import std/[strutils, tables, asyncdispatch, os]

import kairosbot/plugin
import kairosbot/core/command_router
import kairosbot/commands/registry
import kairosbot/core/trophy_tracker
import kairosbot/data/messages
import kairosbot/data/persistence
import kairosbot/twitch/chat
import kairosbot/utils/chat_helpers

var
  msgTexts*: MsgTexts
  ## Translatable user-facing chat texts from messages.json

proc groupTrophiesByCommand*(trophies: seq[Trophy]): Table[string, seq[Trophy]] =
  ## Groups trophies by command
  result = initTable[string, seq[Trophy]]()
  for t in trophies:
    if not result.hasKey(t.command):
      result[t.command] = @[]
    result[t.command].add(t)

proc formatTrophies*(trophies: seq[Trophy]): seq[string] =
  ## Formats the trophy list for the chat, grouped by command
  let grouped = groupTrophiesByCommand(trophies)
  for command in grouped.keys:
    result.add(msgText(msgTexts, "group_line", "📦 {command}:")
               .replace("{command}", command))
    for t in grouped[command]:
      result.add(msgText(msgTexts, "trophy_line", "  🏆 {name}").replace("{name}", t.name))

proc cmdTrophy*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !trophy [user] - shows a user's trophies (their own if omitted)
  let target = msg.args.strip()
  let user = if target.len > 0: target else: msg.username
  let trophies = router.trophyTracker.getUserTrophies(user)
  if trophies.len == 0:
    await safeSend(router.chat,
      msgText(msgTexts, "no_trophies", "{user} has no trophies yet. Play and unlock some!")
      .replace("{user}", user))
  else:
    let lines = formatTrophies(trophies)
    await safeSend(router.chat,
      msgText(msgTexts, "header", "Trophies of {user}:").replace("{user}", user) &
      "\n" & lines.join("\n"))

proc register*(ctx: PluginContext) =
  if not ctx.isEnabled():
    echo "[PLUGIN] trophies: disabled in config.json"
    return
  msgTexts = loadMsgTexts(ctx.dir / "messages.json")
  let specs = loadCommandSpecs(ctx.dir / "commands.json")
  var handlers: Table[string, CommandHandler]
  handlers["trophy"] = cmdTrophy
  registerCommands(ctx, specs, handlers)
