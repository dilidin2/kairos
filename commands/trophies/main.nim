import std/[strutils, tables, asyncdispatch, os, json]

import kairosbot/plugin
import kairosbot/core/command_router
import kairosbot/commands/registry
import kairosbot/core/trophy_tracker
import kairosbot/data/persistence
import kairosbot/twitch/chat
import kairosbot/utils/chat_helpers

var
  msgTexts*: Table[string, string]
  ## Translatable user-facing chat texts from messages.json

# --- Texts --------------------------------------------------------------------

proc loadMsgs(path: string): Table[string, string] =
  ## Loads messages.json: flat key -> template pairs
  result = initTable[string, string]()
  if not fileExists(path):
    return
  let node = loadJson(path)
  if node.kind != JObject:
    return
  for key, value in node.pairs:
    if value.kind == JString:
      result[key] = value.getStr

proc mtext(key, fallback: string): string =
  ## A user-facing message template (messages.json) with English fallback
  if msgTexts.hasKey(key):
    result = msgTexts[key]
  else:
    result = fallback

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
    result.add(mtext("group_line", "📦 {command}:")
               .replace("{command}", command))
    for t in grouped[command]:
      result.add(mtext("trophy_line", "  🏆 {name}").replace("{name}", t.name))

proc cmdTrophy*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !trophy [user] - shows a user's trophies (their own if omitted)
  let target = msg.args.strip()
  let user = if target.len > 0: target else: msg.username
  let trophies = router.trophyTracker.getUserTrophies(user)
  if trophies.len == 0:
    await safeSend(router.chat,
      mtext("no_trophies", "{user} has no trophies yet. Play and unlock some!")
      .replace("{user}", user))
  else:
    let lines = formatTrophies(trophies)
    await safeSend(router.chat,
      mtext("header", "Trophies of {user}:").replace("{user}", user) &
      "\n" & lines.join("\n"))

proc register*(ctx: PluginContext) =
  if not ctx.isEnabled():
    echo "[PLUGIN] trophies: disabled in config.json"
    return
  msgTexts = loadMsgs(ctx.dir / "messages.json")
  let specs = loadCommandSpecs(ctx.dir / "commands.json")
  var handlers: Table[string, CommandHandler]
  handlers["trophy"] = cmdTrophy
  registerCommands(ctx, specs, handlers)
