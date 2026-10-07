import std/[strutils, tables, os, asyncdispatch]

import kairosbot/plugin
import kairosbot/core/command_router
import kairosbot/commands/registry
import kairosbot/data/messages
import kairosbot/data/persistence
import kairosbot/twitch/chat
import kairosbot/twitch/helix
import kairosbot/utils/chat_helpers
import ./message_log

const
  ModScope = "moderator:manage:chat_messages"

var
  pluginCtx*: PluginContext
  log*: MessageLog = newMessageLog()
  ## Ring buffer of the session's messages
  specs*: Table[string, CommandSpec]
  ## Metadata read from commands.json in register()
  msgTexts*: MsgTexts
  ## Translatable user-facing chat texts from messages.json

proc onNewMessage(msg: ChatMessage) {.async.} =
  ## Fills the ring buffer (this live only)
  log.add(msg.username, msg.messageId)

proc hasModScope(p: PluginPlatform): bool =
  ## The bot token has the moderation scope
  result = p.router.chat.token.scope.contains(ModScope)

proc cmdVanish*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !vanish - deletes all MY messages of the session
  let p = pluginCtx.platform
  # the bot must have the moderation scope
  if not hasModScope(p):
    await safeSend(router.chat,
      msgText(msgTexts, "need_mod", "{user}, I need to be a moderator to use !vanish")
      .replace("{user}", msg.username))
    return
  # the broadcaster's messages cannot be deleted (API limitation)
  if msg.username.toLowerAscii() == p.channel.toLowerAscii():
    await safeSend(router.chat,
      msgText(msgTexts, "broadcaster", "{user}, I can't make the broadcaster vanish")
      .replace("{user}", msg.username))
    return
  # dramatic effect (delay from the `dramatic_delay_ms` param)
  let spec = specs.getOrDefault("vanish", CommandSpec(name: "vanish"))
  let delayMs = specIntParam(spec, "dramatic_delay_ms", 1000, 0)
  await sleepAsync(delayMs)
  let ids = log.messagesOf(msg.username)
  var gone = 0
  for id in ids:
    var res = await deleteChatMessage(
      p.router.chat.token.accessToken, p.broadcasterId, p.botId, id)
    if res == drRateLimited:
      # pause and retry once
      await sleepAsync(1000)
      res = await deleteChatMessage(
        p.router.chat.token.accessToken, p.broadcasterId, p.botId, id)
    if res == drDeleted or res == drAlreadyGone:
      gone += 1
  # clears the user's log
  log.clearUser(msg.username)
  await safeSend(router.chat,
    msgText(msgTexts, "secret", "{user}, i see your secret 🕵️")
    .replace("{user}", msg.username))

# --- Registration ------------------------------------------------------------------------

proc register*(ctx: PluginContext) =
  if not ctx.isEnabled():
    echo "[PLUGIN] vanish: disabled in config.json"
    return
  pluginCtx = ctx
  # fills the ring buffer on every chat message
  ctx.onMessage(onNewMessage)
  msgTexts = loadMsgTexts(ctx.dir / "messages.json")
  specs = loadCommandSpecs(ctx.dir / "commands.json")
  var handlers: Table[string, CommandHandler]
  handlers["vanish"] = cmdVanish
  registerCommands(ctx, specs, handlers)
