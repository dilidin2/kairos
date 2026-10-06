import std/[unittest, asyncdispatch, asyncnet, strutils, tables, json,
  sha1, base64, times, os]
import std/collections/sequtils
import ws

import ../src/kairosbot/config/config
import ../src/kairosbot/twitch/chat
import ../src/kairosbot/twitch/auth
import ../src/kairosbot/twitch/helix

# The refresh tests call saveToken: redirect DataDir to a temp
# dir so they do not overwrite the real data/bot_token.json
auth.DataDir = getTempDir() / "kairos_test_chat_data"
createDir(auth.DataDir)

# --- Mock WebSocket server (handmade: handshake + text frames) -----------

proc wsAcceptKey(key: string): string =
  let sh = secureHash(key & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
  result = base64.encode(decodeBase16($sh))

proc encodeServerTextFrame(text: string): string =
  ## WS server→client frame: fin=1, opcode=Text, unmasked
  result = ""
  result.add(char(128 + 0x1))
  if text.len <= 125:
    result.add(text.len.char)
  elif text.len <= 65535:
    result.add(126.char)
    result.add(char((text.len shr 8) and 255))
    result.add(char(text.len and 255))
  else:
    result.add(127.char)
    for i in [int64(56), 48, 40, 32, 24, 16, 8, 0]:
      result.add(char((text.len.int64 shr i) and 255))
  result.add(text)

var
  wsScripts: seq[seq[string]]   # frames (JSON) to send per connection
  wsKeepOpen: seq[bool]         # keep the connection open after the frames
  wsConnections: int
  wsClientClosed: seq[bool]     # per connection: has the client closed?

proc wrapWsFrame(frame: string): string =
  ## Simulates the real EventSub format: "evt_type: <type>\n<payload JSON>"
  if frame.startsWith("{"):
    try:
      let n = parseJson(frame)
      let mt =
        if n.hasKey("metadata") and n["metadata"].hasKey("message_type"):
          n["metadata"]["message_type"].getStr
        else:
          "notification"
      return "evt_type: " & mt & "\n" & frame
    except CatchableError:
      discard
  frame

proc wsHandler(client: AsyncSocket) {.async.} =
  try:
    var data = ""
    while data.find("\r\n\r\n") < 0:
      let chunk = await client.recv(4096)
      if chunk.len == 0:
        return
      data &= chunk
    let headerEnd = data.find("\r\n\r\n")
    var key = ""
    for line in data[0..headerEnd].split("\r\n"):
      if line.toLowerAscii().startsWith("sec-websocket-key:"):
        key = line.substr(20).strip()

    let resp = "HTTP/1.1 101 Switching Protocols\r\n" &
      "Upgrade: websocket\r\n" &
      "Connection: Upgrade\r\n" &
      "Sec-WebSocket-Accept: " & wsAcceptKey(key) & "\r\n\r\n"
    await client.send(resp)

    let idx = wsConnections
    wsConnections += 1
    wsClientClosed.add(false)

    if idx < wsScripts.len:
      # local copy: avoids iterating over a seq that other tests can reset
      let frames = @wsScripts[idx]
      # the real server sends an empty packet on connection
      try:
        await client.send(encodeServerTextFrame(""))
      except CatchableError:
        return
      for frame in frames:
        try:
          await client.send(encodeServerTextFrame(wrapWsFrame(frame)))
        except CatchableError:
          return
        await sleepAsync(5)
    if idx < wsKeepOpen.len and not wsKeepOpen[idx]:
      client.close()
      return

    # stays listening until the client closes (incoming frames: pong)
    while true:
      let chunk = await client.recv(1024)
      if chunk.len == 0:
        if idx < wsClientClosed.len:
          wsClientClosed[idx] = true
        break
  finally:
    client.close()

proc wsAcceptLoop(server: AsyncSocket) {.async.} =
  while true:
    let client = await server.accept()
    asyncCheck wsHandler(client)

proc startWsServer(port: Port): Future[AsyncSocket] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(port = port, address = "127.0.0.1")
  server.listen()
  asyncCheck wsAcceptLoop(server)
  return server

proc resetWsMocks(scripts: openArray[seq[string]], keepOpen: openArray[bool] = @[]) =
  wsScripts = @scripts
  wsKeepOpen = @keepOpen
  wsConnections = 0
  wsClientClosed = @[]

# --- Mock HTTP server (same pattern as test_auth) ---------------------------

type
  MockResponse = tuple[code: int, body: string]

var
  mockResponses: Table[string, seq[MockResponse]]
  mockRequests: seq[(string, string)]

proc httpReadRequest(client: AsyncSocket): Future[(string, string)] {.async.} =
  var data = ""
  var contentLen = 0
  while true:
    let chunk = await client.recv(65536)
    if chunk.len == 0:
      break
    data &= chunk
    let sepIdx = data.find("\r\n\r\n")
    if sepIdx >= 0:
      for line in data[0..sepIdx].split("\r\n"):
        if line.toLowerAscii().startsWith("content-length:"):
          contentLen = parseInt(line.substr(16))
      if data.len >= sepIdx + 4 + contentLen:
        break
  let sepIdx = data.find("\r\n\r\n")
  let firstLine = data.split("\r\n")[0]
  let body =
    if sepIdx >= 0 and data.len > sepIdx + 4:
      data.substr(sepIdx + 4, sepIdx + 3 + contentLen)
    else:
      ""
  result = (firstLine, body)

proc httpHandler(client: AsyncSocket) {.async.} =
  try:
    let (firstLine, body) = await httpReadRequest(client)
    let parts = firstLine.splitWhitespace()
    let path = parts[1].split("?")[0]
    mockRequests.add((parts[0] & " " & path, body))

    var resp: MockResponse = (404, "{}")
    if mockResponses.hasKey(path) and mockResponses[path].len > 0:
      resp = mockResponses[path][0]
      mockResponses[path].delete(0)

    let statusLine =
      case resp.code
      of 200: "HTTP/1.1 200 OK"
      of 401: "HTTP/1.1 401 Unauthorized"
      else: "HTTP/1.1 " & $resp.code & " Error"
    let respStr = statusLine &
      "\r\nContent-Type: application/json" &
      "\r\nContent-Length: " & $resp.body.len &
      "\r\nConnection: close\r\n\r\n" & resp.body
    await client.send(respStr)
  finally:
    client.close()

proc httpAcceptLoop(server: AsyncSocket) {.async.} =
  while true:
    let client = await server.accept()
    asyncCheck httpHandler(client)

proc startHttpServer(port: Port): Future[AsyncSocket] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(port = port, address = "127.0.0.1")
  server.listen()
  asyncCheck httpAcceptLoop(server)
  return server

proc httpMockOne(path: string, code: int, body: string) =
  mockResponses = initTable[string, seq[MockResponse]]()
  mockResponses[path] = @[(code, body)]
  mockRequests = @[]

proc httpMockAdd(path: string, code: int, body: string) =
  if not mockResponses.hasKey(path):
    mockResponses[path] = @[]
  mockResponses[path].add((code, body))

proc useMockHttp(port: Port) =
  HelixBaseUrl = "http://127.0.0.1:" & $int(port) & "/helix"
  TwitchOAuthTokenUrl = "http://127.0.0.1:" & $int(port) & "/oauth2/token"

## Waits (with an active event loop!) for the condition to become true.
## It must be async: a synchronous sleep() here would starve the event loop
## and block both the mocks and the bot.
proc waitForCond(cond: proc(): bool, timeoutMs: int = 5000): Future[bool] {.async.} =
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() < deadline:
    if cond():
      return true
    await sleepAsync(20)
  return cond()

# --- Global state for the tests ---------------------------------------------------

var receivedMsgs: seq[ChatMessage] = @[]

proc testHandler(msg: ChatMessage) {.async.} =
  receivedMsgs.add(msg)

proc makeChat(port: Port): TwitchChat =
  ## Chat with a fake token and minimal backoff for the tests
  let t = TokenSet(accessToken: "fake-token", refreshToken: "fake-rt",
    expiresAt: epochTime() + 3600, scope: @[], userLogin: "botacc", userId: "777")
  let c = newTwitchChat("111", "777", t, BotConfig(), tkBot)
  c.reconnectBackoffMs = 50
  c.onMessage = testHandler
  discard port
  result = c

# --- Tests ------------------------------------------------------------------------

suite "Chat":

  test "parseEventType recognizes all types":
    check parseEventType(%*{"metadata": {"message_type": "session_welcome"}}) == emtSessionWelcome
    check parseEventType(%*{"metadata": {"message_type": "session_keepalive"}}) == emtSessionKeepalive
    check parseEventType(%*{"metadata": {"message_type": "session_reconnect"}}) == emtSessionReconnect
    check parseEventType(%*{"metadata": {"message_type": "notification"}}) == emtNotification
    check parseEventType(%*{"metadata": {"message_type": "revocation"}}) == emtRevocation
    check parseEventType(%*{"metadata": {"message_type": "qualcosaltro"}}) == emtUnknown
    check parseEventType(newJObject()) == emtUnknown

  test "parseWsPacket strips the evt_type header of the real format":
    let pkt = "evt_type: session_welcome\n" &
      """{"metadata":{"message_type":"session_welcome"}}"""
    let n = parseWsPacket(pkt)
    check n["metadata"]["message_type"].getStr == "session_welcome"
    # tolerant: pure JSON (no header) passes straight through
    let pure = parseWsPacket("""{"a":1}""")
    check pure["a"].getInt == 1

  test "parseChatMessage extracts the event fields":
    let chat = makeChat(Port(0))
    let event = %*{
      "chatter_user_login": "mario",
      "broadcaster_user_login": "canale",
      "message": {"text": "ciao a tutti", "non_ce": true},
      "badges": {"subscriber": "12", "vip": "1"}
    }
    let msg = parseChatMessage(chat, event)
    check msg.username == "mario"
    check msg.content == "ciao a tutti"
    check msg.channel == "canale"
    check msg.args == ""
    check msg.isBot == false
    check msg.badges.len == 2
    check "subscriber" in msg.badges
    # bot badge -> isBot true
    let eventBot = %*{
      "chatter_user_login": "qualchibot",
      "broadcaster_user_login": "canale",
      "message": {"text": "ciao", "non_ce": true},
      "badges": {"bot": "1"}
    }
    let msgBot = parseChatMessage(chat, eventBot)
    check msgBot.isBot == true
    check "vip" in msg.badges

  test "handleSessionWelcome saves session_id and subscribes":
    let welcome = %*{
      "metadata": {"message_type": "session_welcome"},
      "payload": {"session": {"id": "sess-abc"}}
    }
    httpMockOne("/helix/eventsub/subscriptions", 200, "{}")
    useMockHttp(Port(18771))
    discard waitFor(startHttpServer(Port(18771)))

    let chat = makeChat(Port(18771))
    waitFor(handleSessionWelcome(chat, welcome))
    check chat.sessionId == "sess-abc"

    check mockRequests.len == 1
    check mockRequests[0][0] == "POST /helix/eventsub/subscriptions"
    let body = mockRequests[0][1]
    check body.contains("sess-abc")   # session_id in the transport
    check body.contains("111")        # broadcaster_id
    check body.contains("777")        # bot_id (sender)

  test "handleSessionKeepalive updates lastMessageAt":
    let ka = %*{"metadata": {"message_type": "session_keepalive"}}
    let chat = makeChat(Port(0))
    chat.lastMessageAt = 0.0
    handleSessionKeepalive(chat, ka)
    check chat.lastMessageAt > epochTime() - 5.0

  test "handleNotification invokes onMessage with the correct ChatMessage":
    proc runTest() {.async.} =
      receivedMsgs = @[]
      let notif = %*{
        "metadata": {"message_type": "notification"},
        "payload": {"event": {
          "chatter_user_login": "pippo",
          "broadcaster_user_login": "canale",
          "message": {"text": "che bello"},
          "badges": {}
        }}
      }
      let chat = makeChat(Port(0))
      handleNotification(chat, notif)
      check await waitForCond(proc(): bool = receivedMsgs.len == 1)
      check receivedMsgs[0].username == "pippo"
      check receivedMsgs[0].content == "che bello"
      check receivedMsgs[0].channel == "canale"
    waitFor(runTest())

  test "handleRevocation does not crash":
    let rev = %*{
      "metadata": {"message_type": "revocation"},
      "payload": {"subscription": {"type": "channel.chat.message", "status": "expired"}}
    }
    let chat = makeChat(Port(0))
    handleRevocation(chat, rev)   # it just must not raise

  test "sendMessage passes the text to Helix":
    httpMockOne("/helix/chat/messages", 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
    useMockHttp(Port(18772))
    discard waitFor(startHttpServer(Port(18772)))

    let chat = makeChat(Port(18772))
    waitFor(sendMessage(chat, "ciao dal bot"))
    check mockRequests.len == 1
    check mockRequests[0][0] == "POST /helix/chat/messages"
    check mockRequests[0][1].contains("ciao dal bot")
    check mockRequests[0][1].contains("111")
    check mockRequests[0][1].contains("777")

  test "sendMessage 401 -> refresh -> successful retry":
    httpMockOne("/helix/chat/messages", 401, """{"message":"Invalid token"}""")
    httpMockAdd("/oauth2/token", 200,
      """{"access_token":"token-nuovo","refresh_token":"rt-nuovo","expires_in":3600,"scope":"a"}""")
    httpMockAdd("/helix/chat/messages", 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
    useMockHttp(Port(18773))
    discard waitFor(startHttpServer(Port(18773)))

    let chat = makeChat(Port(18773))
    waitFor(sendMessage(chat, "riprova"))
    # two requests to /chat/messages: the 401 and the successful one
    let chatReqs = mockRequests.filterIt(it[0] == "POST /helix/chat/messages")
    check chatReqs.len == 2
    check chat.token.accessToken == "token-nuovo"
    check chat.token.refreshToken == "rt-nuovo"

  test "connect: welcome -> subscribe -> notification reaches onMessage":
    proc runTest() {.async.} =
      let welcome = """{"metadata":{"message_type":"session_welcome"},"payload":{"session":{"id":"sess-1"}}}"""
      let notif = """{"metadata":{"message_type":"notification"},"payload":{"event":{"chatter_user_login":"mario","broadcaster_user_login":"canale","message":{"text":"ehi"},"badges":{}}}}"""
      resetWsMocks(@[@[welcome, notif]])
      httpMockOne("/helix/eventsub/subscriptions", 200, "{}")
      useMockHttp(Port(18774))
      discard waitFor(startHttpServer(Port(18774)))
      discard waitFor(startWsServer(Port(18780)))

      WsUrl = "ws://127.0.0.1:18780"
      receivedMsgs = @[]
      let chat = makeChat(Port(18780))
      await connect(chat)

      check await waitForCond(proc(): bool = chat.sessionId == "sess-1")
      check await waitForCond(proc(): bool =
        mockRequests.anyIt(it[0] == "POST /helix/eventsub/subscriptions"))
      check await waitForCond(proc(): bool = receivedMsgs.len == 1)
      check receivedMsgs[0].content == "ehi"

      await disconnect(chat)
      WsUrl = "wss://eventsub.wss.twitch.tv/ws"
    waitFor(runTest())

  test "reconnection after the connection drops":
    proc runTest() {.async.} =
      let welcome1 = """{"metadata":{"message_type":"session_welcome"},"payload":{"session":{"id":"sess-A"}}}"""
      let welcome2 = """{"metadata":{"message_type":"session_welcome"},"payload":{"session":{"id":"sess-B"}}}"""
      # first connection: welcome then drop; second: welcome and stays open
      resetWsMocks(@[@[welcome1], @[welcome2]], @[false, true])
      httpMockOne("/helix/eventsub/subscriptions", 200, "{}")
      httpMockAdd("/helix/eventsub/subscriptions", 200, "{}")
      useMockHttp(Port(18775))
      discard waitFor(startHttpServer(Port(18775)))
      discard waitFor(startWsServer(Port(18781)))

      WsUrl = "ws://127.0.0.1:18781"
      let chat = makeChat(Port(18781))
      await connect(chat)

      # wait for the reconnection: sessionId becomes sess-B and 2 total subscribes
      check await waitForCond(proc(): bool = chat.sessionId == "sess-B", 15000)
      check await waitForCond(proc(): bool =
        mockRequests.filterIt(it[0] == "POST /helix/eventsub/subscriptions").len == 2, 15000)

      await disconnect(chat)
      WsUrl = "wss://eventsub.wss.twitch.tv/ws"
    waitFor(runTest())

  test "session_reconnect: migrates to the new connection without re-subscribing":
    proc runTest() {.async.} =
      let welcome1 = """{"metadata":{"message_type":"session_welcome"},"payload":{"session":{"id":"sess-X"}}}"""
      let reconnect = """{"metadata":{"message_type":"session_reconnect"},"payload":{"session":{"id":"sess-Y","reconnect_url":"ws://127.0.0.1:18782"}}}"""
      let welcome2 = """{"metadata":{"message_type":"session_welcome"},"payload":{"session":{"id":"sess-Y"}}}"""
      # conn 1: welcome + reconnect (then stays open until the bot closes);
      # conn 2: welcome of the new session
      resetWsMocks(@[@[welcome1, reconnect], @[welcome2]], @[true, true])
      httpMockOne("/helix/eventsub/subscriptions", 200, "{}")
      useMockHttp(Port(18776))
      discard waitFor(startHttpServer(Port(18776)))
      discard waitFor(startWsServer(Port(18782)))

      WsUrl = "ws://127.0.0.1:18782"
      let chat = makeChat(Port(18782))
      await connect(chat)

      # the bot must migrate: sessionId sess-Y, old connection closed
      check await waitForCond(proc(): bool = chat.sessionId == "sess-Y", 15000)
      check await waitForCond(proc(): bool =
        wsClientClosed.len > 0 and wsClientClosed[0], 15000)
      # a single subscribe (the subscriptions migrate on their own)
      let subs = mockRequests.filterIt(it[0] == "POST /helix/eventsub/subscriptions")
      check subs.len == 1

      await disconnect(chat)
      WsUrl = "wss://eventsub.wss.twitch.tv/ws"
    waitFor(runTest())
