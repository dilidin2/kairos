import std/[strutils, tables, json, os, times, asyncdispatch, parseutils]

import kairosbot/plugin
import kairosbot/core/command_router
import kairosbot/commands/registry
import kairosbot/core/economy
import kairosbot/core/trophy_tracker
import kairosbot/data/persistence
import kairosbot/twitch/chat
import kairosbot/utils/chat_helpers

const
  ServiceKey = "economy"

var
  svc*: EconomyService
  ## Economy service, built in register(): the handlers read it from here
  specs*: Table[string, CommandSpec]
  ## Metadata read from commands.json in register()
  trophyTexts*: Table[string, TrophyText]
  ## Translatable one-off trophy texts from trophies.json

# --- Parameters -----------------------------------------------------------------------

proc loadEconomyParams*(path: string): (int, int, int, int) =
  ## (startBalance, minBet, bigWinner, firstTo) from economy.json;
  ## defaults if missing
  result = (100, 1, DefaultBigWinner, DefaultFirstTo)
  let node = loadJson(path)
  if node.kind != JObject:
    return
  if node.hasKey("startBalance") and node["startBalance"].kind == JInt:
    result[0] = node["startBalance"].getInt
  if node.hasKey("minBet") and node["minBet"].kind == JInt:
    result[1] = node["minBet"].getInt
  if node.hasKey("bigWinner") and node["bigWinner"].kind == JInt:
    result[2] = node["bigWinner"].getInt
  if node.hasKey("firstTo") and node["firstTo"].kind == JInt:
    result[3] = node["firstTo"].getInt

# --- Trophies --------------------------------------------------------------------------

proc createPayRules*(): seq[TrophyRule] =
  ## Trophy rules for !pay
  result = @[
    TrophyRule(name: "Charity Case", eventType: "pay", threshold: 10,
      description: "Sent 10 payments", ruleType: trtTotal),
  ]

proc sendTrophyNotifs(chat: TwitchChat, username: string,
                      trophies: seq[Trophy]) {.async.} =
  let tpl = trophyText(trophyTexts, "unlock", "",
    "🏆 {user} unlocked the trophy \"{name}\"!")
  for t in trophies:
    let msg = tpl.message.replace("{user}", username).replace("{name}", t.name)
    await safeSend(chat, msg)

# --- Handlers ---------------------------------------------------------------------------

proc cmdBalance*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !balance - current balance
  let bal = svc.getBalance(msg.username)
  await safeSend(router.chat, msg.username & ", your balance: " & $bal & " 🪙")

proc cmdPay*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !pay <user> <amount> - give coins
  let parts = msg.args.strip().splitWhitespace()
  if parts.len != 2:
    await safeSend(router.chat, msg.username & ", usage: !pay <user> <amount>")
    return
  let to = parts[0]
  var amount = 0
  if parseInt(parts[1], amount) == 0 or amount < 1:
    await safeSend(router.chat, msg.username & ", enter a valid amount")
    return
  if svc.transfer(msg.username, to, amount):
    let trophies = router.trophyTracker.recordEvent(msg.username, "pay", "pay")
    # "first to reach the threshold" for the recipient
    if svc.checkFirstTo(to):
      let ft = trophyText(trophyTexts, "first_to", "First to 1000",
        "🏆 {user} unlocked the trophy \"{name}\"!")
      let ftName = ft.name.replace("{amount}", $svc.firstTo)
      discard router.trophyTracker.awardTrophy(to,
        Trophy(name: ftName, command: "economy",
               unlockedAt: toIsoString(now().toTime())))
      let msg = ft.message.replace("{user}", to).replace("{name}", ftName)
      await safeSend(router.chat, msg)
    await safeSend(router.chat,
      msg.username & " gave " & $amount & " 🪙 to " & to & "!")
    await sendTrophyNotifs(router.chat, msg.username, trophies)
  else:
    await safeSend(router.chat,
      msg.username & ", you can't afford that — check your balance")

proc cmdRich*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !rich - top balances (N from the `rich_top` param, default 5)
  let spec = specs.getOrDefault("rich", CommandSpec(name: "rich"))
  var n = 5
  if spec.params.hasKey("rich_top") and spec.params["rich_top"].kind == JInt:
    let v = spec.params["rich_top"].getInt
    if v > 0:
      n = v
  let top = svc.topBalances(n)
  if top.len == 0:
    await safeSend(router.chat, "No balances yet — be the first to play!")
    return
  let medals = @["🥇", "🥈", "🥉"]
  var lines: seq[string] = @[]
  for i, (user, bal) in top:
    let medal = if i < medals.len: medals[i] else: $(i + 1) & "."
    lines.add(medal & " " & user & ": " & $bal & " 🪙")
  await safeSend(router.chat, "Top balances:\n" & lines.join("\n"))

# --- Registration ------------------------------------------------------------------------

proc register*(ctx: PluginContext) =
  if not ctx.isEnabled():
    echo "[PLUGIN] economy: disabled in config.json"
    return
  let (sb, mb, bw, ft) = loadEconomyParams(ctx.dir / "economy.json")
  svc = newEconomyService(ctx.statePath, startBalance = sb, minBet = mb,
                          bigWinner = bw, firstTo = ft)
  ctx.platform.services[ServiceKey] = svc

  specs = loadCommandSpecs(ctx.dir / "commands.json")
  trophyTexts = loadTrophyTexts(ctx.dir / "trophies.json")
  var handlers: Table[string, CommandHandler]
  handlers["balance"] = cmdBalance
  handlers["pay"] = cmdPay
  handlers["rich"] = cmdRich
  registerCommands(ctx, specs, handlers)
  # trophy rules from commands.json, built-in default as fallback
  let fromJson = loadTrophyRules(specs.getOrDefault("pay", CommandSpec(name: "pay")))
  ctx.trophyRules("pay", if fromJson.len > 0: fromJson else: createPayRules())

  proc onShut() {.async.} =
    await svc.forceSave()
  ctx.onShutdown(onShut)
