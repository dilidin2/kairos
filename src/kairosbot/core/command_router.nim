import std/[asyncdispatch, strutils, tables, options, logging]

import ../config/config
import ../twitch/chat
import ../commands/registry
import ./cooldown_tracker
import ./attempt_tracker
import ./trophy_tracker
import ../utils/chat_helpers

type
  CommandHandler* = proc (msg: ChatMessage, cmd: Command, router: CommandRouter): Future[void]

  CommandRouter* = ref object
    chat*: TwitchChat
    trophyTracker*: TrophyTracker
    cooldownTracker*: CooldownTracker
    attemptTracker*: AttemptTracker
    registry*: CommandRegistry
    handlers*: Table[string, CommandHandler]
    config*: BotConfig
    botName*: string
    prefix*: string
    subscribers*: seq[MessageHandler]

proc newCommandRouter*(
    chat: TwitchChat,
    trophyTracker: TrophyTracker,
    cooldownTracker: CooldownTracker,
    attemptTracker: AttemptTracker,
    registry: CommandRegistry,
    config: BotConfig
): CommandRouter =
  ## Creates a new CommandRouter
  result = CommandRouter(
    chat: chat,
    trophyTracker: trophyTracker,
    cooldownTracker: cooldownTracker,
    attemptTracker: attemptTracker,
    registry: registry,
    handlers: initTable[string, CommandHandler](),
    config: config,
    botName: config.botName,
    prefix: config.commandPrefix,
    subscribers: @[]
  )

proc registerHandler*(router: CommandRouter, name: string, handler: CommandHandler) =
  ## Registers the handler proc for a command
  router.handlers[name] = handler

proc mtext*(router: CommandRouter, key, fallback: string): string =
  ## A user-facing message template (config/messages.json) with an
  ## English fallback
  if router.config.messages.hasKey(key):
    result = router.config.messages[key]
  else:
    result = fallback

proc renderText(router: CommandRouter, key, fallback: string,
                replacements: openArray[tuple[ph, val: string]]): string =
  ## mtext with the given {placeholder}s substituted
  var text = router.mtext(key, fallback)
  for r in replacements:
    text = text.replace(r.ph, r.val)
  result = text

proc parseCommand*(router: CommandRouter, content: string): Option[(string, string)] =
  ## Parses command name and arguments from the message content

  if not content.startsWith(router.prefix):
    return none((string, string))

  let rest = content[router.prefix.len .. ^1].strip()

  if rest.len == 0:
    return none((string, string))

  let parts = rest.splitWhitespace(maxsplit = 1)

  let name = parts[0]
  
  let args = if parts.len > 1: parts[1] else: ""

  return some((name, args))

proc sendCooldownMessage*(router: CommandRouter, msg: ChatMessage, command: string, remaining: float) {.async.} =
  ## Sends a cooldown message to chat
  let text = renderText(router, "cooldown",
                        "{user}, {prefix}{command} is on cooldown, retry in {secs} seconds",
                        [("{user}", msg.username),
                         ("{prefix}", router.prefix),
                         ("{command}", command),
                         ("{secs}", $remaining.int)])

  await safeSend(router.chat, text)

proc sendNoAttemptsMessage*(router: CommandRouter, msg: ChatMessage, command: string) {.async.} =
  ## Sends a "no attempts left" message to chat
  let text = renderText(router, "no_attempts",
                        "{user}, you have no attempts left for: {prefix}{command}",
                        [("{user}", msg.username),
                         ("{prefix}", router.prefix),
                         ("{command}", command)])

  await safeSend(router.chat, text)

proc sendErrorMessage*(router: CommandRouter, msg: ChatMessage) {.async.} =
  ## Sends a generic error message to chat
  let text = renderText(router, "error",
                        "{user}, this is a generic error message, we have no clue why this did not work -.-",
                        [("{user}", msg.username)])

  await safeSend(router.chat, text)

proc handleCommand*(router: CommandRouter, msg: ChatMessage, commandName: string, args: string) {.async.} =
  ## Runs the full logic of a command with try/except
  var msg = msg
  msg.args = args

  let command = router.registry.get(commandName).get()
  # the canonical name (the alias is resolved in the registry): handler,
  # attempts and cooldown are keyed on it
  let canonical = command.name
  if not router.handlers.hasKey(canonical):
    # command in the registry but without a handler: incomplete configuration,
    # do not crash (rule: the router does not propagate exceptions)
    warn "Command without handler: !", canonical
    await sendErrorMessage(router, msg)
    return
  let handler = router.handlers[canonical]

  info "Command: !", canonical, " by ", msg.username,
       (if args.len > 0: " args=" & args else: "")

  if command.maxAttemptsPerDay > 0:
    router.attemptTracker.useAttempt(msg.username, canonical)

  try:
    await handler(msg, command, router)
    info "Command done: !", canonical, " (", msg.username, ")"
  except CatchableError as e:
    error "Command error: !", canonical, " — ", e.name, ": ", e.msg
    echo getStackTrace()
    await sendErrorMessage(router, msg)

  router.cooldownTracker.setCooldown(msg.username, canonical, command.cooldown)

proc process*(router: CommandRouter, msg: ChatMessage) {.async.} =
  ## Processes a chat message: parse, lookup, cooldown, attempts, handler execution

  # ignore our own messages: bot badge (verified Twitch bots) or
  # username equal to the bot's (case-insensitive: Twitch
  # usernames are case-insensitive)
  if msg.isBot or msg.username.toLower() == router.botName.toLower():
    return

  # plugin subscribers: every message goes to the subscribers
  for sub in router.subscribers:
    asyncCheck: sub(msg)

  let opt = parseCommand(router, msg.content)
  
  if opt.isNone:
    return

  let (name, args) = opt.get()

  let cmdOpt = router.registry.get(name)

  if cmdOpt.isNone:
    debug "Unknown command: ", name, " (", msg.username, ")"
    return
  let command = cmdOpt.get()
  # canonical name: the alias is already resolved in the registry, so cooldown,
  # attempts and handler are keyed on the same string
  let canonical = command.name

  # minimum role check (badges already extracted from the events)
  case command.role
  of crEveryone:
    discard
  of crMod:
    if not (msg.badges.contains("moderator") or
            msg.badges.contains("broadcaster")):
      debug "Denied (mod role required): !", canonical, " by ", msg.username
      await safeSend(router.chat,
        renderText(router, "mod_required",
                   "{user}, you need a moderator role to use {prefix}{command}",
                   [("{user}", msg.username),
                    ("{prefix}", router.prefix),
                    ("{command}", canonical)]))
      return
  of crBroadcaster:
    if not msg.badges.contains("broadcaster"):
      debug "Denied (broadcaster role required): !", canonical, " by ", msg.username
      await safeSend(router.chat,
        renderText(router, "broadcaster_required",
                   "{user}, only the broadcaster can use {prefix}{command}",
                   [("{user}", msg.username),
                    ("{prefix}", router.prefix),
                    ("{command}", canonical)]))
      return

  if router.cooldownTracker.isOnCooldown(msg.username, canonical):
    let remaining = router.cooldownTracker.getRemaining(msg.username, canonical)

    debug "On cooldown: !", canonical, " for ", msg.username
    await sendCooldownMessage(router, msg, canonical, remaining)
    return

  if command.maxAttemptsPerDay > 0:
    if not router.attemptTracker.hasAttemptsLeft(msg.username, canonical, command.maxAttemptsPerDay):
      debug "No attempts left: !", canonical, " for ", msg.username
      await sendNoAttemptsMessage(router, msg, canonical)
      return 

  await handleCommand(router, msg, canonical, args)
