import std/[asyncdispatch, asyncnet, strutils, tables, json, os, options, times]

import ../src/kairosbot/config/config
import ../src/kairosbot/twitch/chat
import ../src/kairosbot/twitch/auth
import ../src/kairosbot/twitch/helix
import ../src/kairosbot/core/command_router
import ../src/kairosbot/core/cooldown_tracker
import ../src/kairosbot/core/attempt_tracker
import ../src/kairosbot/core/trophy_tracker
import ../src/kairosbot/commands/registry
import ../src/kairosbot/plugin

## Mock HTTP + MockPluginContext reusable for the plugin tests:
## in-memory send (mock Helix), command registry, working beginWindow.

var
  mockResponses: Table[string, seq[(int, string)]]
  mockRequests*: seq[(string, string)]
  tmpCounter = 0

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

    var resp: (int, string) = (404, "{}")
    if mockResponses.hasKey(path) and mockResponses[path].len > 0:
      resp = mockResponses[path][0]
      mockResponses[path].delete(0)

    let statusLine =
      case resp[0]
      of 200: "HTTP/1.1 200 OK"
      else: "HTTP/1.1 " & $resp[0] & " Error"
    let respStr = statusLine &
      "\r\nContent-Type: application/json" &
      "\r\nContent-Length: " & $resp[1].len &
      "\r\nConnection: close\r\n\r\n" & resp[1]
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

proc mockMany*(path: string, n: int, code: int, body: string) =
  mockResponses = initTable[string, seq[(int, string)]]()
  mockResponses[path] = @[]
  for i in 1 .. n:
    mockResponses[path].add((code, body))
  mockRequests = @[]

proc mockAdd*(path: string, code: int, body: string, n: int = 1) =
  ## Adds `n` responses (code, body) to the path without clearing the others
  if not mockResponses.hasKey(path):
    mockResponses[path] = @[]
  for i in 1 .. n:
    mockResponses[path].add((code, body))

proc useMockHttp*(port: Port) =
  HelixBaseUrl = "http://127.0.0.1:" & $int(port) & "/helix"
  TwitchOAuthTokenUrl = "http://127.0.0.1:" & $int(port) & "/oauth2/token"

proc startMockHttp*(port: Port) {.async.} =
  discard await startHttpServer(port)

proc sentBodies*(): seq[string] =
  ## Bodies of the messages sent to chat (POST /helix/chat/messages)
  for r in mockRequests:
    if r[0] == "POST /helix/chat/messages":
      result.add(r[1])

proc sentMessages*(): seq[string] =
  ## `message` field of every POST /helix/chat/messages (chat text)
  for b in sentBodies():
    let node = parseJson(b)
    if node.kind == JObject and node.hasKey("message"):
      result.add(node["message"].getStr)
    else:
      result.add(b)

proc mkMsg*(content: string, username = "mario",
           isBot = false, badges: seq[string] = @[]): ChatMessage =
  ChatMessage(username: username, content: content,
              isBot: isBot, badges: badges, channel: "canale")

proc makeMockContext*(pluginName: string, port: Port, dir = ""): PluginContext =
  ## Builds a real PluginContext (router, trackers, window guard)
  ## on top of a local HTTP mock: the tests stay focused on the logic.
  tmpCounter += 1
  useMockHttp(port)
  let t = TokenSet(accessToken: "fake-token", refreshToken: "fake-rt",
    expiresAt: epochTime() + 3600, scope: @[], userLogin: "botacc", userId: "777")
  let chat = newTwitchChat("111", "777", t, BotConfig(), tkBot)
  var config = BotConfig()
  config.botName = "kairosbot"
  config.commandPrefix = "!"
  let base = getTempDir() / ("kairos_test_" & pluginName & "_" & $tmpCounter)
  let registry = newCommandRegistry()
  let router = newCommandRouter(chat,
    newTrophyTracker(base & "_trophies.json"),
    newCooldownTracker(),
    newAttemptTracker(base & "_attempts.json"),
    registry, config)
  let platform = newPluginPlatform(router, router.trophyTracker,
    router.attemptTracker, base,
    "kairosbot", "111", "777", "canale")
  result = newPluginContext(platform, pluginName, dir)
