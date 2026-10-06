import std/[tables, options, json, strutils, asyncdispatch, os, logging, sequtils]

import ./commands/registry
import ./core/command_router
import ./core/trophy_tracker
import ./core/attempt_tracker
import ./core/window_guard
import ./core/peerbus
import ./data/persistence
import ./twitch/chat
import ./utils/chat_helpers

## Plugin contract for Kairos.
##
## Each plugin lives in `commands/<name>/main.nim` and exposes exactly one
## `proc register(ctx: PluginContext)`. The context is the entire available
## API: plugins do not import other plugins, coupling always goes through
## the core.

type
  Service* = ref object of RootObj
    ## Base for shared services exposed by one plugin to others
    ## (e.g. `ctx.services["economy"]`). The consumer casts to the
    ## concrete type: `cast[EconomyService](ctx.services["economy"])`.
    ## `of RootObj` makes the type inheritable by concrete services.

  BotInfo* = object
    botName*: string
    broadcasterId*: string
    botId*: string
    channel*: string

  TimerHandler* = proc () {.async.}
  ShutdownHandler* = proc () {.async.}

  CommandSpec* = object
    ## Metadata for a command read from `commands.json` (data in JSON,
    ## behaviour in Nim). Extra fields stay in `params`.
    name*: string
    aliases*: seq[string]
    help*: string
    cooldown*: float
    maxAttemptsPerDay*: int
    role*: CommandRole
    params*: Table[string, JsonNode]

  PlatformTimer = ref object
    task*: Future[void]
    stop*: bool

  PluginPlatform* = ref object
    ## Shared core state, built once at bootstrap
    router*: CommandRouter
    trophyTracker*: TrophyTracker
    attemptTracker*: AttemptTracker
    dataDir*: string
    botName*: string
    broadcasterId*: string
    botId*: string
    channel*: string
    services*: Table[string, Service]
    windowGuard*: WindowGuard
    timers*: seq[PlatformTimer]
    shutdownHooks*: seq[ShutdownHandler]
    peerBus*: PeerBus
    ## Inter-bot HTTP bus (nil = bus inactive, peer procs are no-ops)

  PluginContext* = ref object
    ## API exposed to a single plugin
    platform*: PluginPlatform
    name*: string
    dir*: string
    ## Plugin directory (`commands/<name>`): data files
    ## (commands.json, content.json, ...) live here
    statePath*: string
    ## Path `data/<name>.json`: persistence owned by the plugin

proc newPluginPlatform*(
    router: CommandRouter,
    trophyTracker: TrophyTracker,
    attemptTracker: AttemptTracker,
    dataDir: string,
    botName: string,
    broadcasterId: string,
    botId: string,
    channel: string,
    peerBus: PeerBus = nil
): PluginPlatform =
  ## Creates the shared platform on which contexts are built
  result = PluginPlatform(
    router: router,
    trophyTracker: trophyTracker,
    attemptTracker: attemptTracker,
    dataDir: dataDir,
    botName: botName,
    broadcasterId: broadcasterId,
    botId: botId,
    channel: channel,
    services: initTable[string, Service](),
    windowGuard: newWindowGuard(),
    timers: @[],
    shutdownHooks: @[],
    peerBus: peerBus
  )

proc newPluginContext*(platform: PluginPlatform, name: string,
                       dir: string = ""): PluginContext =
  ## Creates a plugin context: `statePath` points to `data/<name>.json`,
  ## `dir` is the plugin folder (passed by the generator at build time)
  result = PluginContext(
    platform: platform,
    name: name,
    dir: dir,
    statePath: platform.dataDir / (name & ".json")
  )

# --- Context API -----------------------------------------------------------

proc send*(ctx: PluginContext, text: string) {.async.} =
  ## Sends text to chat (already via safeSend)
  await safeSend(ctx.platform.router.chat, text)

proc registerCommand*(ctx: PluginContext, spec: CommandSpec,
                      handler: CommandHandler) =
  ## Registers a command in the router: metadata in the registry (aliases,
  ## role, cooldown, attempts) + handler
  let router = ctx.platform.router
  router.registry.register(Command(
    name: spec.name,
    helpText: spec.help,
    cooldown: spec.cooldown,
    maxAttemptsPerDay: spec.maxAttemptsPerDay,
    category: ctx.name,
    role: spec.role,
    aliases: spec.aliases
  ))
  router.registerHandler(spec.name, handler)

proc onMessage*(ctx: PluginContext, handler: MessageHandler) =
  ## Subscribes to chat messages: the core invokes the plugin on every message
  ctx.platform.router.subscribers.add(handler)

proc every*(ctx: PluginContext, intervalSec: int, handler: TimerHandler) =
  ## Periodic timer managed by the core (started immediately, stopped at shutdown)
  let t = PlatformTimer()
  proc timerTask() {.async.} =
    while not t.stop:
      await sleepAsync(intervalSec * 1000)
      if not t.stop:
        try:
          await handler()
        except CatchableError as e:
          echo "[PLUGIN] ", ctx.name, ": timer error: ", e.msg
  t.task = timerTask()  # the task starts immediately, it is not awaited
  ctx.platform.timers.add(t)

proc beginWindow*(ctx: PluginContext, name: string, seconds: int,
                  onExpire: WindowExpireHandler): bool =
  ## Acquires the channel guard: only one timed mini-game at a time.
  ## true = acquired, false = one is already running
  ctx.platform.windowGuard.tryBegin(name, seconds, onExpire)

proc endWindow*(ctx: PluginContext, name: string) =
  ## Releases the window `name` early (e.g. quiz won)
  ctx.platform.windowGuard.release(name)

proc activeWindow*(ctx: PluginContext): Option[(string, float)] =
  ## Window currently in progress: (name, seconds remaining)
  let g = ctx.platform.windowGuard
  if g.isActive():
    result = some((g.activeName, g.remaining()))
  else:
    result = none((string, float))

proc trophyRules*(ctx: PluginContext, command: string,
                  rules: seq[TrophyRule]) =
  ## Registers trophy rules for a command
  ctx.platform.trophyTracker.addRules(command, rules)

proc botInfo*(ctx: PluginContext): BotInfo =
  ## Bot identity: name, broadcaster, IDs, channel
  let p = ctx.platform
  result = BotInfo(botName: p.botName, broadcasterId: p.broadcasterId,
                   botId: p.botId, channel: p.channel)

proc onShutdown*(ctx: PluginContext, handler: ShutdownHandler) =
  ## Hook called at shutdown (e.g. forceSave of the plugin's persistence)
  ctx.platform.shutdownHooks.add(handler)

# --- Peer bus (inter-bot HTTP) --------------------------------------------------

proc onPeerEvent*(ctx: PluginContext, handler: PeerEventHandler) =
  ## Subscribes to incoming peer events (POST /v1/events)
  if ctx.platform.peerBus != nil:
    ctx.platform.peerBus.addEventHandler(handler)

proc sendEvent*(ctx: PluginContext, peer: string, event: PeerEvent) =
  ## Sends a push event to a peer (fire-and-forget)
  if ctx.platform.peerBus != nil:
    asyncCheck: ctx.platform.peerBus.sendEvent(peer, event)

proc peerState*(ctx: PluginContext, peer: string): Future[Option[(bool, string)]] {.async.} =
  ## State of a peer: (busy, detail). none = unreachable/unknown
  if ctx.platform.peerBus != nil:
    result = await ctx.platform.peerBus.peerState(peer)
  else:
    result = none((bool, string))

proc broadcastEvent*(ctx: PluginContext, event: PeerEvent) =
  ## Sends an event to all known peers (fire-and-forget)
  if ctx.platform.peerBus != nil:
    ctx.platform.peerBus.broadcastEvent(event)

proc setBusy*(ctx: PluginContext, detail: string) =
  ## Marks the bot as busy for /v1/state (short window)
  if ctx.platform.peerBus != nil:
    ctx.platform.peerBus.setBusy(detail)

proc clearBusy*(ctx: PluginContext) =
  if ctx.platform.peerBus != nil:
    ctx.platform.peerBus.clearBusy()

proc httpRoute*(ctx: PluginContext, path: string, handler: PeerHttpHandler) =
  ## Registers a plugin HTTP route on the bus (e.g. GET /v1/quest)
  if ctx.platform.peerBus != nil:
    ctx.platform.peerBus.addRoute(path, handler)

proc stop*(platform: PluginPlatform) {.async.} =
  ## Platform shutdown: stops timers and guard, runs the hooks
  for t in platform.timers:
    t.stop = true
  platform.windowGuard.stop()
  for h in platform.shutdownHooks:
    try:
      await h()
    except CatchableError as e:
      echo "[PLUGIN] shutdown hook error: ", e.msg
  if platform.peerBus != nil:
    platform.peerBus.stop()

# --- commands.json ---------------------------------------------------------------

const
  specKnownKeys = @["help", "cooldown", "max_attempts_per_day", "role", "aliases"]

proc stripPrefix(name: string): string =
  ## Removes the "!" prefix from a command/alias name
  if name.startsWith("!"):
    result = name[1 .. ^1]
  else:
    result = name

proc loadCommandSpecs*(path: string): Table[string, CommandSpec] =
  ## Parses `commands.json`: one entry per command.
  ## Validation rules (no crashes):
  ## - missing/malformed file -> empty table + warning
  ## - missing field -> default
  result = initTable[string, CommandSpec]()

  if not fileExists(path):
    echo "[PLUGIN] missing commands.json: ", path
    return
  let node = loadJson(path)
  if node.kind != JObject:
    echo "[PLUGIN] malformed commands.json: ", path
    return

  for key, value in node.pairs:
    if value.kind != JObject:
      warn "[PLUGIN] ", path, ": skipping non-object entry: ", key
      continue
    let name = stripPrefix(key)
    if name.len == 0:
      continue

    var spec = CommandSpec(name: name, role: crEveryone)
    if value.hasKey("help"):
      spec.help = value["help"].getStr
    if value.hasKey("cooldown") and
        (value["cooldown"].kind == JInt or value["cooldown"].kind == JFloat):
      spec.cooldown = value["cooldown"].getFloat
    if value.hasKey("max_attempts_per_day") and
        value["max_attempts_per_day"].kind == JInt:
      spec.maxAttemptsPerDay = value["max_attempts_per_day"].getInt
    if value.hasKey("role"):
      case value["role"].getStr.toLowerAscii()
      of "mod": spec.role = crMod
      of "broadcaster": spec.role = crBroadcaster
      else: discard
    if value.hasKey("aliases") and value["aliases"].kind == JArray:
      for a in value["aliases"]:
        let alias = stripPrefix(a.getStr)
        if alias.len > 0:
          spec.aliases.add(alias)
    for k, v in value.pairs:
      if k notin specKnownKeys:
        spec.params[k] = v
    result[name] = spec
    debug "[PLUGIN] spec ", name, ": params=[",
          toSeq(spec.params.keys).join(", "), "]"

  info "[PLUGIN] Loaded ", $result.len, " command spec(s) from ", path

proc isEnabled*(ctx: PluginContext): bool =
  ## The plugin-level `enabled` toggle in config.json (default: true).
  ## Every plugin checks it at the top of register(): disabled plugins
  ## register nothing and return early.
  let path = ctx.dir / "config.json"
  if not fileExists(path):
    return true
  let node = loadJson(path)
  if node.kind == JObject and node.hasKey("enabled"):
    return node["enabled"].getBool
  result = true

type
  TrophyText* = object
    ## Translatable text of a one-off trophy (from the plugin's
    ## trophies.json). `name` is the trophy name, `message` is the chat
    ## announcement ({user}, {name}, {amount}, {item} placeholders).
    name*: string
    message*: string

proc loadTrophyTexts*(path: string): Table[string, TrophyText] =
  ## Loads a plugin's trophies.json: JString values are message
  ## templates, JObject values are {name, message} entries.
  result = initTable[string, TrophyText]()
  if not fileExists(path):
    return
  let node = loadJson(path)
  if node.kind != JObject:
    return
  for key, value in node.pairs:
    var t: TrophyText
    case value.kind
    of JString: t.message = value.getStr
    of JObject:
      if value.hasKey("name"): t.name = value["name"].getStr
      if value.hasKey("message"): t.message = value["message"].getStr
    else: continue
    result[key] = t

proc trophyText*(texts: Table[string, TrophyText], key, defaultName,
                defaultMessage: string): TrophyText =
  ## Entry from trophies.json with built-in defaults as fallback
  let t = texts.getOrDefault(key, TrophyText())
  result = TrophyText(
    name: if t.name.len > 0: t.name else: defaultName,
    message: if t.message.len > 0: t.message else: defaultMessage)

proc loadTrophyRules*(spec: CommandSpec): seq[TrophyRule] =
  ## Parses the `trophies` param of commands.json: a list of
  ## {name, event, threshold, description, type}. Empty if missing.
  ## `type` is "total" (default) or "streak"; event/type are behaviour
  ## keys, name/description/threshold are tunable data.
  result = @[]
  if not spec.params.hasKey("trophies") or spec.params["trophies"].kind != JArray:
    return
  for item in spec.params["trophies"]:
    if item.kind != JObject:
      continue
    var r: TrophyRule
    if item.hasKey("name"): r.name = item["name"].getStr
    if item.hasKey("event"): r.eventType = item["event"].getStr
    if item.hasKey("threshold") and item["threshold"].kind == JInt:
      r.threshold = item["threshold"].getInt
    if item.hasKey("description"): r.description = item["description"].getStr
    if item.hasKey("type") and item["type"].getStr.toLowerAscii() == "streak":
      r.ruleType = trtStreak
    if r.name.len > 0 and r.eventType.len > 0 and r.threshold > 0:
      result.add(r)

proc registerCommands*(ctx: PluginContext,
                       specs: Table[string, CommandSpec],
                       handlers: Table[string, CommandHandler]) =
  ## Registers the handlers following the validation rules (no crashes):
  ## - command in JSON without a handler in code -> skipped + warning
  ## - handler in code without an entry in JSON -> registered with defaults + warning
  for name, spec in specs.pairs:
    if not handlers.hasKey(name):
      echo "[PLUGIN] ", ctx.name, ": command in commands.json without handler: !",
           name, " (skipped)"

  for name in handlers.keys:
    let spec =
      if specs.hasKey(name):
        specs[name]
      else:
        echo "[PLUGIN] ", ctx.name, ": handler without entry in commands.json: !",
             name, " (registered with defaults)"
        CommandSpec(name: name)
    ctx.registerCommand(spec, handlers[name])
    info "[PLUGIN] ", ctx.name, ": registered !", spec.name,
         " (cooldown=", $spec.cooldown, "s, maxAttemptsPerDay=",
         $spec.maxAttemptsPerDay, ")"
