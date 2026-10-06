import std/[unittest, asyncdispatch, asyncnet, strutils, tables]

import ../src/kairosbot/twitch/helix

# --- Minimal mock HTTP server (std/asyncnet) --------------------------------

type
  MockResponse = tuple[code: int, body: string]

var
  mockResponses: Table[string, MockResponse]
  mockRequests: seq[string]

proc mockHandler(client: AsyncSocket) {.async.} =
  try:
    let data = await client.recv(65536)
    let firstLine = data.split("\r\n")[0]
    let parts = firstLine.splitWhitespace()
    if parts.len >= 2:
      mockRequests.add(parts[0] & " " & parts[1])
      let path = parts[1].split("?")[0]
      let (code, body) = mockResponses.getOrDefault(path, (404, "{}"))
      let statusLine =
        case code
        of 200: "HTTP/1.1 200 OK"
        of 401: "HTTP/1.1 401 Unauthorized"
        of 429: "HTTP/1.1 429 Too Many Requests"
        else: "HTTP/1.1 " & $code & " Error"
      let resp = statusLine &
        "\r\nContent-Type: application/json" &
        "\r\nContent-Length: " & $body.len &
        "\r\nConnection: close\r\n\r\n" & body
      await client.send(resp)
  finally:
    client.close()

proc mockAcceptLoop(server: AsyncSocket) {.async.} =
  while true:
    let client = await server.accept()
    asyncCheck mockHandler(client)

proc startMockServer(port: Port): Future[AsyncSocket] {.async.} =
  ## buffered=false: recv returns as soon as data arrives,
  ## without waiting for the requested `size` bytes (otherwise deadlock with the client)
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(port = port, address = "127.0.0.1")
  server.listen()
  asyncCheck mockAcceptLoop(server)
  return server

proc mockOne(path: string, code: int, body: string) =
  ## Configures the mock with a single response and resets the history
  mockResponses = initTable[string, MockResponse]()
  mockResponses[path] = (code, body)
  mockRequests = @[]

proc useMock(port: Port) =
  HelixBaseUrl = "http://127.0.0.1:" & $int(port)

# --- Tests ----------------------------------------------------------------------

suite "Helix":

  test "getSelfUser parses id, login and display_name":
    mockOne("/users", 200, """{"data":[{"id":"123","login":"tester","display_name":"Tester"}]}""")
    useMock(Port(18741))
    discard waitFor(startMockServer(Port(18741)))

    let user = waitFor(getSelfUser("fake-token"))
    check user.id == "123"
    check user.login == "tester"
    check user.displayName == "Tester"
    check mockRequests == @["GET /users"]

  test "getUserByLogin includes the login query param":
    mockOne("/users", 200, """{"data":[{"id":"456","login":"streamer","display_name":"Streamer"}]}""")
    useMock(Port(18742))
    discard waitFor(startMockServer(Port(18742)))

    let user = waitFor(getUserByLogin("fake-token", "streamer"))
    check user.id == "456"
    check user.login == "streamer"
    check mockRequests == @["GET /users?login=streamer"]

  test "sendChatMessage ok with is_sent=true":
    mockOne("/chat/messages", 200,
      """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
    useMock(Port(18743))
    discard waitFor(startMockServer(Port(18743)))

    waitFor(sendChatMessage("fake-token", "111", "222", "ciao"))
    check mockRequests == @["POST /chat/messages"]

  test "sendChatMessage raises MessageNotSentError with is_sent=false":
    mockOne("/chat/messages", 200,
      """{"data":[{"message_id":null,"is_sent":false,"drop_reason":"automod"}]}""")
    useMock(Port(18744))
    discard waitFor(startMockServer(Port(18744)))

    var caught = false
    try:
      waitFor(sendChatMessage("fake-token", "111", "222", "ciao"))
    except MessageNotSentError as e:
      caught = true
      check e.reason == "automod"
    check caught

  test "sendChatMessage: response without data raises MessageNotSentError":
    mockOne("/chat/messages", 200, """{"message":"weird"}""")
    useMock(Port(18749))
    discard waitFor(startMockServer(Port(18749)))

    var caught2 = false
    try:
      waitFor(sendChatMessage("fake-token", "111", "222", "ciao"))
    except MessageNotSentError:
      caught2 = true
    check caught2

  test "401 raises TokenExpiredError":
    mockOne("/users", 401, """{"message":"Invalid token"}""")
    useMock(Port(18745))
    discard waitFor(startMockServer(Port(18745)))

    var caught = false
    try:
      discard waitFor(getSelfUser("scaduto"))
    except TokenExpiredError:
      caught = true
    check caught

  test "429 raises HelixRateLimitError":
    mockOne("/users", 429, """{"message":"Slow down"}""")
    useMock(Port(18746))
    discard waitFor(startMockServer(Port(18746)))

    var caught = false
    try:
      discard waitFor(getSelfUser("fake-token"))
    except HelixRateLimitError:
      caught = true
    check caught

  test "500 raises HelixError with the code":
    mockOne("/users", 500, """{"message":"boom"}""")
    useMock(Port(18747))
    discard waitFor(startMockServer(Port(18747)))

    var caughtCode = -1
    try:
      discard waitFor(getSelfUser("fake-token"))
    except HelixError as e:
      caughtCode = e.code
    check caughtCode == 500

  test "subscribeToChatMessages sends the EventSub request":
    mockOne("/eventsub/subscriptions", 200, "{}")
    useMock(Port(18748))
    discard waitFor(startMockServer(Port(18748)))

    waitFor(subscribeToChatMessages("fake-token", "client-id", "111", "222", "session-abc"))
    check mockRequests == @["POST /eventsub/subscriptions"]

  test "getEventSubWebSocketUrl returns the standard URL":
    check getEventSubWebSocketUrl() == "wss://eventsub.wss.twitch.tv/ws"
