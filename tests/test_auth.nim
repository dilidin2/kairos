import std/[unittest, asyncdispatch, asyncnet, strutils, tables, os, json, options, times]

import ../src/kairosbot/twitch/auth
import ../src/kairosbot/twitch/helix

# --- Mock HTTP server (std/asyncnet) -------------------------------------------
# Same pattern as test_helix, extended to:
# - logging of the request body
# - multiple responses per path (in order, to simulate pending -> success)

type
  MockResponse = tuple[code: int, body: string]

var
  mockResponses: Table[string, seq[MockResponse]]
  mockRequests: seq[(string, string)]   # (method & path, body)

proc readRequest(client: AsyncSocket): Future[(string, string)] {.async.} =
  ## Reads the complete HTTP request (even in segments) and returns
  ## (firstLine, body)
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

proc mockHandler(client: AsyncSocket) {.async.} =
  try:
    let (firstLine, body) = await readRequest(client)
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
      of 400: "HTTP/1.1 400 Bad Request"
      else: "HTTP/1.1 " & $resp.code & " Error"
    let respStr = statusLine &
      "\r\nContent-Type: application/json" &
      "\r\nContent-Length: " & $resp.body.len &
      "\r\nConnection: close\r\n\r\n" & resp.body
    await client.send(respStr)
  finally:
    client.close()

proc mockAcceptLoop(server: AsyncSocket) {.async.} =
  while true:
    let client = await server.accept()
    asyncCheck mockHandler(client)

proc startMockServer(port: Port): Future[AsyncSocket] {.async.} =
  let server = newAsyncSocket(buffered = false)
  server.setSockOpt(OptReuseAddr, true)
  server.bindAddr(port = port, address = "127.0.0.1")
  server.listen()
  asyncCheck mockAcceptLoop(server)
  return server

proc mockOne(path: string, code: int, body: string) =
  mockResponses = initTable[string, seq[MockResponse]]()
  mockResponses[path] = @[(code, body)]
  mockRequests = @[]

proc mockAdd(path: string, code: int, body: string) =
  if not mockResponses.hasKey(path):
    mockResponses[path] = @[]
  mockResponses[path].add((code, body))

proc useMock(port: Port) =
  ## Points OAuth and Helix at the same local mock
  TwitchOAuthDeviceUrl = "http://127.0.0.1:" & $int(port) & "/oauth2/device"
  TwitchOAuthTokenUrl = "http://127.0.0.1:" & $int(port) & "/oauth2/token"
  HelixBaseUrl = "http://127.0.0.1:" & $int(port) & "/helix"

const TestDataDir = "test_data_auth"

proc cleanTestDir() =
  if dirExists(TestDataDir):
    for f in walkFiles(TestDataDir & "/*"):
      removeFile(f)
    removeDir(TestDataDir)

# --- Tests ------------------------------------------------------------------------

suite "Auth":

  test "tokenPath returns the right files":
    DataDir = TestDataDir
    check tokenPath(tkBroadcaster) == TestDataDir / "broadcaster_token.json"
    check tokenPath(tkBot) == TestDataDir / "bot_token.json"
    DataDir = "data"

  test "saveToken/loadToken roundtrip":
    cleanTestDir()
    DataDir = TestDataDir
    let t = TokenSet(
      accessToken: "at", refreshToken: "rt", expiresAt: 1234567890.0,
      scope: @["user:read:chat", "user:write:chat"],
      userLogin: "acc", userId: "42"
    )
    saveToken(tkBroadcaster, t)
    check fileExists(tokenPath(tkBroadcaster))

    let loaded = loadToken(tkBroadcaster)
    check loaded.isSome()
    check loaded.get().accessToken == "at"
    check loaded.get().refreshToken == "rt"
    check loaded.get().expiresAt == 1234567890.0
    check loaded.get().scope == @["user:read:chat", "user:write:chat"]
    check loaded.get().userLogin == "acc"
    check loaded.get().userId == "42"
    cleanTestDir()
    DataDir = "data"

  test "loadToken on a missing file returns none":
    cleanTestDir()
    DataDir = TestDataDir
    check loadToken(tkBot).isNone()
    cleanTestDir()
    DataDir = "data"

  test "isTokenExpired: futuro, passato, margine":
    let now = epochTime()
    check not isTokenExpired(TokenSet(expiresAt: now + 3600))
    check isTokenExpired(TokenSet(expiresAt: now - 100))
    check isTokenExpired(TokenSet(expiresAt: now + 30))  # within the 60s margin

  test "tokenKindToString":
    check tokenKindToString(tkBroadcaster) == "broadcaster"
    check tokenKindToString(tkBot) == "bot"

  test "postOAuth 200 parses the body":
    mockOne("/oauth2/device", 200, """{"device_code":"dc"}""")
    useMock(Port(18751))
    discard waitFor(startMockServer(Port(18751)))

    let node = waitFor(postOAuth("http://127.0.0.1:18751/oauth2/device",
      @[("client_id", "cid"), ("scopes", "a b")]))
    check node["device_code"].getStr == "dc"
    check mockRequests[0][1].contains("client_id=cid")
    check mockRequests[0][1].contains("scopes=a")  # URL-encoded (kept)

  test "postOAuth 400 raises OAuthError with errorCode":
    mockOne("/oauth2/token", 400, """{"error":"expired_token","error_description":"gone"}""")
    useMock(Port(18752))
    discard waitFor(startMockServer(Port(18752)))

    var caughtCode = 0
    var caughtErr = ""
    try:
      discard waitFor(postOAuth("http://127.0.0.1:18752/oauth2/token", @[]))
    except OAuthError as e:
      caughtCode = e.code
      caughtErr = e.errorCode
    check caughtCode == 400
    check caughtErr == "expired_token"

  test "requestDeviceCode sends client_id and scopes":
    mockOne("/oauth2/device", 200,
      """{"device_code":"dc1","user_code":"ABCD","verification_uri":"http://mock/activate","expires_in":1800,"interval":0}""")
    useMock(Port(18753))
    discard waitFor(startMockServer(Port(18753)))

    let dev = waitFor(requestDeviceCode("cid", @["user:read:chat", "user:write:chat"]))
    check dev["device_code"].getStr == "dc1"
    let body = mockRequests[0][1]
    check body.contains("client_id=cid")
    check body.contains("user%3Aread%3Achat")  # URL-encoded colons

  test "pollToken: authorization_pending -> OAuthPendingError":
    mockOne("/oauth2/token", 400, """{"error":"authorization_pending"}""")
    useMock(Port(18754))
    discard waitFor(startMockServer(Port(18754)))

    var caught = false
    try:
      discard waitFor(pollToken("cid", "dc"))
    except OAuthPendingError:
      caught = true
    check caught

  test "pollToken: authorization_pending in the real Twitch format (message, not error)":
    # Twitch returns {"status":400,"message":"authorization_pending"}
    # without an "error" field: the conversion must go through "message"
    mockOne("/oauth2/token", 400, """{"status":400,"message":"authorization_pending"}""")
    useMock(Port(18761))
    discard waitFor(startMockServer(Port(18761)))

    var caught = false
    try:
      discard waitFor(pollToken("cid", "dc"))
    except OAuthPendingError:
      caught = true
    except OAuthError:
      caught = false
    check caught

  test "pollToken: slow_down -> OAuthSlowDownError":
    mockOne("/oauth2/token", 400, """{"error":"slow_down"}""")
    useMock(Port(18755))
    discard waitFor(startMockServer(Port(18755)))

    var caught = false
    try:
      discard waitFor(pollToken("cid", "dc"))
    except OAuthSlowDownError:
      caught = true
    check caught

  test "pollToken: fatal error re-raises OAuthError":
    mockOne("/oauth2/token", 400, """{"error":"expired_token"}""")
    useMock(Port(18756))
    discard waitFor(startMockServer(Port(18756)))

    var caught = false
    try:
      discard waitFor(pollToken("cid", "dc"))
    except OAuthError:
      caught = true
    check caught

  test "parseTokenResponse: absolute timestamp and inheritance from old":
    let before = epochTime()
    let t = parseTokenResponse(parseJson(
      """{"access_token":"at","refresh_token":"rt","expires_in":3600,"scope":"a b"}"""))
    check t.accessToken == "at"
    check t.refreshToken == "rt"
    check t.expiresAt >= before + 3600
    check t.expiresAt < before + 3610
    check t.scope == @["a", "b"]
    check t.userLogin == ""
    check t.userId == ""

    let old = TokenSet(accessToken: "old", refreshToken: "rt-old",
      expiresAt: 0.0, scope: @["x"], userLogin: "acc", userId: "9")
    let t2 = parseTokenResponse(
      parseJson("""{"access_token":"new","expires_in":100}"""), old)
    check t2.accessToken == "new"
    check t2.refreshToken == "rt-old"   # inherited
    check t2.scope == @["x"]            # inherited
    check t2.userLogin == "acc"
    check t2.userId == "9"

  test "refreshToken renews and keeps the user data":
    mockOne("/oauth2/token", 200,
      """{"access_token":"at2","refresh_token":"rt2","expires_in":3600,"scope":"a b"}""")
    useMock(Port(18757))
    discard waitFor(startMockServer(Port(18757)))

    let old = TokenSet(accessToken: "at1", refreshToken: "rt1",
      expiresAt: 0.0, scope: @["a"], userLogin: "acc", userId: "7")
    let t = waitFor(refreshToken(old))
    check t.accessToken == "at2"
    check t.refreshToken == "rt2"
    check t.userLogin == "acc"
    check t.userId == "7"
    let body = mockRequests[0][1]
    check body.contains("grant_type=refresh_token")
    check body.contains("refresh_token=rt1")

  test "authenticate: valid token returned without HTTP requests":
    cleanTestDir()
    DataDir = TestDataDir
    useMock(Port(18758))   # port without a server: if it makes requests, it fails
    mockOne("/oauth2/token", 400, """{"error":"boom"}""")

    let t = TokenSet(
      accessToken: "valid", refreshToken: "rt", expiresAt: epochTime() + 7200,
      scope: @["a"], userLogin: "acc", userId: "1")
    saveToken(tkBroadcaster, t)

    let got = waitFor(authenticate(tkBroadcaster, @["a"]))
    check got.accessToken == "valid"
    check mockRequests.len == 0
    cleanTestDir()
    DataDir = "data"

  test "authenticate: expired token + ok refresh -> re-saved":
    cleanTestDir()
    DataDir = TestDataDir
    mockOne("/oauth2/token", 200,
      """{"access_token":"at3","refresh_token":"rt3","expires_in":3600,"scope":"a"}""")
    useMock(Port(18759))
    discard waitFor(startMockServer(Port(18759)))

    let old = TokenSet(
      accessToken: "scaduto", refreshToken: "rt-vecchio", expiresAt: epochTime() - 100,
      scope: @["a"], userLogin: "acc", userId: "1")
    saveToken(tkBot, old)

    let t = waitFor(authenticate(tkBot, @["a"]))
    check t.accessToken == "at3"
    check t.refreshToken == "rt3"

    # the single-use refresh token must be re-saved to the file
    let onDisk = loadToken(tkBot)
    check onDisk.isSome()
    check onDisk.get().refreshToken == "rt3"
    cleanTestDir()
    DataDir = "data"

  test "authenticate: missing file -> complete Device Code Flow":
    cleanTestDir()
    DataDir = TestDataDir
    mockOne("/oauth2/device", 200,
      """{"device_code":"dc9","user_code":"WXYZ","verification_uri":"http://mock/activate","expires_in":1800,"interval":0}""")
    mockAdd("/oauth2/token", 200,
      """{"access_token":"atf","refresh_token":"rtf","expires_in":3600,"scope":"user:read:chat user:write:chat"}""")
    mockAdd("/helix/users", 200,
      """{"data":[{"id":"777","login":"botacc","display_name":"BotAcc"}]}""")
    useMock(Port(18760))
    discard waitFor(startMockServer(Port(18760)))

    let t = waitFor(authenticate(tkBot, @["user:read:chat", "user:write:chat"]))
    check t.accessToken == "atf"
    check t.refreshToken == "rtf"
    check t.userLogin == "botacc"
    check t.userId == "777"
    check t.scope == @["user:read:chat", "user:write:chat"]

    # the token has been persisted
    check fileExists(tokenPath(tkBot))
    let onDisk = loadToken(tkBot)
    check onDisk.isSome()
    check onDisk.get().userId == "777"
    cleanTestDir()
    DataDir = "data"
