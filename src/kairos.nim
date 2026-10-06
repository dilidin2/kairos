import std/[asyncdispatch, os, strutils, logging, times, tables]

when defined(posix):
  import posix

import kairosbot/config/config
import kairosbot/twitch/auth
import kairosbot/twitch/helix
import kairosbot/twitch/chat
import kairosbot/core/command_router
import kairosbot/core/cooldown_tracker
import kairosbot/core/attempt_tracker
import kairosbot/core/trophy_tracker
import kairosbot/core/peerbus
import kairosbot/commands/registry
import kairosbot/plugin
import generated/plugins_agg
import kairosbot/utils/logger

var
  shutdownFuture*: Future[void] = newFuture[void]("shutdown")
  botStartTime*: times.Time
  ## `var` (not `const`) so tests can redirect these to temporary directories
  DataDir* = "data"
  ConfigPath* = "config/bot_config.json"

const
  ## Note: "channel:manage:chat" was removed by Twitch (replaced by
  ## "channel:bot", which only works with an app access token). To send
  ## messages with a user access token, "user:write:chat" is enough.
  BroadcasterScopes* = @["user:read:chat", "user:write:chat"]
  ## The bot also requires `moderator:manage:chat_messages` for !vanish
  ## (the broadcaster must have added it as a moderator: /mod <bot>).
  BotScopes* = @["user:read:chat", "user:write:chat", "moderator:manage:chat_messages"]

proc shutdownHandler() {.noconv.} =
  ## Synchronous handler for Ctrl+C / SIGTERM: completes shutdownFuture
  ## (the rest of the shutdown sequence is async and exits from runBot)
  if not shutdownFuture.finished:
    shutdownFuture.complete()

proc parseCliArgs*(params: seq[string] = commandLineParams()): bool =
  ## Parses the CLI arguments and returns true if --bot is present
  for p in params:
    if p == "--bot":
      return true
  false

proc checkBroadcasterTokenExists*(): bool =
  ## Checks whether broadcaster_token.json exists
  fileExists(tokenPath(tkBroadcaster))

proc resolveIds*(token: TokenSet, config: BotConfig, tokenKind: TokenKind): Future[(string, string)] {.async.} =
  ## Resolves broadcasterId and botId
  if tokenKind == tkBroadcaster:
    # same account: broadcaster and bot coincide
    result = (token.userId, token.userId)
  else:
    # the target channel is resolved from the config: any valid token can
    # resolve the public ID of another user
    let u = await getUserByLogin(token.accessToken, config.channel)
    result = (u.id, token.userId)

proc bootstrap*(
    tokenKind: TokenKind, scopes: seq[string]
): Future[(BotConfig, TwitchChat, CommandRouter, TrophyTracker, AttemptTracker, PluginPlatform)] {.async.} =
  ## Runs the full bootstrap: auth, config, trackers, router, chat, plugins
  botStartTime = now().toTime()
  let token = await authenticate(tokenKind, scopes)
  let config = loadConfig(ConfigPath)
  initLogger()
  info "Config loaded: bot=", config.botName, " channel=", config.channel,
       " prefix=", config.commandPrefix, " language=", config.botLanguage
  createDir(DataDir)
  let trophyTracker = newTrophyTracker(DataDir / "trophies.json")
  let attemptTracker = newAttemptTracker(DataDir / "attempts.json")
  let cooldownTracker = newCooldownTracker()
  let registry = newCommandRegistry()
  let (broadcasterId, botId) = await resolveIds(token, config, tokenKind)
  let chat = newTwitchChat(broadcasterId, botId, token, config, tokenKind)
  let router = newCommandRouter(
    chat, trophyTracker, cooldownTracker, attemptTracker, registry, config)
  # botName must be the REAL LOGIN (for the anti-self-reply guard),
  # not the display name from the config
  router.botName = token.userLogin
  # inter-bot HTTP bus (failure is non-fatal: the bot runs without it)
  let peerBus = newPeerBus(config.botName, config.peerBus.kind, "0.1.0",
                           config.peerBus.host, Port(config.peerBus.port),
                           config.peerBus.peers)
  discard peerBus.start()
  # plugin platform + auto-registration (generated at build time)
  let platform = newPluginPlatform(
    router, trophyTracker, attemptTracker, DataDir,
    token.userLogin, broadcasterId, botId, config.channel, peerBus)
  registerAllPlugins(platform)
  info "Startup complete: ", $platform.router.registry.commands.len,
       " command(s) registered"
  chat.onMessage = proc (msg: ChatMessage) {.async.} =
    await router.process(msg)
  result = (config, chat, router, trophyTracker, attemptTracker, platform)

proc shutdown*(
    chat: TwitchChat,
    trophyTracker: TrophyTracker,
    attemptTracker: AttemptTracker,
    platform: PluginPlatform
) {.async.} =
  ## Runs the shutdown procedure: stops the plugins, disconnects, saves data
  await platform.stop()
  await disconnect(chat)
  await trophyTracker.forceSave()
  await attemptTracker.forceSave()
  info("Shutdown complete")

proc runBot*(
    chat: TwitchChat,
    router: CommandRouter,
    trophyTracker: TrophyTracker,
    attemptTracker: AttemptTracker,
    platform: PluginPlatform
) {.async.} =
  ## Starts the bot: connects chat, waits for shutdown
  await connect(chat)
  info("Bot active: listening to the channel")
  await shutdownFuture
  await shutdown(chat, trophyTracker, attemptTracker, platform)

proc seedDefaults() =
  ## Seeds config/ and commands/ from .example templates (only missing files)
  var created = 0
  for dir in @["config", "commands"]:
    if dirExists(dir):
      for f in walkDirRec(dir):
        if f.endsWith(".example"):
          let target = f[0 ..^ 9]  # strip ".example"
          if not fileExists(target):
            copyFile(f, target)
            inc created
  if created > 0:
    echo "Created ", created, " default file(s) from .example templates"

proc main() {.async.} =
  ## Main function: CLI parsing, bootstrap, start, wait for shutdown
  seedDefaults()
  let isBot = parseCliArgs()
  var tokenKind: TokenKind
  var scopes: seq[string]
  if not isBot:
    tokenKind = tkBroadcaster
    scopes = BroadcasterScopes
  else:
    if not checkBroadcasterTokenExists():
      echo "You must first run the bot without the flag to authorize the broadcaster account."
      quit(1)
    tokenKind = tkBot
    scopes = BotScopes

  echo "Starting up (", tokenKindToString(tokenKind), ")..."
  let (_, chat, router, trophyTracker, attemptTracker, platform) =
    await bootstrap(tokenKind, scopes)
  botStartTime = now().toTime()
  setControlCHook(shutdownHandler)
  when defined(posix):
    proc sigtermHandler(sig: cint) {.noconv.} =
      shutdownHandler()
    discard posix.signal(SIGTERM, sigtermHandler)
  await runBot(chat, router, trophyTracker, attemptTracker, platform)

when isMainModule:
  try:
    waitFor main()
  except CatchableError as e:
    echo "Critical error: ", e.msg
    quit(1)
