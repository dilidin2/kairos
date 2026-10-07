import std/[strutils, tables, json, os, times, asyncdispatch, parseutils, sequtils]

import kairosbot/plugin
import kairosbot/core/command_router
import kairosbot/commands/registry
import kairosbot/core/economy
import kairosbot/core/trophy_tracker
import kairosbot/data/messages
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
  msgTexts*: MsgTexts
  ## Translatable user-facing chat texts from messages.json
  nextPayAt*: Table[string, int]
  ## username (lowercase) -> unix seconds of the user's next payroll
  payrollPath: string
  ## where nextPayAt is persisted (data/economy_payroll.json)

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

# --- Payroll ---------------------------------------------------------------------------

type
  PayrollConfig* = object
    ## Periodic payroll: credits every known user on an interval so nobody
    ## gets stuck at 0 coins
    amount*: int
    ## coins credited to each user per payroll
    intervalMinutes*: int
    ## how often the payroll runs (minutes)
    message*: string
    ## per-user chat announcement (placeholders {user}, {amount})
    firstPayTrophy*: string
    ## trophy unlocked on the first payroll

proc loadPayrollConfig*(path: string): PayrollConfig =
  ## Payroll config from economy.json; defaults if missing
  result = PayrollConfig(
    amount: 10,
    intervalMinutes: 60,
    message: "💸 {user}, added {amount} 🪙 to your balance!",
    firstPayTrophy: "First Paycheck")
  let node = loadJson(path)
  if node.kind != JObject or not node.hasKey("payroll") or
      node["payroll"].kind != JObject:
    return
  let p = node["payroll"]
  if p.hasKey("amount") and p["amount"].kind == JInt:
    result.amount = p["amount"].getInt
  if p.hasKey("intervalMinutes") and p["intervalMinutes"].kind == JInt:
    result.intervalMinutes = p["intervalMinutes"].getInt
  if p.hasKey("message") and p["message"].kind == JString:
    result.message = p["message"].getStr
  if p.hasKey("firstPayTrophy") and p["firstPayTrophy"].kind == JString:
    result.firstPayTrophy = p["firstPayTrophy"].getStr

proc payrollTick*(chat: TwitchChat, tracker: TrophyTracker,
                 cfg: PayrollConfig, nowSec: int = int(epochTime())) {.async.} =
  ## One payroll tick with a PER-USER clock: each user is paid `interval`
  ## minutes after their own first interaction, so nobody gets stuck at 0.
  ## Brand-new users are scheduled; users whose pay is due get credited and
  ## are announced publicly (with the first-pay trophy on the first one).
  let interval = cfg.intervalMinutes * 60
  var dirty = false
  # schedule users we haven't seen before (first pay `interval` from now)
  for user in toSeq(svc.balances.keys):
    if not nextPayAt.hasKey(user):
      nextPayAt[user] = nowSec + interval
      dirty = true
  # credit everyone whose payroll is due
  var paid: seq[string] = @[]
  for user in toSeq(nextPayAt.keys):
    if nextPayAt[user] <= nowSec:
      svc.credit(user, cfg.amount)
      # no catch-up storm after downtime: next pay is >= `interval` from now
      nextPayAt[user] = if nextPayAt[user] + interval < nowSec:
                          nowSec + interval
                        else:
                          nextPayAt[user] + interval
      paid.add(user)
      dirty = true
  for user in paid:
    # public first-pay trophy announcement (only on the first payroll)
    let trophies = tracker.recordEvent(user, "payroll", "payday")
    await sendTrophyUnlocks(chat, trophyTexts, user, trophies)
    let msg = cfg.message.replace("{user}", user).replace("{amount}", $cfg.amount)
    await safeSend(chat, msg)
  if dirty:
    saveTyped(payrollPath, nextPayAt)

# --- Trophies --------------------------------------------------------------------------

proc createPayRules*(): seq[TrophyRule] =
  ## Trophy rules for !pay
  result = @[
    TrophyRule(name: "Charity Case", eventType: "pay", threshold: 10,
      description: "Sent 10 payments", ruleType: trtTotal),
  ]

# --- Handlers ---------------------------------------------------------------------------

proc cmdBalance*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !balance - current balance
  let bal = svc.getBalance(msg.username)
  await safeSend(router.chat,
    msgText(msgTexts, "balance", "{user}, your balance: {balance} 🪙")
      .replace("{user}", msg.username)
      .replace("{balance}", $bal))

proc cmdPay*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !pay <user> <amount> - give coins
  let parts = msg.args.strip().splitWhitespace()
  if parts.len != 2:
    await safeSend(router.chat,
      msgText(msgTexts, "pay_usage", "{user}, usage: !pay <user> <amount>")
        .replace("{user}", msg.username))
    return
  let to = parts[0]
  var amount = 0
  if parseInt(parts[1], amount) == 0 or amount < 1:
    await safeSend(router.chat,
      msgText(msgTexts, "invalid_amount", "{user}, enter a valid amount")
        .replace("{user}", msg.username))
    return
  if svc.transfer(msg.username, to, amount):
    let trophies = router.trophyTracker.recordEvent(msg.username, "pay", "pay")
    # "first to reach the threshold" for the recipient
    if svc.checkFirstTo(to):
      let ft = trophyText(trophyTexts, "first_to", "First to 1000",
        "🏆 {user} unlocked the trophy \"{name}\"!")
      let ftName = ft.name.replace("{amount}", $svc.firstTo)
      discard router.trophyTracker.awardTrophy(to, newTrophy(ftName, "economy"))
      let msg = ft.message.replace("{user}", to).replace("{name}", ftName)
      await safeSend(router.chat, msg)
    await safeSend(router.chat,
      msgText(msgTexts, "paid", "{user} gave {amount} 🪙 to {to}!")
        .replace("{user}", msg.username)
        .replace("{amount}", $amount)
        .replace("{to}", to))
    await sendTrophyUnlocks(router.chat, trophyTexts, msg.username, trophies)
  else:
    await safeSend(router.chat,
      msgText(msgTexts, "cannot_afford", "{user}, you can't afford that — check your balance")
      .replace("{user}", msg.username))

proc cmdRich*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !rich - top balances (N from the `rich_top` param, default 5)
  let spec = specs.getOrDefault("rich", CommandSpec(name: "rich"))
  let n = specIntParam(spec, "rich_top", 5, 1)
  let top = svc.topBalances(n)
  if top.len == 0:
    await safeSend(router.chat, msgText(msgTexts, "rich_empty",
      "No balances yet — be the first to play!"))
    return
  let medals = @["🥇", "🥈", "🥉"]
  var lines: seq[string] = @[]
  for i, (user, bal) in top:
    let medal = if i < medals.len: medals[i] else: $(i + 1) & "."
    lines.add(medal & " " & user & ": " & $bal & " 🪙")
  await safeSend(router.chat,
    msgText(msgTexts, "rich_header", "Top balances:") & "\n" & lines.join("\n"))

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
  msgTexts = loadMsgTexts(ctx.dir / "messages.json")
  var handlers: Table[string, CommandHandler]
  handlers["balance"] = cmdBalance
  handlers["pay"] = cmdPay
  handlers["rich"] = cmdRich
  registerCommands(ctx, specs, handlers)
  # trophy rules from commands.json, built-in default as fallback
  let fromJson = loadTrophyRules(specs.getOrDefault("pay", CommandSpec(name: "pay")))
  ctx.trophyRules("pay", if fromJson.len > 0: fromJson else: createPayRules())

  # periodic payroll: a per-user clock so nobody gets stuck at 0
  let payroll = loadPayrollConfig(ctx.dir / "economy.json")
  if payroll.amount > 0 and payroll.intervalMinutes > 0:
    ctx.trophyRules("payroll", @[
      TrophyRule(name: payroll.firstPayTrophy, eventType: "payday",
        threshold: 1, description: "Received your first payroll",
        ruleType: trtTotal)
    ])
    payrollPath = ctx.platform.dataDir / "economy_payroll.json"
    nextPayAt = loadTyped[Table[string, int]](payrollPath,
                    initTable[string, int]())
    let chat = ctx.platform.router.chat
    let tracker = ctx.platform.trophyTracker
    # fixed 1-minute tick so each user's per-user due time is caught on time
    ctx.every(60, proc () {.async.} =
      await payrollTick(chat, tracker, payroll)
    )
  else:
    echo "[PLUGIN] economy: payroll disabled (amount/interval <= 0)"

  proc onShut() {.async.} =
    await svc.forceSave()
    if payrollPath.len > 0:
      saveTyped(payrollPath, nextPayAt)
  ctx.onShutdown(onShut)
