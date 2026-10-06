import std/[unittest, asyncdispatch, asyncnet, strutils, tables, os, options, times]

import ../src/kairosbot/config/config
import ../src/kairosbot/twitch/auth
import ../src/kairosbot/twitch/helix
import ../src/kairosbot/twitch/chat
import ../src/kairosbot/core/command_router
import ../src/kairosbot/core/cooldown_tracker
import ../src/kairosbot/core/trophy_tracker
import ../src/kairosbot/core/attempt_tracker
import ../src/kairosbot/commands/registry
import ../src/kairosbot/plugin
import ../src/kairosbot/utils/logger
import ../src/kairos

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

proc tempBase(): string =
  tmpCounter += 1
  result = getTempDir() / ("kairos_test_entry_" & $tmpCounter)
  if dirExists(result):
    removeDir(result)   # recursive in Nim 2: cleans up any leftovers
  createDir(result)

proc seedValidToken(kind: TokenKind) =
  ## Writes a valid token to the DataDir so authenticate() makes no HTTP
  let t = TokenSet(accessToken: "tok-" & tokenKindToString(kind),
    refreshToken: "rt-" & tokenKindToString(kind),
    expiresAt: epochTime() + 3600, scope: @[],
    userLogin: "utente_" & tokenKindToString(kind), userId: "uid-" & tokenKindToString(kind))
  saveToken(kind, t)

suite "KairosEntry":

  test "parseCliArgs detects --bot":
    check parseCliArgs(@["--bot"])
    check not parseCliArgs(@["altro"])
    check not parseCliArgs(@[])
    check parseCliArgs(@["x", "--bot", "y"])

  test "checkBroadcasterTokenExists":
    let base = tempBase()
    kairos.DataDir = base
    auth.DataDir = base
    check not checkBroadcasterTokenExists()
    writeFile(base / "broadcaster_token.json", "{}")
    check checkBroadcasterTokenExists()

  test "resolveIds in broadcaster mode: same account":
    let t = TokenSet(accessToken: "a", refreshToken: "b",
      expiresAt: epochTime() + 3600, scope: @[], userLogin: "x", userId: "111")
    let config = BotConfig()
    proc runTest() {.async.} =
      let (b, r) = await resolveIds(t, config, tkBroadcaster)
      check b == "111" and r == "111"
    waitFor(runTest())

  test "resolveIds in bot mode: resolves the channel from the config":
    proc runTest() {.async.} =
      mockMany("/helix/users", 3, 200,
        """{"data":[{"id":"chan-999","login":"canale","display_name":"Canale"}]}""")
      useMockHttp(Port(18826))
      discard waitFor(startHttpServer(Port(18826)))

      let t = TokenSet(accessToken: "a", refreshToken: "b",
        expiresAt: epochTime() + 3600, scope: @[], userLogin: "x", userId: "777")
      var config = BotConfig()
      config.channel = "canale"
      let (b, r) = await resolveIds(t, config, tkBot)
      check b == "chan-999"
      check r == "777"
    waitFor(runTest())

  test "complete bootstrap (pre-existing token, no HTTP)":
    proc runTest() {.async.} =
      let base = tempBase()
      kairos.DataDir = base
      auth.DataDir = base
      ConfigPath = base / "bot_config.json"
      LogDir = base
      writeFile(ConfigPath, """
        {"bot_name":"kairos","channel":"canale","command_prefix":"!",
         "cooldown_default":30,
         "llm_server":{"host":"localhost","port":8099,"temperature":0.8},
         "quest_system":{"enabled":false,"periodic_quest_call":10,
                        "llm_active":true},
         "peerbus":{"host":"127.0.0.1","port":8310,"kind":"games",
                    "peers":{}}}
      """)
      seedValidToken(tkBroadcaster)

      let (config, chat, router, trophyTracker, attemptTracker, platform) =
        await bootstrap(tkBroadcaster, BroadcasterScopes)
      check config.botName == "kairos"
      check chat.broadcasterId == "uid-broadcaster"
      check chat.botId == "uid-broadcaster"
      check chat.kind == tkBroadcaster
      check chat.onMessage != nil
      check router.registry.listAll().len == 25  # info(4) + games(4) + trophies(1) + fun(4) + economy(3) + quotes(3) + quiz(1) + stocks(4) + vanish(1)
      check router.registry.get("slots").isSome()
      check router.registry.get("8ball").isSome()
      check router.registry.get("trophy").isSome()
      check router.registry.get("ping").isSome()
      check trophyTracker.rules.hasKey("slots")
      check trophyTracker.rules.hasKey("8ball")
      # platform built with the correct IDs
      check platform.botName == "utente_broadcaster"
      check platform.broadcasterId == "uid-broadcaster"
      check platform.botId == "uid-broadcaster"
      check platform.channel == "canale"
      check platform.dataDir == base
      # startTime set to the present (not the 1970 default -> absurd uptime)
      let up = (now().toTime() - kairos.botStartTime).inSeconds
      check up >= 0 and up < 60
      # botName = real login (guard against auto-reply)
      check router.botName == "utente_broadcaster"
      await platform.stop()
    waitFor(runTest())

  test "shutdown saves the data to disk":
    proc runTest() {.async.} =
      let base = tempBase()
      kairos.DataDir = base
      auth.DataDir = base
      LogDir = base
      let t = TokenSet(accessToken: "a", refreshToken: "b",
        expiresAt: epochTime() + 3600, scope: @[], userLogin: "x", userId: "111")
      let chat = newTwitchChat("111", "111", t, BotConfig(), tkBroadcaster)
      let trophyTracker = newTrophyTracker(base / "trophies.json")
      let attemptTracker = newAttemptTracker(base / "attempts.json")
      trophyTracker.trophies["mario"] = @[
        Trophy(name: "Gambler", command: "slots", unlockedAt: "2026-10-04T12:00:00")]
      let registry = newCommandRegistry()
      let router = newCommandRouter(chat, trophyTracker,
        newCooldownTracker(), attemptTracker, registry, BotConfig())
      let platform = newPluginPlatform(router, trophyTracker, attemptTracker,
        base, "x", "111", "111", "c")
      await shutdown(chat, trophyTracker, attemptTracker, platform)
      check fileExists(base / "trophies.json")
      check fileExists(base / "attempts.json")
    waitFor(runTest())
