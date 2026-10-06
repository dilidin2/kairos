import std/[unittest, asyncdispatch, asyncnet, strutils, tables, json, times]
import std/collections/sequtils

import ../src/kairosbot/config/config
import ../src/kairosbot/twitch/chat
import ../src/kairosbot/twitch/auth
import ../src/kairosbot/twitch/helix
import ../src/kairosbot/utils/chat_helpers

# --- Mock HTTP (same pattern as test_chat) -----------------------------------

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

proc mockOne(path: string, code: int, body: string) =
  mockResponses = initTable[string, seq[(int, string)]]()
  mockResponses[path] = @[(code, body)]
  mockRequests = @[]

proc mockAdd(path: string, code: int, body: string) =
  if not mockResponses.hasKey(path):
    mockResponses[path] = @[]
  mockResponses[path].add((code, body))

proc useMockHttp(port: Port) =
  HelixBaseUrl = "http://127.0.0.1:" & $int(port) & "/helix"
  TwitchOAuthTokenUrl = "http://127.0.0.1:" & $int(port) & "/oauth2/token"

proc makeChat(): TwitchChat =
  let t = TokenSet(accessToken: "fake-token", refreshToken: "fake-rt",
    expiresAt: epochTime() + 3600, scope: @[], userLogin: "botacc", userId: "777")
  result = newTwitchChat("111", "777", t, BotConfig(), tkBot)

# --- Tests ------------------------------------------------------------------------

suite "ChatHelpers":

  test "trimToWordBoundary: short text unchanged":
    check trimToWordBoundary("ciao", 10) == "ciao"
    check trimToWordBoundary("ciao", 4) == "ciao"   # exactly at the limit

  test "trimToWordBoundary: cuts at the last space before the limit":
    let text = "una frase abbastanza lunga da tagliare"
    let cut = trimToWordBoundary(text, 15)
    check cut.len <= 15
    check cut == "una frase"
    # the cut point is the LAST space <= limit (9), not the first (3)

  test "trimToWordBoundary: without spaces it hard-cuts":
    let word = "x".repeat(50)
    check trimToWordBoundary(word, 10) == "x".repeat(10)

  test "trimToWordBoundary: removes the trailing spaces of the chunk":
    let text = "aaa  bbb"          # double space in the middle
    let cut = trimToWordBoundary(text, 6)
    check cut == "aaa"

  test "splitMessage: short text -> one identical chunk (even with newlines)":
    check splitMessage("ciao a tutti") == @["ciao a tutti"]
    check splitMessage("riga uno\nriga due") == @["riga uno\nriga due"]

  test "splitMessage: empty text -> no chunks":
    check splitMessage("").len == 0
    check splitMessage("   \n  \n").len == 0

  test "splitMessage: long text split by newline, empty lines discarded":
    let line1 = "a".repeat(300)
    let line2 = "b".repeat(300)
    let text = line1 & "\n\n" & line2 & "\n   "
    check splitMessage(text) == @[line1, line2]

  test "splitMessage: lines are packed into chunks under the limit":
    let line = "y".repeat(200)
    # two lines fit together (401 < 480): one chunk, not two messages
    check splitMessage(line & "\n" & line) == @[line & "\n" & line]
    # four lines: 803 chars -> packed 2+2
    let chunks = splitMessage(line & "\n" & line & "\n" & line & "\n" & line)
    check chunks.len == 2
    check chunks[0] == line & "\n" & line
    check chunks[1] == line & "\n" & line
    for c in chunks:
      check c.len <= MaxMessageLength

  test "splitMessage: very long line broken by words":
    let long = "w ".repeat(540).strip()   # 1079 characters: 540 "w" separated by spaces
    let chunks = splitMessage(long)
    check chunks.len >= 3
    for c in chunks:
      check c.len <= MaxMessageLength
      check c.len > 0
    # reassembling (with spaces) the original text is recovered
    check chunks.join(" ") == long

  test "safeSend: short message -> single request":
    proc runTest() {.async.} =
      mockOne("/helix/chat/messages", 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      useMockHttp(Port(18790))
      discard waitFor(startHttpServer(Port(18790)))

      let chat = makeChat()
      ChunkDelayMs = 5
      await safeSend(chat, "ciao breve")
      check mockRequests.len == 1
      check mockRequests[0][1].contains("ciao breve")
    waitFor(runTest())

  test "safeSend: long message -> one send per chunk, all under the limit":
    proc runTest() {.async.} =
      # 3 lines, the second very long: we expect 3+ sends (the long line
      # is cut at a word boundary, the short lines are packed where they fit)
      let longLine = "parola ".repeat(100).strip()   # 700 characters
      let text = "prima riga\n" & longLine & "\nterza riga"
      mockOne("/helix/chat/messages", 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      for i in 1 ..< 8:
        mockAdd("/helix/chat/messages", 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      useMockHttp(Port(18791))
      discard waitFor(startHttpServer(Port(18791)))

      let chat = makeChat()
      ChunkDelayMs = 5
      await safeSend(chat, text)

      check mockRequests.len >= 3
      for req in mockRequests:
        let msg = parseJson(req[1])["message"].getStr
        check msg.len <= MaxMessageLength
      # all the content arrived, in order
      let all = mockRequests.mapIt(parseJson(it[1])["message"].getStr).join(" ")
      check all.startsWith("prima riga ")
      check all.contains("terza riga")
    waitFor(runTest())
