import std/[asyncdispatch, httpclient, json, strutils, uri, tables, logging]

import ../config/config

type
  UserInfo* = object
    id*: string
    login*: string
    displayName*: string

  TokenExpiredError* = object of CatchableError
    ## Twitch OAuth token expired or invalid (HTTP 401)

  HelixRateLimitError* = object of CatchableError

  HelixError* = object of CatchableError
    ## Generic HTTP error from Helix (outside 2xx, 401, 429)
    code*: int

  MessageNotSentError* = object of CatchableError
    ## Twitch accepted the request (2xx) but the message was not
    ## actually sent to chat (e.g. AutoMod drop)
    reason*: string

  DeleteResult* = enum
    ## Outcome of a chat message deletion
    drDeleted
    ## 204: deleted
    drAlreadyGone
    ## 404: already deleted (or no longer available)
    drRateLimited
    ## 429: rate limit reached

var
  ## `var` (not `const`) so tests can point it at a local mock
  HelixBaseUrl* = "https://api.twitch.tv/helix"

const
  EventSubWebSocketUrl* = "wss://eventsub.wss.twitch.tv/ws"

proc makeHelixRequest*(
    token: string,
    methodo: HttpMethod = HttpGet,
    path: string,
    body: JsonNode = nil,
    query: Table[string, string] = initTable[string, string](),
    clientId: string = TwitchClientId
): Future[JsonNode] {.async.} =
  ## Performs a Helix request with standard headers and error handling:
  ## - 2xx    → JsonNode of the response (empty object if body is empty)
  ## - 401    → TokenExpiredError
  ## - 429    → HelixRateLimitError
  ## - other  → HelixError with the HTTP code

  let client = newAsyncHttpClient()
  defer: client.close()

  var url = HelixBaseUrl & path
  if query.len > 0:
    var q: seq[(string, string)] = @[]
    for k, v in query.pairs:
      q.add((k, v))
    url &= "?" & encodeQuery(q)

  var headers = newHttpHeaders()
  headers.add("Client-Id", clientId)
  headers.add("Authorization", "Bearer " & token)

  var reqBody = ""
  if body != nil:
    reqBody = body.pretty()
    headers.add("Content-Type", "application/json")

  debug "Helix: " & $methodo & " " & path

  let resp = await client.request(url, methodo, reqBody, headers)
  let respBody = await resp.body

  if is2xx(resp.code):
    if respBody.len > 0:
      result = parseJson(respBody)
    else:
      result = newJObject()
  elif resp.code == Http401:
    raise newException(TokenExpiredError, "Twitch token expired or invalid (401)")
  elif resp.code == Http429:
    raise newException(HelixRateLimitError, "Helix rate limit reached (429)")
  else:
    warn "Helix error " & $resp.code & " on " & path & ": " & respBody
    var e = newException(HelixError, "Helix HTTP error " & $resp.code & " on " & path)
    e.code = int(resp.code)
    raise e

proc parseUserInfo*(node: JsonNode): UserInfo =
  ## Extracts a UserInfo from a /helix/users response
  let user = node["data"][0]
  result = UserInfo(
    id: user["id"].getStr,
    login: user["login"].getStr,
    displayName: user["display_name"].getStr
  )

proc getSelfUser*(token: string): Future[UserInfo] {.async.} =
  ## GET /helix/users - resolves the user of the current token
  let resp = await makeHelixRequest(token, HttpGet, "/users")
  result = parseUserInfo(resp)

proc getUserByLogin*(token: string, login: string): Future[UserInfo] {.async.} =
  ## GET /helix/users?login=<login> - resolves a user by login
  var query = initTable[string, string]()
  query["login"] = login
  let resp = await makeHelixRequest(token, HttpGet, "/users", query = query)
  result = parseUserInfo(resp)

proc sendChatMessage*(
    token: string,
    broadcasterId: string,
    senderId: string,
    text: string
): Future[void] {.async.} =
  ## POST /helix/chat/messages - sends a message to chat.
  ## Real response: {"data":[{"message_id":...,"is_sent":true/"drop_reason":...}]}.
  ## Twitch can answer 2xx but not send the message (e.g. AutoMod):
  ## in that case `is_sent` is false and MessageNotSentError is raised.
  let body = %*{
    "broadcaster_id": broadcasterId,
    "sender_id": senderId,
    "message": text
  }

  let resp = await makeHelixRequest(token, HttpPost, "/chat/messages", body = body)

  if not resp.hasKey("data") or resp["data"].len == 0:
    var e = newException(MessageNotSentError, "Unexpected response from /chat/messages (no data)")
    e.reason = "unexpected response"
    raise e

  let sentNode = resp["data"][0]
  if not sentNode["is_sent"].getBool:
    let reason =
      if sentNode.hasKey("drop_reason") and sentNode["drop_reason"] != nil:
        sentNode["drop_reason"].getStr
      else:
        "reason not specified"
    var e = newException(MessageNotSentError, "Message not sent to chat: " & reason)
    e.reason = reason
    raise e

proc getEventSubWebSocketUrl*(): string =
  ## Returns the EventSub WebSocket URL
  result = EventSubWebSocketUrl

proc subscribeToChatMessages*(
    token: string,
    clientId: string,
    broadcasterId: string,
    botId: string,
    sessionId: string
): Future[void] {.async.} =
  ## POST /helix/eventsub/subscriptions - subscribes to channel.chat.message
  let body = %*{
    "type": "channel.chat.message",
    "version": "1",
    "condition": {
      "broadcaster_user_id": broadcasterId,
      "user_id": botId
    },
    "transport": {
      "method": "websocket",
      "session_id": sessionId
    }
  }

  discard await makeHelixRequest(token, HttpPost, "/eventsub/subscriptions",
    body = body, clientId = clientId)

proc deleteChatMessage*(
    token: string,
    broadcasterId: string,
    moderatorId: string,
    messageId: string
): Future[DeleteResult] {.async.} =
  ## DELETE /helix/moderation/chat - deletes a chat message.
  ## Requires the `moderator:manage:chat_messages` scope and the bot must be
  ## a moderator of the channel. 204 = deleted, 404 = already deleted,
  ## 429 = rate limit (the caller handles the pause).
  var query = initTable[string, string]()
  query["broadcaster_id"] = broadcasterId
  query["moderator_id"] = moderatorId
  query["message_id"] = messageId
  try:
    discard await makeHelixRequest(token, HttpDelete, "/moderation/chat", query = query)
    result = drDeleted
  except HelixRateLimitError:
    result = drRateLimited
  except HelixError as e:
    if e.code == 404:
      result = drAlreadyGone
    else:
      raise
