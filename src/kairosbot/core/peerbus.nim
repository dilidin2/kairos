import std/[asyncdispatch, strutils, tables, json, net, httpclient, options, logging]
import std/asynchttpserver

## PeerBus: inter-bot HTTP bus on localhost.
##
## Every bot exposes the same base API (v1 contract, designed to be
## extended to all the project's bots and to the unified GUI):
##   GET  /v1/info   → identity  {name, kind, version}
##   GET  /v1/state  → {"busy": bool, "detail": string}
##   POST /v1/events → receives push events from peers
## Plugins can add their own routes via `addRoute`.
##
## Events are JSON: {"sender": name, "eventType": ..., "user": ..., "detail": ...}
## `sender` is filled in by the sender (sendEvent)

type
  PeerEvent* = object
    sender*: string
    eventType*: string
    user*: string
    detail*: string

  PeerEventHandler* = proc (sender: string, event: PeerEvent): Future[void] {.async, gcsafe.}
  PeerHttpHandler* = proc (body: JsonNode): Future[JsonNode] {.gcsafe.}

  PeerBus* = ref object
    server*: AsyncHttpServer
    client*: AsyncHttpClient
    host*: string
    port*: Port
    name*: string
    kind*: string
    version*: string
    busy*: bool
    busyDetail*: string
    peers*: Table[string, string]
    peerEventHandlers*: seq[PeerEventHandler]
    routes*: Table[string, PeerHttpHandler]
    stopping*: bool

proc newPeerBus*(name, kind, version, host: string, port: Port,
                 peers: Table[string, string]): PeerBus =
  ## Creates the bus (not listening yet: call `start`)
  result = PeerBus(
    server: newAsyncHttpServer(),
    client: newAsyncHttpClient(),
    host: host,
    port: port,
    name: name,
    kind: kind,
    version: version,
    peers: peers,
    peerEventHandlers: @[],
    routes: initTable[string, PeerHttpHandler]()
  )

proc getPort*(bus: PeerBus): Port =
  ## Port actually bound (useful with Port(0) in tests)
  bus.server.getPort

proc setBusy*(bus: PeerBus, detail: string) =
  ## Marks the bot as busy (short window: "talking/inferring right now")
  bus.busy = true
  bus.busyDetail = detail

proc clearBusy*(bus: PeerBus) =
  bus.busy = false
  bus.busyDetail = ""

proc isBusy*(bus: PeerBus): bool =
  result = bus.busy

proc addEventHandler*(bus: PeerBus, handler: PeerEventHandler) =
  ## Subscribes to incoming peer events (POST /v1/events)
  bus.peerEventHandlers.add(handler)

proc addRoute*(bus: PeerBus, path: string, handler: PeerHttpHandler) =
  ## Registers a plugin route (e.g. GET /v1/quest)
  bus.routes[path] = handler

proc handleRequest(bus: PeerBus, req: Request) {.async, gcsafe.} =
  ## Minimal router: base routes + plugin routes
  let headers = newHttpHeaders([("Content-Type", "application/json")])
  let path = req.url.path
  try:
    case req.reqMethod
    of HttpGet:
      case path
      of "/v1/info":
        await req.respond(Http200, (%*{"name": bus.name, "kind": bus.kind,
                                      "version": bus.version}).pretty(), headers)
      of "/v1/state":
        await req.respond(Http200, (%*{"busy": bus.busy, "detail": bus.busyDetail}).
                          pretty(), headers)
      else:
        if bus.routes.hasKey(path):
          let resp = await bus.routes[path](nil)
          await req.respond(Http200, resp.pretty(), headers)
        else:
          await req.respond(Http404, "not found")
    of HttpPost:
      if path == "/v1/events":
        var event: PeerEvent
        if req.body.len > 0:
          try:
            event = to(parseJson(req.body), PeerEvent)
          except CatchableError:
            await req.respond(Http400, "invalid event")
            return
        for h in bus.peerEventHandlers:
          asyncCheck: h(event.sender, event)
        await req.respond(Http200, (%*{}).pretty(), headers)
      elif bus.routes.hasKey(path):
        var body: JsonNode = nil
        if req.body.len > 0:
          try:
            body = parseJson(req.body)
          except CatchableError:
            body = nil
        let resp = await bus.routes[path](body)
        await req.respond(Http200, resp.pretty(), headers)
      else:
        await req.respond(Http404, "not found")
    else:
      await req.respond(Http405, "method not allowed")
  except CatchableError as e:
    warn "PeerBus: error handling the request: ", e.msg
    try:
      await req.respond(Http500, "internal error")
    except CatchableError:
      discard

proc serveLoop(bus: PeerBus) {.async.} =
  ## Accept loop: ends on stop (socket closed → accept fails)
  proc cb(req: Request) {.async, gcsafe.} =
    await bus.handleRequest(req)
  while not bus.stopping:
    try:
      if bus.server.shouldAcceptRequest():
        await bus.server.acceptRequest(cb)
      else:
        await sleepAsync(500)
    except CatchableError as e:
      if not bus.stopping:
        warn "PeerBus: accept error: ", e.msg
        await sleepAsync(500)

proc start*(bus: PeerBus): bool =
  ## Starts listening. true = ok, false = failure (e.g. port in use):
  ## the caller decides (for us: log + continue without the bus)
  try:
    bus.server.listen(bus.port, bus.host)
  except CatchableError as e:
    error "PeerBus: cannot open ", bus.host, ":", $int(bus.port),
          " — ", e.msg
    result = false
    return
  info "PeerBus: HTTP su ", bus.host, ":", $int(bus.port)
  asyncCheck bus.serveLoop()
  result = true

proc stop*(bus: PeerBus) =
  ## Closes the server and the outbound client
  bus.stopping = true
  bus.server.close()
  bus.client.close()

proc sendEvent*(bus: PeerBus, peer: string, event: PeerEvent): Future[bool] {.async.} =
  ## Sends a push event to a peer. true = delivered (2xx).
  ## Failures are logged and return false (never exceptions).
  let base = bus.peers.getOrDefault(peer, "")
  if base.len == 0:
    debug "PeerBus: unknown peer: ", peer
    result = false
    return
  var e = event
  e.sender = bus.name
  let payload = %*e
  let headers = newHttpHeaders([("Content-Type", "application/json")])
  try:
    let resp = await bus.client.request(base & "/v1/events", HttpPost,
                                        payload.pretty(), headers)
    discard await resp.body
    result = is2xx(resp.code)
    if not result:
      warn "PeerBus: sendEvent to ", peer, " → HTTP ", $resp.code
  except CatchableError as e2:
    debug "PeerBus: sendEvent to ", peer, " failed: ", e2.msg
    result = false

proc broadcastEvent*(bus: PeerBus, event: PeerEvent) =
  ## Sends an event to ALL known peers (fire-and-forget)
  for peer, _ in bus.peers:
    asyncCheck: bus.sendEvent(peer, event)

proc peerState*(bus: PeerBus, peer: string): Future[Option[(bool, string)]] {.async.} =
  ## Reads the peer state (busy, detail). none = unreachable/unknown.
  let base = bus.peers.getOrDefault(peer, "")
  if base.len == 0:
    result = none((bool, string))
    return
  try:
    let resp = await bus.client.request(base & "/v1/state", HttpGet, "")
    let body = await resp.body
    if is2xx(resp.code):
      let node = parseJson(body)
      result = some((node["busy"].getBool(), node["detail"].getStr()))
    else:
      result = none((bool, string))
  except CatchableError as e:
    debug "PeerBus: peerState of ", peer, " failed: ", e.msg
    result = none((bool, string))
