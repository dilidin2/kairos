import std/[asyncdispatch, json, strutils, times, logging]
import ws

import ../config/config
import ../twitch/auth
import ../twitch/helix

type
  ChatMessage* = object
    username*: string
    content*: string
    args*: string
    channel*: string
    badges*: seq[string]
    isBot*: bool
    messageId*: string
    ## Message ID (event.message_id): needed for !vanish (Helix DELETE)

  MessageHandler* = proc (msg: ChatMessage) {.async.}

  EventSubMessageType* = enum
    emtUnknown
    emtSessionWelcome
    emtSessionKeepalive
    emtSessionReconnect
    emtNotification
    emtRevocation

  TwitchChat* = ref object
    broadcasterId*: string
    botId*: string
    token*: TokenSet
    config*: BotConfig
    kind*: TokenKind
    onMessage*: proc (msg: ChatMessage) {.async.}
    shuttingDown*: bool
    sessionId*: string
    # internal state
    ws*: WebSocket
    lastMessageAt*: float
    keepaliveTimeoutSec*: float
    reconnectBackoffMs*: int
    listenActive*: bool
    watchdogActive*: bool

var
  ## `var` (not `const`) so tests can point it at a local mock
  WsUrl* = "wss://eventsub.wss.twitch.tv/ws"

const
  DefaultKeepaliveTimeoutSec* = 10.0
  DefaultReconnectBackoffMs* = 3000

# --- Construction ---------------------------------------------------------------

proc newTwitchChat*(
    broadcasterId: string,
    botId: string,
    token: TokenSet,
    config: BotConfig,
    kind: TokenKind = tkBroadcaster
): TwitchChat =
  ## Creates a new TwitchChat instance
  result = TwitchChat(
    broadcasterId: broadcasterId,
    botId: botId,
    token: token,
    config: config,
    kind: kind,
    shuttingDown: false,
    sessionId: "",
    lastMessageAt: epochTime(),
    keepaliveTimeoutSec: DefaultKeepaliveTimeoutSec,
    reconnectBackoffMs: DefaultReconnectBackoffMs
  )

# --- Parsing --------------------------------------------------------------------

proc parseWsPacket*(payload: string): JsonNode =
  ## EventSub WSS packets have two lines: "evt_type: <type>" and then
  ## the JSON payload. Returns only the JSON (tolerant if the packet
  ## is already pure JSON, useful for tests).
  let idx = payload.find("\n")
  if idx >= 0 and payload[0 .. idx].startsWith("evt_type: "):
    result = parseJson(payload.substr(idx + 1))
  else:
    result = parseJson(payload)

proc parseEventType*(data: JsonNode): EventSubMessageType =
  ## Determines the EventSub message type from metadata.message_type
  let mt =
    if data.hasKey("metadata") and data["metadata"].hasKey("message_type"):
      data["metadata"]["message_type"].getStr
    else:
      ""
  case mt
  of "session_welcome": result = emtSessionWelcome
  of "session_keepalive": result = emtSessionKeepalive
  of "session_reconnect": result = emtSessionReconnect
  of "notification": result = emtNotification
  of "revocation": result = emtRevocation
  else: result = emtUnknown

proc parseChatMessage*(chat: TwitchChat, event: JsonNode): ChatMessage =
  ## Extracts a ChatMessage from a notification event (payload.event)
  var badges: seq[string] = @[]
  let badgesNode = event["badges"]
  if badgesNode != nil and badgesNode.kind == JObject:
    for k in badgesNode.keys:
      badges.add(k)
  let messageId =
    if event.hasKey("message_id"):
      event["message_id"].getStr
    else:
      ""
  result = ChatMessage(
    username: event["chatter_user_login"].getStr,
    content: event["message"]["text"].getStr,
    args: "",
    channel: event["broadcaster_user_login"].getStr,
    badges: badges,
    isBot: badges.contains("bot"),
    messageId: messageId,
  )

# --- Handlers per message type ----------------------------------------------

proc withFreshToken*(chat: TwitchChat,
                    call: proc (accessToken: string): Future[void] {.async.}): Future[void] {.async.} =
  ## Runs `call` with the current access token; on TokenExpiredError it
  ## refreshes and persists the token, then retries ONCE with the new one
  try:
    await call(chat.token.accessToken)
  except TokenExpiredError:
    # expired token: refresh and retry ONCE
    warn "Token expired, refreshing..."
    let newToken = await refreshToken(chat.token)
    chat.token = newToken
    saveToken(chat.kind, newToken)
    await call(newToken.accessToken)

proc handleSessionWelcome*(chat: TwitchChat, data: JsonNode) {.async.} =
  ## session_welcome: saves the session_id and subscribes to channel.chat.message
  ## (from here, not before: the session_id only exists after the welcome)
  chat.sessionId = data["payload"]["session"]["id"].getStr
  info "EventSub session_id: " & chat.sessionId

  try:
    await withFreshToken(chat, proc (token: string) {.async.} =
      await subscribeToChatMessages(
        token, TwitchClientId,
        chat.broadcasterId, chat.botId, chat.sessionId))
    info "channel.chat.message subscription succeeded"
  except CatchableError as e:
    # a failure (even after a token refresh) is logged, not propagated
    error "Subscribe failed: " & e.msg

proc handleSessionKeepalive*(chat: TwitchChat, data: JsonNode) =
  ## session_keepalive: heartbeat, updates the timestamp
  chat.lastMessageAt = epochTime()

proc handleSessionReconnect*(chat: TwitchChat, data: JsonNode) {.async.} =
  ## session_reconnect: opens the NEW connection towards reconnect_url and keeps
  ## the old one until the new one receives its session_welcome,
  ## then closes the old one. Subscriptions migrate on their own.
  let url = data["payload"]["session"]["reconnect_url"].getStr
  info "session_reconnect: migrating to a new session"

  let oldWs = chat.ws
  let newWs = await newWebSocket(url)
  try:
    while true:
      let payload = await newWs.receiveStrPacket()
      if payload.strip().len == 0:
        continue
      let node = parseWsPacket(payload)
      if parseEventType(node) == emtSessionWelcome:
        chat.sessionId = node["payload"]["session"]["id"].getStr
        info "New EventSub session active: " & chat.sessionId
        break
  except CatchableError:
    newWs.hangup()
    raise
  # swap: close the old one, the listen loop will continue on chat.ws
  oldWs.close()
  chat.ws = newWs

proc handleNotification*(chat: TwitchChat, data: JsonNode) =
  ## notification: extracts the message and invokes the onMessage handler
  let msg = parseChatMessage(chat, data["payload"]["event"])
  debug "Chat message from ", msg.username, ": ", msg.content
  if chat.onMessage != nil:
    asyncCheck: chat.onMessage(msg)

proc handleRevocation*(chat: TwitchChat, data: JsonNode) =
  ## revocation: subscription revoked, logs the details
  let sub = data["payload"]["subscription"]
  warn "EventSub subscription revoked: type=" & sub["type"].getStr &
       " status=" & sub["status"].getStr

proc handleMessage*(chat: TwitchChat, data: JsonNode) {.async.} =
  ## Handles a message received from EventSub
  chat.lastMessageAt = epochTime()
  case parseEventType(data):
  of emtSessionWelcome:
    await handleSessionWelcome(chat, data)
  of emtSessionKeepalive:
    handleSessionKeepalive(chat, data)
  of emtSessionReconnect:
    await handleSessionReconnect(chat, data)
  of emtNotification:
    handleNotification(chat, data)
  of emtRevocation:
    handleRevocation(chat, data)
  of emtUnknown:
    warn "Unknown EventSub message_type: " &
         data["metadata"]["message_type"].getStr

# --- Sending messages --------------------------------------------------------------

proc sendMessage*(chat: TwitchChat, text: string) {.async.} =
  ## Sends a message to chat via Helix (delegates to helix.sendChatMessage)
  await withFreshToken(chat, proc (token: string) {.async.} =
    await sendChatMessage(token, chat.broadcasterId, chat.botId, text))
  info "Sent to chat: ", text

# --- Listen loop and watchdog --------------------------------------------------

proc watchdogTask(chat: TwitchChat) {.async.} =
  ## Parallel timer: if NO message (of any kind) arrives
  ## within keepaliveTimeoutSec, the network is probably dead silently:
  ## force a reconnection by closing the socket.
  while not chat.shuttingDown:
    await sleepAsync(1000)
    let ws = chat.ws
    if ws != nil and ws.readyState == Open:
      # 2x THRESHOLD: the server sends the keepalive at t≈K (K = default
      # 10s interval, from keepalive_timeout_seconds in the welcome). With a
      # threshold = K the watchdog would RACE with the keepalive (which can
      # arrive at t=10.1s while the watchdog fires at t=10.0s). With 2K the
      # keepalive "saves" the connection with a wide margin; a dead connection
      # is detected within 2K.
      if epochTime() - chat.lastMessageAt > chat.keepaliveTimeoutSec * 2:
        warn "EventSub keepalive expired, forcing reconnection"
        ws.hangup()

proc listenTask(chat: TwitchChat) {.async.} =
  ## Outer loop: connect → listen until the connection drops →
  ## reconnect. The listenActive flag prevents duplicate tasks on the
  ## same instance in case of close-together reconnections.
  if chat.listenActive:
    return
  chat.listenActive = true
  defer:
    chat.listenActive = false

  while not chat.shuttingDown:
    var ws = chat.ws
    if ws == nil or ws.readyState != Open:
      try:
        ws = await newWebSocket(WsUrl)
        chat.ws = ws
        chat.lastMessageAt = epochTime()
        info "Connected to the EventSub WebSocket"
      except CatchableError as e:
        warn "EventSub connection failed: " & e.msg
        await sleepAsync(chat.reconnectBackoffMs)
        continue

    # listen while the connection holds (or is not swapped by the reconnect)
    while not chat.shuttingDown and chat.ws == ws:
      try:
        let payload = await ws.receiveStrPacket()
        # the server sends an empty packet on connection: skip it
        if payload.strip().len == 0:
          continue
        await chat.handleMessage(parseWsPacket(payload))
      except WebSocketClosedError, IOError, OSError:
        break
      except CatchableError as e:
        warn "EventSub read error: " & e.msg
        break

    # cleanup of the finished connection (unless swapped by session_reconnect)
    if chat.ws == ws:
      ws.hangup()
      chat.ws = nil
    # otherwise handleSessionReconnect already closed the old one and swapped chat.ws

    if not chat.shuttingDown:
      await sleepAsync(chat.reconnectBackoffMs)

proc connect*(chat: TwitchChat) {.async.} =
  ## Connects to the EventSub WebSocket and starts the listen loop + watchdog
  chat.ws = await newWebSocket(WsUrl)
  chat.lastMessageAt = epochTime()
  info "Connected to " & WsUrl
  if not chat.watchdogActive:
    chat.watchdogActive = true
    asyncCheck watchdogTask(chat)
  asyncCheck listenTask(chat)

proc disconnect*(chat: TwitchChat) {.async.} =
  ## Disconnects from the EventSub WebSocket and stops the tasks
  chat.shuttingDown = true
  let ws = chat.ws
  if ws != nil:
    ws.close()
    chat.ws = nil
