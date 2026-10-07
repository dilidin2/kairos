import std/[strutils, times, asyncdispatch, options, tables, os, sequtils]

import kairosbot/plugin
import kairosbot/core/command_router
import kairosbot/data/messages
import kairosbot/commands/registry
import kairosbot/twitch/chat
import kairosbot/utils/chat_helpers

var
  startTime* = now().toTime()
  ## Bot uptime: the info plugin registers at bootstrap, so the
  ## registration time is the bot start
  specs*: Table[string, CommandSpec]
  ## Metadata read from commands.json in register()
  msgTexts*: MsgTexts
  ## Translatable user-facing chat texts from messages.json

proc formatUptime*(startTime: Time): string =
  ## Formats the uptime (days/hours/minutes/seconds)
  let totalSec = int((now().toTime() - startTime).inSeconds)
  let days = totalSec div 86400
  let hours = (totalSec div 3600) mod 24
  let mins = (totalSec div 60) mod 60
  let secs = totalSec mod 60
  if days > 0:
    result = $days & "d " & $hours & "h " & $mins & "m " & $secs & "s"
  elif hours > 0:
    result = $hours & "h " & $mins & "m " & $secs & "s"
  else:
    result = $mins & "m " & $secs & "s"

proc formatCommandsText*(router: CommandRouter): string =
  ## Formats the command list for !commands: one section per category
  ## (one category per plugin) with one line per command (names only;
  ## !help <command> shows the description). Categories are derived from
  ## the registry, so new plugins appear automatically. Aliases (e.g.
  ## translated names set in commands.json) are shown in parentheses
  ## next to the command name.
  for cat in router.registry.listCategories():
    result &= "\n" & capitalizeAscii(cat) & ":"
    for cmd in router.registry.listByCategory(cat):
      result &= "\n" & router.prefix & cmd.name
      if cmd.aliases.len > 0:
        result &= " (" & cmd.aliases.mapIt(router.prefix & it).join(", ") & ")"

proc formatCommandHelp*(cmd: Command): string =
  ## Formats the help for a single command (helpText + cooldown + attempts)
  result = cmd.name & ": " & cmd.helpText
  if cmd.cooldown > 0.0:
    result &= msgText(msgTexts, "help_cooldown", " | cooldown: {s}s")
      .replace("{s}", $int(cmd.cooldown))
  if cmd.maxAttemptsPerDay > 0:
    result &= msgText(msgTexts, "help_attempts", " | max {n} attempts/day")
      .replace("{n}", $cmd.maxAttemptsPerDay)

proc cmdCommands*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !commands - lists all the commands grouped by category. safeSend
  ## splits the text into messages under MaxMessageLength (with a short
  ## delay between them), so the chat is not flooded with one line per
  ## message nor does any message hit the Twitch length limit.
  await safeSend(router.chat,
    msgText(msgTexts, "commands_header", "{user}, here are all the commands:")
      .replace("{user}", msg.username) & formatCommandsText(router))

proc cmdHelp*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !help <command> - shows info about a specific command
  let args = msg.args.strip()
  if args.len == 0:
    await safeSend(router.chat,
      msgText(msgTexts, "help_usage", "{user}, usage: {prefix}help <command>")
        .replace("{user}", msg.username)
        .replace("{prefix}", router.prefix))
    return
  let name = args.splitWhitespace()[0]
  let opt = router.registry.get(name)
  if opt.isNone:
    await safeSend(router.chat,
      msgText(msgTexts, "unknown_command", "{user}, unknown command: {prefix}{name}")
        .replace("{user}", msg.username)
        .replace("{prefix}", router.prefix)
        .replace("{name}", name))
  else:
    await safeSend(router.chat, msg.username & ", " & formatCommandHelp(opt.get()))

proc cmdUptime*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !uptime - shows how long the bot has been online
  await safeSend(router.chat,
    msgText(msgTexts, "uptime", "{user}, I've been online for {time}")
      .replace("{user}", msg.username)
      .replace("{time}", formatUptime(startTime)))

proc cmdPing*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !ping - simple reply
  await safeSend(router.chat,
    msgText(msgTexts, "ping", "{user}, pong 🏓").replace("{user}", msg.username))

proc register*(ctx: PluginContext) =
  if not ctx.isEnabled():
    echo "[PLUGIN] info: disabled in config.json"
    return
  msgTexts = loadMsgTexts(ctx.dir / "messages.json")
  specs = loadCommandSpecs(ctx.dir / "commands.json")
  var handlers: Table[string, CommandHandler]
  handlers["commands"] = cmdCommands
  handlers["help"] = cmdHelp
  handlers["uptime"] = cmdUptime
  handlers["ping"] = cmdPing
  registerCommands(ctx, specs, handlers)
