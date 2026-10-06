import std/[strutils, random, asyncdispatch, tables, json, os]

import kairosbot/plugin
import kairosbot/core/command_router
import kairosbot/commands/registry
import kairosbot/core/trophy_tracker
import kairosbot/data/persistence
import kairosbot/twitch/chat
import kairosbot/utils/chat_helpers

var
  content*: Table[string, seq[string]]
  ## Content lists read from content.json: roasts, jokes, truths, dares
  trophyTexts*: Table[string, TrophyText]
  ## Translatable trophy texts from trophies.json

# --- Contenuti -----------------------------------------------------------------------

proc loadContent*(path: string) =
  ## Loads content.json into a table list->seq[string]. If the file
  ## is missing or malformed, the lists stay empty (the command replies
  ## with a "coming soon" message instead of crashing).
  content = initTable[string, seq[string]]()
  if not fileExists(path):
    echo "[PLUGIN] fun: content.json missing: ", path
    return
  let node = loadJson(path)
  if node.kind != JObject:
    echo "[PLUGIN] fun: content.json malformed: ", path
    return
  for key, value in node.pairs:
    if value.kind == JArray:
      var list: seq[string]
      for item in value:
        list.add(item.getStr)
      content[key] = list

proc pick*(listName: string): string =
  ## Picks a random element from a list ("" if empty)
  let list = content.getOrDefault(listName, @[])
  if list.len == 0:
    result = ""
  else:
    result = list[rand(list.len - 1)]

# --- Trofei --------------------------------------------------------------------------

proc createRoastRules*(): seq[TrophyRule] =
  ## Trophy rules for !roast
  result = @[
    TrophyRule(name: "Hot Sauce", eventType: "roast", threshold: 1,
      description: "First time you got roasted", ruleType: trtTotal),
    TrophyRule(name: "Roast Master", eventType: "roast", threshold: 10,
      description: "Got roasted 10 times", ruleType: trtTotal),
  ]

proc createJokeRules*(): seq[TrophyRule] =
  ## Trophy rules for !joke
  result = @[
    TrophyRule(name: "Class Clown", eventType: "joke", threshold: 1,
      description: "First joke told", ruleType: trtTotal),
    TrophyRule(name: "Comedian", eventType: "joke", threshold: 10,
      description: "Told 10 jokes", ruleType: trtTotal),
  ]

# --- Handlers ---------------------------------------------------------------------------

proc sendTrophyNotifs(chat: TwitchChat, username: string,
                      trophies: seq[Trophy]) {.async.} =
  let tpl = trophyText(trophyTexts, "unlock", "",
    "🏆 {user} unlocked the trophy \"{name}\"!")
  for t in trophies:
    let msg = tpl.message.replace("{user}", username).replace("{name}", t.name)
    await safeSend(chat, msg)

proc cmdRoast*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !roast [user] - random insult to the requester or the given user
  let target = msg.args.strip()
  let roast = pick("roasts")
  if roast.len == 0:
    await safeSend(router.chat, "The roasts are still loading, hang tight!")
    return
  let who = if target.len > 0: target else: msg.username
  let trophies = router.trophyTracker.recordEvent(msg.username, "roast", "roast")
  await safeSend(router.chat, who & ", " & roast)
  await sendTrophyNotifs(router.chat, msg.username, trophies)

proc cmdJoke*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !joke - random joke
  let joke = pick("jokes")
  if joke.len == 0:
    await safeSend(router.chat, "The jokes are still loading, hang tight!")
    return
  let trophies = router.trophyTracker.recordEvent(msg.username, "joke", "joke")
  await safeSend(router.chat, msg.username & ", " & joke)
  await sendTrophyNotifs(router.chat, msg.username, trophies)

proc cmdTruth*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !truth - random truth about the user
  let truth = pick("truths")
  if truth.len == 0:
    await safeSend(router.chat, "The truths are still loading, hang tight!")
    return
  await safeSend(router.chat, msg.username & ", " & truth)

proc cmdDare*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !dare - random dare for the user
  let dare = pick("dares")
  if dare.len == 0:
    await safeSend(router.chat, "The dares are still loading, hang tight!")
    return
  await safeSend(router.chat, msg.username & ", your dare: " & dare)

# --- Registration ------------------------------------------------------------------------

proc register*(ctx: PluginContext) =
  if not ctx.isEnabled():
    echo "[PLUGIN] fun: disabled in config.json"
    return
  loadContent(ctx.dir / "content.json")
  trophyTexts = loadTrophyTexts(ctx.dir / "trophies.json")
  let specs = loadCommandSpecs(ctx.dir / "commands.json")
  var handlers: Table[string, CommandHandler]
  handlers["roast"] = cmdRoast
  handlers["joke"] = cmdJoke
  handlers["truth"] = cmdTruth
  handlers["dare"] = cmdDare
  registerCommands(ctx, specs, handlers)
  # trophy rules from commands.json, built-in defaults as fallback
  let roastRules = loadTrophyRules(specs.getOrDefault("roast", CommandSpec(name: "roast")))
  ctx.trophyRules("roast", if roastRules.len > 0: roastRules else: createRoastRules())
  let jokeRules = loadTrophyRules(specs.getOrDefault("joke", CommandSpec(name: "joke")))
  ctx.trophyRules("joke", if jokeRules.len > 0: jokeRules else: createJokeRules())
