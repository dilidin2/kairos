import std/[tables, strutils, json, os, math, asyncdispatch, options, times, random, sequtils, algorithm]

import kairosbot/data/persistence
import kairosbot/utils/common

## Virtual stock market. Lives in the plugin: only this plugin uses the
## state. Prices and holdings persist in data/stocks.json.

type
  Stock* = object
    name*: string
    price*: float
    prevPrice*: float
    volatility*: float
    ## amplitude of the random walk (e.g. 0.10 = ±10%)
    supply*: int
    ## total shares in existence: all users combined can never hold more

  MarketEventKind* = enum
    meCrash
    ## the crash hit (negative shock, executed)

  MarketEvent* = object
    kind*: MarketEventKind
    item*: string
    ## stock name
    magnitude*: float
    ## shock amplitude as a positive fraction (0.0 for meNews)

  MarketData* = object
    ## Serializable snapshot
    stocks*: seq[Stock]
    holdings*: Table[string, Table[string, int]]
    invested*: Table[string, float]
    brokerPool*: float
    ## real coins collected as broker fees: the only source of loan money
    loans*: Table[string, float]
    ## user (lowercase) -> total debt (principal + accrued interest)
    dividendAccrual*: Table[string, float]
    ## user (lowercase) -> fractional coins accrued as dividends, not yet
    ## paid out (paid in whole coins by payDividends)
    dividendsPaid*: Table[string, Table[string, int]]
    ## user (lowercase) -> item (lowercase) -> lifetime dividend coins
    ## received for that stock
    pendingCrash*: Table[string, bool]
    ## items that crash on the next tick
    lastTick*: float

  StockMarket* = ref object
    stocks*: Table[string, Stock]
    ## item (lowercase) -> Stock
    holdings*: Table[string, Table[string, int]]
    ## user (lowercase) -> item -> qty
    invested*: Table[string, float]
    ## user (lowercase) -> net invested cash (buys - sells)
    brokerPool*: float
    ## real coins collected as broker fees
    loans*: Table[string, float]
    ## user (lowercase) -> total debt (principal + interest)
    dividendAccrual*: Table[string, float]
    ## user (lowercase) -> fractional dividend coins not yet paid out
    dividendsPaid*: Table[string, Table[string, int]]
    ## user (lowercase) -> item (lowercase) -> lifetime dividend coins
    pendingCrash*: Table[string, bool]
    ## items that crash on the next tick
    dataPath*: string
    saver: DebouncedSaver
    lastTick*: float
    shockChance*: int
    ## rare surge chance per tick, in percent
    shockMin*: int
    ## rare event minimum amplitude, in percent
    shockMax*: int
    ## rare event maximum amplitude, in percent
    crashChance*: int
    ## chance per tick of a pre-crash rumour, in percent. Kept equal to
    ## shockChance by default: with equal chances and amplitude the
    ## expected drift of the log-price is zero.
    crashThreshold*: float
    ## shock >= this is announced as a crash/surge (+ survivor trophy)
    maxPrice*: float
    ## hard upper bound for a stock price (safety net against runaway growth)
    brokerFee*: float
    ## fee on every trade, as a fraction (0.02 = 2%)
    loanInterest*: float
    ## interest on debts per tick, as a fraction (0.01 = 1%)
    maxLoanPct*: float
    ## max loan as a fraction of the user's wealth (0.5 = 50%)
    dividendPct*: float
    ## dividend per tick as a fraction of the holdings value (0.001 = 0.1%)

## Shock, crash, fee and loan defaults (overridable in stocks.json):
## 5% surge chance per tick, 2% crash-rumour chance, shock amplitude
## ±20-40%, crash >= 20%, broker fee 2%, loan interest 1%/tick,
## max loan 50% of wealth.

proc round2*(x: float): float =
  ## Rounds to 2 decimal places
  result = round(x * 100.0) / 100.0

const minPrice* = 1.0
  ## Hard lower bound for a stock price. Below this the round2 rounding in
  ## transactions starts to behave like a lottery (fractions of a coin), so
  ## the floor keeps every transaction in the normal integer-coin range.

proc saveMarket*(m: StockMarket)  # forward declaration

proc newStockMarket*(dataPath: string): StockMarket =
  ## Creates the market and loads the persistent data
  let default = MarketData(
    stocks: @[],
    holdings: initTable[string, Table[string, int]](),
    invested: initTable[string, float](),
    brokerPool: 0.0,
    loans: initTable[string, float](),
    dividendAccrual: initTable[string, float](),
    dividendsPaid: initTable[string, Table[string, int]](),
    pendingCrash: initTable[string, bool](),
    lastTick: 0.0
  )
  let data = loadTyped[MarketData](dataPath, default)
  var m = StockMarket(
    stocks: initTable[string, Stock](),
    holdings: data.holdings,
    invested: data.invested,
    brokerPool: data.brokerPool,
    loans: data.loans,
    dividendAccrual: data.dividendAccrual,
    dividendsPaid: data.dividendsPaid,
    pendingCrash: data.pendingCrash,
    dataPath: dataPath,
    lastTick: data.lastTick,
    shockChance: 5,
    shockMin: 20,
    shockMax: 40,
    crashChance: 5,
    crashThreshold: 0.20,
    maxPrice: 100000.0,
    brokerFee: 0.02,
    loanInterest: 0.01,
    maxLoanPct: 0.50,
    dividendPct: 0.0
  )
  m.saver = newDebouncedSaver(proc () {.closure.} = saveMarket(m))
  for s in data.stocks:
    m.stocks[s.name.toLowerAscii()] = s
  result = m

proc setStocks*(m: StockMarket, stocks: seq[Stock]) =
  ## Defines the stock list (price, prev, volatility)
  m.stocks = initTable[string, Stock]()
  for s in stocks:
    m.stocks[s.name.toLowerAscii()] = s

proc stock*(m: StockMarket, item: string): Option[Stock] =
  ## Looks up a stock by name (case-insensitive)
  let key = item.toLowerAscii()
  if m.stocks.hasKey(key):
    result = some(m.stocks[key])
  else:
    result = none(Stock)

proc scheduleMarketSave*(m: StockMarket)  # forward declaration
proc portfolioValue*(m: StockMarket, user: string): float  # forward declaration

proc tick*(m: StockMarket): seq[MarketEvent] =
  ## One market step. Order: (1) execute the crashes telegraphed by the
  ## previous tick, (2) random walk + surges + new crash rumours,
  ## (3) loan interest, (4) dividend accrual. Returns the crash events.
  result = @[]
  # 1) crashes telegraphed by the previous tick
  var crashedThisTick: Table[string, bool]
  for key in toSeq(m.pendingCrash.keys):
    if m.stocks.hasKey(key):
      var item = m.stocks[key]
      let magnitude = float(rand(m.shockMin .. m.shockMax)) / 100.0
      let oldPrice = item.price
      item.price = max(round2(item.price * exp(-magnitude)), minPrice)
      m.stocks[key] = item
      crashedThisTick[key] = true
      # the event carries the ACTUAL signed price change (exp(-0.30) is
      # -25.9%, not -30%), so chat messages are exact
      result.add(MarketEvent(kind: meCrash, item: item.name,
                             magnitude: item.price / oldPrice - 1.0))
  m.pendingCrash = initTable[string, bool]()
  # 2) normal trading: walk, surges, crash rumours
  for key in m.stocks.keys:
    var item = m.stocks[key]
    # keep the pre-crash price as the trend reference (step 1 already set
    # prevPrice to the pre-crash value)
    if not crashedThisTick.hasKey(key):
      item.prevPrice = item.price
    # random walk: log-normal so the median (not the mean) stays flat.
    # A +x followed by a -x returns to the exact previous price
    # (exp(x)*exp(-x)=1), which kills the volatility drag that made
    # prices decay tick after tick.
    let change = rand(-item.volatility .. item.volatility)
    item.price = round2(item.price * exp(change))
    # rare positive shock (surge), immediate. rand(99): 0..99, so
    # `rand(99) < N` is exactly N percent. The two events roll
    # INDEPENDENTLY (not if/elif): with equal chances the expected
    # drift of the log-price is exactly zero.
    if rand(99) < m.shockChance:
      let magnitude = float(rand(m.shockMin .. m.shockMax)) / 100.0
      item.price = round2(item.price * exp(magnitude))
    # pre-crash rumour: the crash lands on the NEXT tick
    if rand(99) < m.crashChance:
      m.pendingCrash[key] = true
    # keep the price inside [minPrice, maxPrice] (see minPrice)
    item.price = clamp(item.price, minPrice, m.maxPrice)
    m.stocks[key] = item
  # 3) debts grow with interest
  for u in toSeq(m.loans.keys):
    m.loans[u] = round2(m.loans[u] * (1.0 + m.loanInterest))
  # 4) dividends: every holder accrues a per-tick cut of their holdings
  # value; the whole-coin part is paid out by payDividends
  if m.dividendPct > 0.0:
    for u in toSeq(m.holdings.keys):
      m.dividendAccrual[u] = m.dividendAccrual.getOrDefault(u, 0.0) +
                             m.portfolioValue(u) * m.dividendPct
  m.lastTick = epochTime()
  scheduleMarketSave(m)

# --- Supply -----------------------------------------------------------------

proc totalHeld*(m: StockMarket, item: string): int =
  ## Total shares of `item` held by ALL users
  let i = item.toLowerAscii()
  for u in m.holdings.keys:
    result += m.holdings[u].getOrDefault(i, 0)

proc remainingSupply*(m: StockMarket, item: string): int =
  ## Shares of `item` still available for purchase
  let s = m.stock(item)
  if s.isSome:
    result = max(0, s.get().supply - m.totalHeld(item))

# --- Holdings ----------------------------------------------------------------

proc holdingQty*(m: StockMarket, user: string, item: string): int =
  ## Quantity held by a user
  let u = normUser(user)
  let i = item.toLowerAscii()
  if m.holdings.hasKey(u) and m.holdings[u].hasKey(i):
    result = m.holdings[u][i]
  else:
    result = 0

proc addHolding*(m: StockMarket, user: string, item: string, qty: int, cash: float) =
  ## Adds quantity to the portfolio and updates the invested cash
  let u = normUser(user)
  let i = item.toLowerAscii()
  if not m.holdings.hasKey(u):
    m.holdings[u] = initTable[string, int]()
  m.holdings[u][i] = m.holdings[u].getOrDefault(i, 0) + qty
  m.invested[u] = m.invested.getOrDefault(u, 0.0) + cash
  scheduleMarketSave(m)

proc removeHolding*(m: StockMarket, user: string, item: string, qty: int, cash: float): bool =
  ## Removes quantity from the portfolio. False if there isn't enough.
  ## Updates the invested cash (proceeds) if ok.
  let u = normUser(user)
  let i = item.toLowerAscii()
  if not m.holdings.hasKey(u) or m.holdings[u].getOrDefault(i, 0) < qty:
    result = false
    return
  m.holdings[u][i] = m.holdings[u][i] - qty
  if m.holdings[u][i] == 0:
    m.holdings[u].del(i)
  if m.holdings[u].len == 0:
    m.holdings.del(u)
  m.invested[u] = m.invested.getOrDefault(u, 0.0) - cash
  scheduleMarketSave(m)
  result = true

proc portfolioValue*(m: StockMarket, user: string): float =
  ## Current value of the portfolio
  let u = normUser(user)
  if not m.holdings.hasKey(u):
    result = 0.0
    return
  for item, qty in m.holdings[u].pairs:
    if m.stocks.hasKey(item):
      result += m.stocks[item].price * float(qty)
  result = round2(result)

proc pnl*(m: StockMarket, user: string): float =
  ## PnL: current value - invested cash
  let u = normUser(user)
  result = round2(m.portfolioValue(user) - m.invested.getOrDefault(u, 0.0))

proc holdingsList*(m: StockMarket, user: string): seq[(string, int)] =
  ## A user's holdings: (item, qty)
  let u = normUser(user)
  if m.holdings.hasKey(u):
    for item, qty in m.holdings[u].pairs:
      result.add((item, qty))

# --- Dividends -----------------------------------------------------------------

proc creditDividends(m: StockMarket, user: string, amount: int) =
  ## Splits `amount` across the user's holdings proportionally to their
  ## value (largest remainder, so the parts always sum to `amount`) and
  ## adds it to their lifetime per-stock total
  var parts: seq[tuple[item: string, share: int, value: float, frac: float]]
  var total = 0.0
  if m.holdings.hasKey(user):
    for item, qty in m.holdings[user].pairs:
      if m.stocks.hasKey(item) and qty > 0:
        let v = m.stocks[item].price * float(qty)
        parts.add((item, 0, v, 0.0))
        total += v
  if total <= 0.0:
    return
  if not m.dividendsPaid.hasKey(user):
    m.dividendsPaid[user] = initTable[string, int]()
  var allocated = 0
  for i in 0 ..< parts.len:
    let exact = float(amount) * parts[i].value / total
    parts[i].share = int(floor(exact))
    parts[i].frac = exact - float(parts[i].share)
    allocated += parts[i].share
  # leftover coins go to the largest fractions first
  var leftover = amount - allocated
  for p in parts.sortedByIt(-it.frac):
    if leftover <= 0:
      break
    m.dividendsPaid[user][p.item] = m.dividendsPaid[user].getOrDefault(p.item, 0) + 1
    dec leftover
  for p in parts:
    if p.share > 0:
      m.dividendsPaid[user][p.item] = m.dividendsPaid[user].getOrDefault(p.item, 0) + p.share

proc payDividends*(m: StockMarket, user: string): int =
  ## Pays out the whole-coin part of the user's accrued dividend (the
  ## fractional remainder keeps accruing). 0 if there is nothing to pay.
  let u = normUser(user)
  if not m.dividendAccrual.hasKey(u):
    result = 0
    return
  let whole = int(floor(m.dividendAccrual[u]))
  if whole < 1:
    result = 0
    return
  m.dividendAccrual[u] -= float(whole)
  if m.dividendAccrual[u] <= 0.0:
    m.dividendAccrual.del(u)
  m.creditDividends(u, whole)
  scheduleMarketSave(m)
  result = whole

proc dividendsPaid*(m: StockMarket, user, item: string): int =
  ## Lifetime dividend coins the user received for `item`
  let u = normUser(user)
  let i = item.toLowerAscii()
  if m.dividendsPaid.hasKey(u) and m.dividendsPaid[u].hasKey(i):
    result = m.dividendsPaid[u][i]

# --- Broker and loans ----------------------------------------------------------

proc brokerFeeFor*(m: StockMarket, amount: float): int =
  ## Integer fee on a trade of `amount` coins (rounded up: every non-
  ## trivial trade pays at least 1 coin, so the fee pool is a real sink)
  result = int(ceil(amount * m.brokerFee))

proc creditBroker*(m: StockMarket, fee: int) =
  ## Adds fee income to the broker pool
  m.brokerPool = round2(m.brokerPool + float(fee))
  scheduleMarketSave(m)

proc debt*(m: StockMarket, user: string): float =
  ## Total debt of a user (principal + accrued interest)
  result = m.loans.getOrDefault(normUser(user), 0.0)

proc maxLoanAmount*(m: StockMarket, wealth: float): float =
  ## Loan cap for a user with `wealth` (balance + portfolio value)
  result = round2(wealth * m.maxLoanPct)

proc takeLoan*(m: StockMarket, user: string, amount: float): bool =
  ## Advances `amount` from the broker pool. False if the pool can't cover it.
  if amount <= 0.0 or m.brokerPool < amount:
    result = false
    return
  let u = normUser(user)
  m.brokerPool = round2(m.brokerPool - amount)
  m.loans[u] = round2(m.loans.getOrDefault(u, 0.0) + amount)
  scheduleMarketSave(m)
  result = true

proc repayLoan*(m: StockMarket, user: string, amount: float): (float, int) =
  ## Repays up to `amount` to the broker pool. Returns (real, pay):
  ## `real` is the debt actually cleared, `pay` the whole coins the user
  ## pays (ceiling: any overpay is burned, the broker never mints coins).
  ## (0, 0) if the user has no debt.
  let u = normUser(user)
  let real = min(amount, m.loans.getOrDefault(u, 0.0))
  if real <= 0.0:
    return (0.0, 0)
  let pay = int(ceil(real))
  m.brokerPool = round2(m.brokerPool + float(pay))
  m.loans[u] = round2(m.loans[u] - real)
  if m.loans[u] <= 0.0:
    m.loans.del(u)
  scheduleMarketSave(m)
  return (real, pay)

# --- Persistence ----------------------------------------------------------------

proc saveMarket*(m: StockMarket) =
  ## Saves prices, holdings, invested cash, broker pool and debts to the
  ## JSON file
  let data = MarketData(
    stocks: toSeq(m.stocks.values),
    holdings: m.holdings,
    invested: m.invested,
    brokerPool: m.brokerPool,
    loans: m.loans,
    dividendAccrual: m.dividendAccrual,
    dividendsPaid: m.dividendsPaid,
    pendingCrash: m.pendingCrash,
    lastTick: m.lastTick
  )
  saveTyped(m.dataPath, data)

proc scheduleMarketSave*(m: StockMarket) =
  ## Schedules a debounced save (5s)
  m.saver.schedule()

proc forceSave*(m: StockMarket) {.async.} =
  ## Saves immediately, ignoring the debounce
  m.saver.flush()
