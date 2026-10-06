import std/[unittest, asyncdispatch, asyncnet, strutils, tables, json, os, times, options]
import std/collections/sequtils

import ../src/kairosbot/core/command_router
import ../src/kairosbot/core/cooldown_tracker
import ../src/kairosbot/core/attempt_tracker
import ../src/kairosbot/core/trophy_tracker
import ../src/kairosbot/commands/registry
import ../src/kairosbot/config/config
import ../src/kairosbot/twitch/chat
import ../src/kairosbot/twitch/auth
import ../src/kairosbot/twitch/helix

# --- Mock HTTP (test_chat pattern) ---------------------------------------------

var
  mockResponses: Table[string, seq[(int, string)]]
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

proc mockMany(path: string, n: int, code: int, body: string) =
  mockResponses = initTable[string, seq[(int, string)]]()
  mockResponses[path] = @[]
  for i in 1 .. n:
    mockResponses[path].add((code, body))
  mockRequests = @[]

proc useMockHttp(port: Port) =
  HelixBaseUrl = "http://127.0.0.1:" & $int(port) & "/helix"
  TwitchOAuthTokenUrl = "http://127.0.0.1:" & $int(port) & "/oauth2/token"

# --- Setup -----------------------------------------------------------------------

var tmpCounter = 0

proc freshPaths(): (string, string) =
  tmpCounter += 1
  let base = getTempDir() / ("kairos_test_router_" & $tmpCounter)
  result = (base & "_attempts.json", base & "_trophies.json")

proc makeRouter(): CommandRouter =
  let t = TokenSet(accessToken: "fake-token", refreshToken: "fake-rt",
    expiresAt: epochTime() + 3600, scope: @[], userLogin: "botacc", userId: "777")
  let chat = newTwitchChat("111", "777", t, BotConfig(), tkBot)
  var config = BotConfig()
  config.botName = "kairosbot"
  config.commandPrefix = "!"
  let (attemptsPath, trophiesPath) = freshPaths()
  let registry = newCommandRegistry()
  result = newCommandRouter(chat,
    newTrophyTracker(trophiesPath),
    newCooldownTracker(),
    newAttemptTracker(attemptsPath),
    registry, config)

proc mkMsg(content: string, username = "mario", isBot = false): ChatMessage =
  ChatMessage(username: username, content: content, isBot: isBot, channel: "canale")

suite "CommandRouter":

  test "parseCommand extracts name and arguments":
    let router = makeRouter()
    let opt = router.parseCommand("!8ball dadi")
    check opt.isSome()
    let (name, args) = opt.get()
    check name == "8ball"
    check args == "dadi"
    # no arguments
    let opt2 = router.parseCommand("!ping")
    check opt2.isSome()
    check opt2.get()[1] == ""

  test "parseCommand ignores messages without prefix":
    let router = makeRouter()
    check router.parseCommand("ciao").isNone()
    check router.parseCommand("8ball dadi").isNone()

  test "parseCommand returns None for a nonexistent command":
    # the parse succeeds, but the registry lookup gives none
    let router = makeRouter()
    let opt = router.parseCommand("!inesistente")
    check opt.isSome()
    check router.registry.get("inesistente").isNone()

  test "process ignores bot messages":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      useMockHttp(Port(18800))
      discard waitFor(startHttpServer(Port(18800)))

      let router = makeRouter()
      var called = false
      proc handler(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
        called = true
      router.registry.register(Command(name: "test", helpText: "h"))
      router.registerHandler("test", handler)

      # both isBot and username == botName must be ignored
      await router.process(mkMsg("!test", isBot = true))
      check not called
      await router.process(mkMsg("!test", username = "kairosbot"))
      check not called
      # case-insensitive: Twitch usernames are case-insensitive
      await router.process(mkMsg("!test", username = "KairosBOT"))
      check not called
    waitFor(runTest())

  test "process ignores messages without prefix":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      useMockHttp(Port(18801))
      discard waitFor(startHttpServer(Port(18801)))

      let router = makeRouter()
      var called = false
      proc handler(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
        called = true
      router.registry.register(Command(name: "test", helpText: "h"))
      router.registerHandler("test", handler)

      await router.process(mkMsg("ciao a tutti"))
      check not called
    waitFor(runTest())

  test "process runs an existing command":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      useMockHttp(Port(18802))
      discard waitFor(startHttpServer(Port(18802)))

      let router = makeRouter()
      var gotArgs = ""
      proc handler(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
        gotArgs = msg.args
      router.registry.register(Command(name: "test", helpText: "h"))
      router.registerHandler("test", handler)

      await router.process(mkMsg("!test argomento1 argomento2"))
      check gotArgs == "argomento1 argomento2"
    waitFor(runTest())

  test "process: command in the registry without a handler does not crash":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      useMockHttp(Port(18806))
      discard waitFor(startHttpServer(Port(18806)))

      let router = makeRouter()
      # I register only the metadata, without a handler (incomplete config)
      router.registry.register(Command(name: "orphan", helpText: "h"))
      # it must not raise an exception; it must reply with a generic error
      await router.process(mkMsg("!orphan"))
      let sent = mockRequests.filterIt(it[0] == "POST /helix/chat/messages")
      check sent.len == 1
    waitFor(runTest())

  test "process blocks a command on cooldown":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      useMockHttp(Port(18803))
      discard waitFor(startHttpServer(Port(18803)))

      let router = makeRouter()
      var called = false
      proc handler(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
        called = true
      router.registry.register(Command(name: "test", helpText: "h", cooldown: 5.0))
      router.registerHandler("test", handler)
      router.cooldownTracker.setCooldown("mario", "test", 100.0)

      await router.process(mkMsg("!test"))
      check not called
      # the cooldown message went out
      check mockRequests.anyIt(it[1].contains("cooldown"))
    waitFor(runTest())

  test "process blocks a command with no attempts left":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      useMockHttp(Port(18804))
      discard waitFor(startHttpServer(Port(18804)))

      let router = makeRouter()
      var called = false
      proc handler(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
        called = true
      router.registry.register(Command(name: "slots", helpText: "h",
        maxAttemptsPerDay: 2))
      router.registerHandler("slots", handler)
      # I exhaust the attempts
      router.attemptTracker.useAttempt("mario", "slots")
      router.attemptTracker.useAttempt("mario", "slots")

      await router.process(mkMsg("!slots"))
      check not called
      check mockRequests.anyIt(it[1].contains("no attempts"))
    waitFor(runTest())

  test "process catches handler exceptions":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      useMockHttp(Port(18805))
      discard waitFor(startHttpServer(Port(18805)))

      let router = makeRouter()
      proc handler(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
        raise newException(ValueError, "boom")
      router.registry.register(Command(name: "test", helpText: "h", cooldown: 5.0))
      router.registerHandler("test", handler)

      # it must not propagate the exception
      await router.process(mkMsg("!test"))
      # generic error message sent
      check mockRequests.anyIt(it[1].contains("generic error"))
      # cooldown set anyway after the command
      check router.cooldownTracker.isOnCooldown("mario", "test")
    waitFor(runTest())
