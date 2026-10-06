import std/[strutils, tables, json, os, math, asyncdispatch, options, times]

import kairosbot/plugin
import kairosbot/core/command_router
import kairosbot/core/trophy_tracker
import kairosbot/core/economy
import kairosbot/data/persistence
import kairosbot/commands/registry
import kairosbot/twitch/chat
import kairosbot/utils/chat_helpers
import ./stock_market

var
  pluginCtx*: PluginContext
  market*: StockMarket
  econ*: EconomyService
  tickSeconds*: int = 60
  pnlKing*: float = 100.0
  ## PnL threshold for the "PnL King" trophy (from stocks.json)
  millionaire*: float = 1000.0
  ## portfolio value threshold for the "Stock Millionaire" trophy
  trophyTexts*: Table[string, TrophyText]
  ## Translatable one-off trophy texts from trophies.json

# --- Trophies ------------------------------------------------------------------------

proc checkPortfolioTrophies(router: CommandRouter, user: string) {.async.} =
  ## Checks the portfolio trophies (first to 1000, PnL King) and announces them
  let u = normUser(user)
  let m = trophyText(trophyTexts, "millionaire", "Stock Millionaire",
    "🏆 {user} is the first to {amount} 🪙 in stocks!")
  let mName = m.name.replace("{amount}", $int(millionaire))
  if market.portfolioValue(u) >= millionaire:
    var t = Trophy(name: mName, command: "stocks",
                   unlockedAt: toIsoString(now().toTime()))
    if router.trophyTracker.awardTrophy(u, t):
      let msg = m.message.replace("{user}", u)
        .replace("{amount}", $int(millionaire))
      await safeSend(router.chat, msg)
  let pk = trophyText(trophyTexts, "pnl_king", "PnL King",
    "👑 {user} is the {name}!")
  if market.pnl(u) >= pnlKing:
    var t = Trophy(name: pk.name, command: "stocks",
                   unlockedAt: toIsoString(now().toTime()))
    if router.trophyTracker.awardTrophy(u, t):
      let msg = pk.message.replace("{user}", u).replace("{name}", pk.name)
      await safeSend(router.chat, msg)

proc awardCrashSurvivors(router: CommandRouter, item: string) {.async.} =
  ## Awards "Crash Survivor" to whoever held the crashed stock
  let key = item.toLowerAscii()
  let cs = trophyText(trophyTexts, "crash_survivor", "Crash Survivor",
    "🦴 {user} survived the {item} crash!")
  for user in market.holdings.keys:
    if market.holdings[user].hasKey(key) and market.holdings[user][key] > 0:
      var t = Trophy(name: cs.name, command: "stocks",
                     unlockedAt: toIsoString(now().toTime()))
      if router.trophyTracker.awardTrophy(user, t):
        let msg = cs.message.replace("{user}", user).replace("{item}", item)
        await safeSend(router.chat, msg)

# --- Tick timer --------------------------------------------------------------------

proc doTick() {.async.} =
  ## One market step: random walk + any shocks announced in chat
  let router = pluginCtx.platform.router
  let events = market.tick()
  for (name, shock) in events:
    let arrow = if shock < 0: "📉" else: "📈"
    let pct = int(abs(shock) * 100.0)
    let verb = if shock < 0: "CRASH" else: "SURGE"
    let sign = if shock < 0: "-" else: "+"
    await safeSend(router.chat, arrow & " " & verb & ": " & name & " " & sign & $pct & "%")
    if shock <= -0.20:
      await awardCrashSurvivors(router, name)

# --- Config ------------------------------------------------------------------------

proc loadConfig(ctx: PluginContext) =
  ## Loads stocks.json (system parameters + stock list)
  let path = ctx.dir / "stocks.json"
  if not fileExists(path):
    echo "[PLUGIN] stocks: stocks.json missing: ", path
    return
  let node = loadJson(path)
  if node.kind != JObject:
    echo "[PLUGIN] stocks: stocks.json malformed: ", path
    return
  if node.hasKey("tickSeconds") and node["tickSeconds"].kind == JInt:
    tickSeconds = node["tickSeconds"].getInt
  if node.hasKey("pnlKing") and node["pnlKing"].kind in {JInt, JFloat}:
    pnlKing = node["pnlKing"].getFloat
  if node.hasKey("millionaire") and node["millionaire"].kind in {JInt, JFloat}:
    millionaire = node["millionaire"].getFloat
  # market behaviour (shocks and crash detection)
  if node.hasKey("shockChance") and node["shockChance"].kind == JInt:
    market.shockChance = node["shockChance"].getInt
  if node.hasKey("shockMin") and node["shockMin"].kind == JInt:
    market.shockMin = node["shockMin"].getInt
  if node.hasKey("shockMax") and node["shockMax"].kind == JInt:
    market.shockMax = node["shockMax"].getInt
  if node.hasKey("crashThreshold") and node["crashThreshold"].kind in {JInt, JFloat}:
    market.crashThreshold = node["crashThreshold"].getFloat
  var stocks: seq[Stock] = @[]
  if node.hasKey("stocks") and node["stocks"].kind == JArray:
    for item in node["stocks"]:
      if item.kind != JObject:
        continue
      var s = Stock()
      if item.hasKey("name"):
        s.name = item["name"].getStr
      if item.hasKey("price") and (item["price"].kind == JInt or item["price"].kind == JFloat):
        s.price = item["price"].getFloat
      if item.hasKey("volatility") and (item["volatility"].kind == JInt or item["volatility"].kind == JFloat):
        s.volatility = item["volatility"].getFloat
      if s.name.len > 0 and s.volatility > 0.0:
        stocks.add(s)
  # merge: already persisted stocks keep their price, new ones start from the config
  for s in stocks:
    var st = s
    let key = st.name.toLowerAscii()
    if market.stocks.hasKey(key):
      market.stocks[key].volatility = st.volatility
    else:
      st.prevPrice = st.price
      market.stocks[key] = st

# --- Handlers ---------------------------------------------------------------------------

proc cmdStock*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !stock - stock list with price and trend
  if market.stocks.len == 0:
    await safeSend(router.chat, "No stocks available.")
    return
  var lines: seq[string] = @[]
  for s in market.stocks.values:
    let trend =
      if s.price > s.prevPrice: "📈"
      elif s.price < s.prevPrice: "📉"
      else: "➖"
    lines.add(s.name & ": " & $s.price & " " & trend)
  await safeSend(router.chat, "📊 Stock market:\n" & lines.join("\n"))

proc cmdBuy*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !buy <item> <qty> - buys stocks
  let parts = msg.args.splitWhitespace()
  if parts.len != 2:
    await safeSend(router.chat, msg.username & ", usage: !buy <item> <quantity>")
    return
  let qty = parseInt(parts[1])
  if qty < 1:
    await safeSend(router.chat, msg.username & ", enter a valid quantity")
    return
  # qty already extracted
  let stockOpt = market.stock(parts[0])
  if stockOpt.isNone:
    await safeSend(router.chat, msg.username & ", unknown stock: " & parts[0])
    return
  if econ.isNil:
    await safeSend(router.chat, msg.username & ", the economy is not available")
    return
  let cash = int(round(stockOpt.get().price * float(qty)))
  if not econ.debit(msg.username, cash):
    await safeSend(router.chat, msg.username & ", you only have " &
      $econ.getBalance(msg.username) & " 🪙")
    return
  market.addHolding(msg.username, parts[0], qty, float(cash))
  await safeSend(router.chat, msg.username & " bought " & $qty & " " &
    parts[0] & " for " & $cash & " 🪙")
  await checkPortfolioTrophies(router, msg.username)

proc cmdSell*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !sell <item> <qty> - sells stocks
  let parts = msg.args.splitWhitespace()
  if parts.len != 2:
    await safeSend(router.chat, msg.username & ", usage: !sell <item> <quantity>")
    return
  let qty = parseInt(parts[1])
  if qty < 1:
    await safeSend(router.chat, msg.username & ", enter a valid quantity")
    return
  # qty already extracted
  let stockOpt = market.stock(parts[0])
  if stockOpt.isNone:
    await safeSend(router.chat, msg.username & ", unknown stock: " & parts[0])
    return
  if econ.isNil:
    await safeSend(router.chat, msg.username & ", the economy is not available")
    return
  let cash = int(round(stockOpt.get().price * float(qty)))
  if not market.removeHolding(msg.username, parts[0], qty, float(cash)):
    await safeSend(router.chat, msg.username & ", you don't own " & parts[0])
    return
  econ.credit(msg.username, cash)
  await safeSend(router.chat, msg.username & " sold " & $qty & " " &
    parts[0] & " for " & $cash & " 🪙")
  await checkPortfolioTrophies(router, msg.username)

proc cmdPortfolio*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !portfolio - holdings + value + PnL
  let holdings = market.holdingsList(msg.username)
  if holdings.len == 0:
    await safeSend(router.chat, msg.username & ", you don't own any stocks")
    return
  var lines: seq[string] = @[]
  for (item, qty) in holdings:
    let s = market.stock(item).get()
    lines.add($qty & " " & s.name & " (" & $round2(float(qty) * s.price) & " 🪙)")
  let value = market.portfolioValue(msg.username)
  let profit = market.pnl(msg.username)
  let sign = if profit >= 0: "+" else: ""
  await safeSend(router.chat, "💼 " & msg.username & "'s portfolio:\n" &
    lines.join("\n") & "\nTotal: " & $value & " 🪙 (PnL " & sign & $profit & ")")

# --- Registration ------------------------------------------------------------------------

proc register*(ctx: PluginContext) =
  if not ctx.isEnabled():
    echo "[PLUGIN] stocks: disabled in config.json"
    return
  pluginCtx = ctx
  let dataDir = ctx.platform.dataDir
  market = newStockMarket(dataDir / "stocks.json")
  econ = cast[EconomyService](ctx.platform.services.getOrDefault("economy", nil))
  trophyTexts = loadTrophyTexts(ctx.dir / "trophies.json")
  loadConfig(ctx)
  # catch-up: if there was an open market, it does a single update tick
  if market.lastTick > 0.0:
    discard market.tick()
  # periodic timer
  ctx.every(tickSeconds, doTick)
  # shutdown hook: saves the market
  ctx.onShutdown(proc () {.async.} =
    await market.forceSave()
  )

  let specs = loadCommandSpecs(ctx.dir / "commands.json")
  var handlers: Table[string, CommandHandler]
  handlers["stock"] = cmdStock
  handlers["buy"] = cmdBuy
  handlers["sell"] = cmdSell
  handlers["portfolio"] = cmdPortfolio
  registerCommands(ctx, specs, handlers)
