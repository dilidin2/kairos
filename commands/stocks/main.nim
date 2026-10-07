import std/[strutils, tables, json, os, math, asyncdispatch, options, times, random, sequtils, algorithm]

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
  msgTexts*: Table[string, string]
  ## Translatable user-facing chat texts from messages.json
  newsPhrases*: seq[string]
  ## Pre-crash rumour templates from news.json ({item} placeholder)

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

proc loadNews(ctx: PluginContext): seq[string] =
  ## Loads news.json: an array of rumour templates ({item} placeholder)
  result = @[]
  let path = ctx.dir / "news.json"
  if fileExists(path):
    let node = loadJson(path)
    if node.kind == JArray:
      for p in node:
        if p.kind == JString and p.getStr.len > 0:
          result.add(p.getStr)
  if result.len == 0:
    result = @["📰 Rumour mill: the {item} board is panicking..."]

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
  # toSeq: during the awaits below a user can sell (removeHolding deletes
  # from the table), which would invalidate a live iteration
  for user in toSeq(market.holdings.keys):
    if market.holdings[user].hasKey(key) and market.holdings[user][key] > 0:
      var t = Trophy(name: cs.name, command: "stocks",
                     unlockedAt: toIsoString(now().toTime()))
      if router.trophyTracker.awardTrophy(user, t):
        let msg = cs.message.replace("{user}", user).replace("{item}", item)
        await safeSend(router.chat, msg)

# --- Tick timer --------------------------------------------------------------------

proc doTick() {.async.} =
  ## One market step: news, crashes and surges announced in chat
  let router = pluginCtx.platform.router
  for e in market.tick():
    case e.kind
    of meNews:
      let phrase = newsPhrases[rand(newsPhrases.high)]
      await safeSend(router.chat, phrase.replace("{item}", e.item))
    of meCrash:
      # magnitude is the actual signed change (negative for a crash)
      let txt = mtext("crash", "📉 CRASH: {item} -{pct}%")
        .replace("{item}", e.item)
        .replace("{pct}", $int(round(abs(e.magnitude) * 100.0)))
      await safeSend(router.chat, txt)
      # a meCrash event is by definition a crash (telegraphed by the
      # news), so the survivors are always awarded
      await awardCrashSurvivors(router, e.item)
    of meSurge:
      let txt = mtext("surge", "📈 SURGE: {item} +{pct}%")
        .replace("{item}", e.item)
        .replace("{pct}", $int(round(abs(e.magnitude) * 100.0)))
      await safeSend(router.chat, txt)

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
    # <= 0 would spin the timer empty (or not at all): keep the current value
    if node["tickSeconds"].getInt > 0:
      tickSeconds = node["tickSeconds"].getInt
  if node.hasKey("pnlKing") and node["pnlKing"].kind in {JInt, JFloat}:
    pnlKing = node["pnlKing"].getFloat
  if node.hasKey("millionaire") and node["millionaire"].kind in {JInt, JFloat}:
    millionaire = node["millionaire"].getFloat
  # market behaviour (shocks, crashes, fees and loans)
  if node.hasKey("shockChance") and node["shockChance"].kind in {JInt, JFloat}:
    market.shockChance = int(node["shockChance"].getFloat)
  if node.hasKey("shockMin") and node["shockMin"].kind in {JInt, JFloat}:
    market.shockMin = int(node["shockMin"].getFloat)
  if node.hasKey("shockMax") and node["shockMax"].kind in {JInt, JFloat}:
    market.shockMax = int(node["shockMax"].getFloat)
  # rand(a..b) with a > b would be nonsense: swap
  if market.shockMin > market.shockMax:
    swap(market.shockMin, market.shockMax)
  if node.hasKey("crashChance") and node["crashChance"].kind in {JInt, JFloat}:
    market.crashChance = int(node["crashChance"].getFloat)
  if node.hasKey("crashThreshold") and node["crashThreshold"].kind in {JInt, JFloat}:
    market.crashThreshold = node["crashThreshold"].getFloat
  if node.hasKey("maxPrice") and node["maxPrice"].kind in {JInt, JFloat}:
    market.maxPrice = node["maxPrice"].getFloat
  if node.hasKey("brokerFee") and node["brokerFee"].kind in {JInt, JFloat}:
    market.brokerFee = node["brokerFee"].getFloat / 100.0
  if node.hasKey("loanInterest") and node["loanInterest"].kind in {JInt, JFloat}:
    market.loanInterest = node["loanInterest"].getFloat / 100.0
  if node.hasKey("maxLoanPct") and node["maxLoanPct"].kind in {JInt, JFloat}:
    market.maxLoanPct = node["maxLoanPct"].getFloat / 100.0
  var defaultSupply = 1000
  if node.hasKey("defaultSupply") and node["defaultSupply"].kind in {JInt, JFloat}:
    defaultSupply = int(node["defaultSupply"].getFloat)
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
      if item.hasKey("supply") and item["supply"].kind in {JInt, JFloat}:
        s.supply = int(item["supply"].getFloat)
      else:
        s.supply = defaultSupply
      # a new stock starting below minPrice would sit in the
      # rounding-lottery zone until the first tick: clamp it up
      s.price = max(s.price, minPrice)
      if s.name.len > 0 and s.volatility > 0.0:
        stocks.add(s)
  # merge: already persisted stocks keep their price, new ones start from the config
  for s in stocks:
    var st = s
    let key = st.name.toLowerAscii()
    if market.stocks.hasKey(key):
      market.stocks[key].volatility = st.volatility
      market.stocks[key].supply = st.supply
    else:
      st.prevPrice = st.price
      market.stocks[key] = st

# --- Trading (shared by buy/sell and buyall/sellall) ------------------------------

proc doBuy(router: CommandRouter, user: string, item: string, qty: int) {.async.} =
  ## Executes a buy (broker fee included) and announces it
  let s = market.stock(item).get()
  # round up: a buyer must never pay less than the true value. max(1, ...) so
  # a purchase always costs at least 1 coin, even for sub-coin prices.
  let cash = max(1, int(ceil(s.price * float(qty))))
  let fee = market.brokerFeeFor(float(cash))
  let total = cash + fee
  if not econ.debit(user, total):
    let txt = mtext("insufficient_funds", "{user}, you only have {balance} 🪙")
      .replace("{user}", user)
      .replace("{balance}", $econ.getBalance(user))
    await safeSend(router.chat, txt)
    return
  market.addHolding(user, item, qty, float(cash))
  market.creditBroker(fee)
  let txt = mtext("bought",
    "{user} bought {qty} {item} for {total} 🪙 ({cash} + {fee} fee)")
    .replace("{user}", user).replace("{qty}", $qty)
    .replace("{item}", s.name).replace("{total}", $total)
    .replace("{cash}", $cash).replace("{fee}", $fee)
  await safeSend(router.chat, txt)
  await checkPortfolioTrophies(router, user)

proc doSell(router: CommandRouter, user: string, item: string, qty: int) {.async.} =
  ## Executes a sell (broker fee included) and announces it
  let s = market.stock(item).get()
  # round down: a seller must never receive more than the true value, so the
  # buy-ceil / sell-floor gap can never be exploited for free coins.
  let proceeds = int(floor(s.price * float(qty)))
  let fee = market.brokerFeeFor(float(proceeds))
  let net = proceeds - fee
  if not market.removeHolding(user, item, qty, float(proceeds)):
    let txt = mtext("not_owner", "{user}, you don't own {item}")
      .replace("{user}", user).replace("{item}", s.name)
    await safeSend(router.chat, txt)
    return
  market.creditBroker(fee)
  econ.credit(user, net)
  let txt = mtext("sold",
    "{user} sold {qty} {item} for {net} 🪙 ({proceeds} - {fee} fee)")
    .replace("{user}", user).replace("{qty}", $qty)
    .replace("{item}", s.name).replace("{net}", $net)
    .replace("{proceeds}", $proceeds).replace("{fee}", $fee)
  await safeSend(router.chat, txt)
  await checkPortfolioTrophies(router, user)

# --- Handlers ---------------------------------------------------------------------------

proc cmdStock*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !stock - stock list with price, trend and remaining supply
  if market.stocks.len == 0:
    await safeSend(router.chat, mtext("no_stocks", "No stocks available."))
    return
  let leftTpl = mtext("left_suffix", " ({left} left)")
  var lines: seq[string] = @[]
  for s in toSeq(market.stocks.values).sortedByIt(it.name.toLowerAscii()):
    let trend =
      if s.price > s.prevPrice: "📈"
      elif s.price < s.prevPrice: "📉"
      else: "➖"
    let left = leftTpl.replace("{left}", $market.remainingSupply(s.name))
    lines.add(s.name & ": " & $s.price & " " & trend & left)
  let header = mtext("market_header", "📊 Stock market:")
  await safeSend(router.chat, header & "\n" & lines.join("\n"))

proc cmdBuy*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !buy <item> <qty> - buys stocks
  let parts = msg.args.splitWhitespace()
  if parts.len != 2:
    let txt = mtext("buy_usage", "{user}, usage: !buy <item> <quantity>")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  var qty = 0
  try: qty = parseInt(parts[1]) except ValueError: qty = 0
  # guard against overflow / garbage: e.g. !buy doge abc or a huge number
  if qty < 1 or qty > 1_000_000:
    let txt = mtext("invalid_quantity", "{user}, enter a valid quantity")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  # qty already extracted
  let stockOpt = market.stock(parts[0])
  if stockOpt.isNone:
    let txt = mtext("unknown_stock", "{user}, unknown stock: {item}")
      .replace("{user}", msg.username).replace("{item}", parts[0])
    await safeSend(router.chat, txt)
    return
  # limited supply: nobody can buy more than what is left
  let rem = market.remainingSupply(stockOpt.get().name)
  if qty > rem:
    let txt = mtext("only_left", "{user}, only {left} {item} left to buy")
      .replace("{user}", msg.username)
      .replace("{left}", $rem).replace("{item}", stockOpt.get().name)
    await safeSend(router.chat, txt)
    return
  if econ.isNil:
    let txt = mtext("economy_unavailable", "{user}, the economy is not available")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  await doBuy(router, msg.username, stockOpt.get().name, qty)

proc cmdSell*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !sell <item> <qty> - sells stocks
  let parts = msg.args.splitWhitespace()
  if parts.len != 2:
    let txt = mtext("sell_usage", "{user}, usage: !sell <item> <quantity>")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  var qty = 0
  try: qty = parseInt(parts[1]) except ValueError: qty = 0
  # guard against overflow / garbage: e.g. !sell doge abc or a huge number
  if qty < 1 or qty > 1_000_000:
    let txt = mtext("invalid_quantity", "{user}, enter a valid quantity")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  # qty already extracted
  let stockOpt = market.stock(parts[0])
  if stockOpt.isNone:
    let txt = mtext("unknown_stock", "{user}, unknown stock: {item}")
      .replace("{user}", msg.username).replace("{item}", parts[0])
    await safeSend(router.chat, txt)
    return
  if econ.isNil:
    let txt = mtext("economy_unavailable", "{user}, the economy is not available")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  await doSell(router, msg.username, stockOpt.get().name, qty)

proc cmdBuyAll*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !buyall <item> - buys as many shares as the balance allows
  let parts = msg.args.splitWhitespace()
  if parts.len != 1:
    let txt = mtext("buyall_usage", "{user}, usage: !buyall <item>")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  let stockOpt = market.stock(parts[0])
  if stockOpt.isNone:
    let txt = mtext("unknown_stock", "{user}, unknown stock: {item}")
      .replace("{user}", msg.username).replace("{item}", parts[0])
    await safeSend(router.chat, txt)
    return
  let s = stockOpt.get()
  if econ.isNil:
    let txt = mtext("economy_unavailable", "{user}, the economy is not available")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  let rem = market.remainingSupply(s.name)
  if rem < 1:
    let txt = mtext("no_left", "{user}, no {item} left to buy")
      .replace("{user}", msg.username).replace("{item}", s.name)
    await safeSend(router.chat, txt)
    return
  # max qty: price + fee must fit in the balance. Start from the analytic
  # upper bound (the adjustment loop below then runs a handful of times)
  let balance = econ.getBalance(msg.username)
  var qty = min(rem, int(floor(float(balance) / (s.price * (1.0 + market.brokerFee)))))
  while qty > 0:
    let cost = max(1, int(ceil(s.price * float(qty))))
    if cost + market.brokerFeeFor(float(cost)) <= balance:
      break
    dec qty
  if qty < 1:
    let txt = mtext("cannot_afford",
      "{user}, you can't afford {item} (balance {balance} 🪙)")
      .replace("{user}", msg.username)
      .replace("{item}", s.name).replace("{balance}", $balance)
    await safeSend(router.chat, txt)
    return
  await doBuy(router, msg.username, s.name, qty)

proc cmdSellAll*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !sellall <item> - sells all shares of an item
  let parts = msg.args.splitWhitespace()
  if parts.len != 1:
    let txt = mtext("sellall_usage", "{user}, usage: !sellall <item>")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  let stockOpt = market.stock(parts[0])
  if stockOpt.isNone:
    let txt = mtext("unknown_stock", "{user}, unknown stock: {item}")
      .replace("{user}", msg.username).replace("{item}", parts[0])
    await safeSend(router.chat, txt)
    return
  let qty = market.holdingQty(msg.username, stockOpt.get().name)
  if qty < 1:
    let txt = mtext("not_owner", "{user}, you don't own {item}")
      .replace("{user}", msg.username).replace("{item}", stockOpt.get().name)
    await safeSend(router.chat, txt)
    return
  if econ.isNil:
    let txt = mtext("economy_unavailable", "{user}, the economy is not available")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  await doSell(router, msg.username, stockOpt.get().name, qty)

proc cmdLoan*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !loan [<amount>] - borrows from the broker (funded by trade fees)
  if econ.isNil:
    let txt = mtext("economy_unavailable", "{user}, the economy is not available")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  let balance = econ.getBalance(msg.username)
  # debt is subtracted: borrowed coin is not wealth, so repeated loans
  # can't push the cap towards 100% leverage
  let wealth = float(balance) + market.portfolioValue(msg.username) -
               market.debt(msg.username)
  let available = max(0.0, min(market.maxLoanAmount(wealth),
                               market.brokerPool) - market.debt(msg.username))
  let parts = msg.args.splitWhitespace()
  if parts.len == 0:
    let txt = mtext("loan_status",
      "{user}, you owe {debt} 🪙. You can borrow up to {available} 🪙")
      .replace("{user}", msg.username)
      .replace("{debt}", $market.debt(msg.username))
      .replace("{available}", $int(available))
    await safeSend(router.chat, txt)
    return
  var amount = 0
  try: amount = parseInt(parts[0]) except ValueError: amount = 0
  if amount < 1:
    let txt = mtext("invalid_amount", "{user}, enter a valid amount")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  if market.brokerPool <= 0.0:
    let txt = mtext("broker_empty",
      "{user}, the broker has no money (fees fund the loans)")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  if float(amount) > available:
    let txt = mtext("loan_max", "{user}, you can borrow up to {available} 🪙")
      .replace("{user}", msg.username)
      .replace("{available}", $int(available))
    await safeSend(router.chat, txt)
    return
  if not market.takeLoan(msg.username, float(amount)):
    let txt = mtext("broker_cannot_cover", "{user}, the broker can't cover that")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  econ.credit(msg.username, amount)
  let txt = mtext("borrowed",
    "{user} borrowed {amount} 🪙 from the broker (interest {interest}% per tick)")
    .replace("{user}", msg.username).replace("{amount}", $amount)
    .replace("{interest}", $int(round(market.loanInterest * 100.0)))
  await safeSend(router.chat, txt)

proc cmdRepay*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !repay [<amount>] - repays the broker (no amount = as much as possible)
  if market.debt(msg.username) <= 0.0:
    let txt = mtext("no_debt", "{user}, you have no debt")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  if econ.isNil:
    let txt = mtext("economy_unavailable", "{user}, the economy is not available")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  let balance = econ.getBalance(msg.username)
  var amount = float(balance)
  let parts = msg.args.splitWhitespace()
  if parts.len == 1:
    var a = 0
    try: a = parseInt(parts[0]) except ValueError: a = 0
    if a < 1:
      let txt = mtext("invalid_amount", "{user}, enter a valid amount")
        .replace("{user}", msg.username)
      await safeSend(router.chat, txt)
      return
    amount = float(a)
  # never repay more than the balance (the debit below is then guaranteed)
  amount = min(amount, float(balance))
  let (real, pay) = market.repayLoan(msg.username, amount)
  if real <= 0.0:
    let txt = mtext("cannot_repay", "{user}, you can't repay: no balance")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  # pay <= balance: repayLoan returns the ceiling of `real`, and
  # real <= amount <= balance with balance a whole number
  discard econ.debit(msg.username, pay)
  let txt = mtext("repaid",
    "{user} repaid {amount} 🪙 to the broker (left: {debt} 🪙)")
    .replace("{user}", msg.username).replace("{amount}", $pay)
    .replace("{debt}", $market.debt(msg.username))
  await safeSend(router.chat, txt)

proc cmdPortfolio*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !portfolio - holdings + value + PnL + debt
  let holdings = market.holdingsList(msg.username)
  if holdings.len == 0:
    let txt = mtext("no_portfolio", "{user}, you don't own any stocks")
      .replace("{user}", msg.username)
    await safeSend(router.chat, txt)
    return
  let lineTpl = mtext("holding_line", "{qty} {item} ({value} 🪙)")
  let delistTpl = mtext("delisted_line", "{qty} {item} (delisted)")
  var lines: seq[string] = @[]
  for (item, qty) in holdings.sortedByIt(it[0].toLowerAscii()):
    # the stock can have disappeared from the market (removed from
    # stocks.json): value it as 0 instead of raising on .get()
    let sOpt = market.stock(item)
    if sOpt.isNone:
      lines.add(delistTpl.replace("{qty}", $qty).replace("{item}", item))
      continue
    lines.add(lineTpl.replace("{qty}", $qty).replace("{item}", sOpt.get().name)
      .replace("{value}", $round2(float(qty) * sOpt.get().price)))
  let value = market.portfolioValue(msg.username)
  let profit = market.pnl(msg.username)
  let sign = if profit >= 0: "+" else: ""
  let total = mtext("portfolio_total", "Total: {value} 🪙 (PnL {pnl})")
    .replace("{value}", $value).replace("{pnl}", sign & $profit)
  let header = mtext("portfolio_header", "💼 {user}'s portfolio:")
    .replace("{user}", msg.username)
  var debtLine = ""
  let debt = market.debt(msg.username)
  if debt > 0.0:
    debtLine = "\n" & mtext("debt_line", "Debt: {debt} 🪙")
      .replace("{debt}", $debt)
  await safeSend(router.chat, header & "\n" & lines.join("\n") & "\n" &
    total & debtLine)

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
  msgTexts = loadMsgs(ctx.dir / "messages.json")
  newsPhrases = loadNews(ctx)
  loadConfig(ctx)
  # seed the RNG: without this the market replays the same random
  # sequence on every boot
  randomize()
  # catch-up: if there was an open market, it does a single update tick.
  # Its news events are discarded, so drop the crashes they telegraphed:
  # no crash without its rumour
  if market.lastTick > 0.0:
    discard market.tick()
    market.pendingCrash = initTable[string, bool]()
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
  handlers["buyall"] = cmdBuyAll
  handlers["sellall"] = cmdSellAll
  handlers["loan"] = cmdLoan
  handlers["repay"] = cmdRepay
  handlers["portfolio"] = cmdPortfolio
  registerCommands(ctx, specs, handlers)
