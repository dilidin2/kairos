import std/[tables, strutils, json, os, math, asyncdispatch, options, times, random, sequtils]

import kairosbot/data/persistence

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
    meNews
    ## pre-crash rumour: a crash of `item` lands on the NEXT tick
    meCrash
    ## the crash hit (negative shock, executed)
    meSurge
    ## a positive shock hit

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
    pendingCrash*: Table[string, bool]
    ## items that crash on the next tick (telegraphed by a meNews event)
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
    pendingCrash*: Table[string, bool]
    ## items that crash on the next tick
    dataPath*: string
    saveGeneration*: int
    saveFuture*: Option[Future[void]]
    lastTick*: float
    shockChance*: int
    ## rare surge chance per tick, in percent
    shockMin*: int
    ## rare event minimum amplitude, in percent
    shockMax*: int
    ## rare event maximum amplitude, in percent
    crashChance*: int
    ## chance per tick of a pre-crash rumour, in percent
    crashThreshold*: float
    ## shock >= this is announced as a crash/surge (+ survivor trophy)
    brokerFee*: float
    ## fee on every trade, as a fraction (0.02 = 2%)
    loanInterest*: float
    ## interest on debts per tick, as a fraction (0.01 = 1%)
    maxLoanPct*: float
    ## max loan as a fraction of the user's wealth (0.5 = 50%)

## Shock, crash, fee and loan defaults (overridable in stocks.json):
## 5% surge chance per tick, 2% crash-rumour chance, shock amplitude
## ±20-40%, crash >= 20%, broker fee 2%, loan interest 1%/tick,
## max loan 50% of wealth.

proc round2*(x: float): float =
  ## Rounds to 2 decimal places
  result = round(x * 100.0) / 100.0

const minPrice = 1.0
  ## Hard lower bound for a stock price. Below this the round2 rounding in
  ## transactions starts to behave like a lottery (fractions of a coin), so
  ## the floor keeps every transaction in the normal integer-coin range.

proc normUser*(user: string): string =
  ## Normalizes a username (lowercase)
  result = user.toLowerAscii()

proc newStockMarket*(dataPath: string): StockMarket =
  ## Creates the market and loads the persistent data
  let default = MarketData(
    stocks: @[],
    holdings: initTable[string, Table[string, int]](),
    invested: initTable[string, float](),
    brokerPool: 0.0,
    loans: initTable[string, float](),
    pendingCrash: initTable[string, bool](),
    lastTick: 0.0
  )
  let data = loadTyped[MarketData](dataPath, default)
  result = StockMarket(
    stocks: initTable[string, Stock](),
    holdings: data.holdings,
    invested: data.invested,
    brokerPool: data.brokerPool,
    loans: data.loans,
    pendingCrash: data.pendingCrash,
    dataPath: dataPath,
    saveGeneration: 0,
    saveFuture: none(Future[void]),
    lastTick: data.lastTick,
    shockChance: 5,
    shockMin: 20,
    shockMax: 40,
    crashChance: 2,
    crashThreshold: 0.20,
    brokerFee: 0.02,
    loanInterest: 0.01,
    maxLoanPct: 0.50
  )
  for s in data.stocks:
    result.stocks[s.name.toLowerAscii()] = s

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

proc tick*(m: StockMarket): seq[MarketEvent] =
  ## One market step. Order: (1) execute the crashes telegraphed by the
  ## news of the previous tick, (2) random walk + surges + new crash
  ## rumours, (3) loan interest. Returns the chat events in order.
  result = @[]
  # 1) crashes announced by the news of the previous tick
  for key in toSeq(m.pendingCrash.keys):
    if m.stocks.hasKey(key):
      var item = m.stocks[key]
      let magnitude = float(rand(m.shockMin .. m.shockMax)) / 100.0
      item.prevPrice = item.price
      item.price = max(round2(item.price * exp(-magnitude)), minPrice)
      m.stocks[key] = item
      result.add(MarketEvent(kind: meCrash, item: item.name,
                             magnitude: magnitude))
  m.pendingCrash = initTable[string, bool]()
  # 2) normal trading: walk, surges, crash rumours
  for key in m.stocks.keys:
    var item = m.stocks[key]
    item.prevPrice = item.price
    # random walk: log-normal so the median (not the mean) stays flat.
    # A +x followed by a -x returns to the exact previous price
    # (exp(x)*exp(-x)=1), which kills the volatility drag that made
    # prices decay tick after tick.
    let change = rand(-item.volatility .. item.volatility)
    item.price = round2(item.price * exp(change))
    # rare positive shock (surge), immediate
    if rand(100) < m.shockChance:
      let magnitude = float(rand(m.shockMin .. m.shockMax)) / 100.0
      item.price = round2(item.price * exp(magnitude))
      if magnitude >= m.crashThreshold:
        result.add(MarketEvent(kind: meSurge, item: item.name,
                               magnitude: magnitude))
    # pre-crash rumour: the crash lands on the NEXT tick
    elif rand(100) < m.crashChance:
      m.pendingCrash[key] = true
      result.add(MarketEvent(kind: meNews, item: item.name, magnitude: 0.0))
    # never let a tick push a price into the rounding-lottery zone (see minPrice)
    item.price = max(item.price, minPrice)
    m.stocks[key] = item
  # 3) debts grow with interest
  for u in toSeq(m.loans.keys):
    m.loans[u] = round2(m.loans[u] * (1.0 + m.loanInterest))
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

# --- Broker and loans ----------------------------------------------------------

proc brokerFeeFor*(m: StockMarket, amount: float): int =
  ## Integer fee on a trade of `amount` coins (rounded down: tiny trades
  ## pay no fee, the broker never takes more than the true value)
  result = int(floor(amount * m.brokerFee))

proc creditBroker*(m: StockMarket, fee: int) =
  ## Adds fee income to the broker pool
  m.brokerPool = round2(m.brokerPool + float(fee))

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
  result = true

proc repayLoan*(m: StockMarket, user: string, amount: float): float =
  ## Repays up to `amount` to the broker pool. Returns the amount
  ## actually repaid (0 if the user has no debt).
  let u = normUser(user)
  result = min(amount, m.loans.getOrDefault(u, 0.0))
  if result <= 0.0:
    return
  m.brokerPool = round2(m.brokerPool + result)
  m.loans[u] = round2(m.loans[u] - result)
  if m.loans[u] <= 0.0:
    m.loans.del(u)

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
    pendingCrash: m.pendingCrash,
    lastTick: m.lastTick
  )
  saveTyped(m.dataPath, data)

proc performDebounceSave*(m: StockMarket, myGen: int) {.async.} =
  ## Debounced save after 5s if this is still the current generation
  await sleepAsync(5000)
  if myGen != m.saveGeneration:
    return
  saveMarket(m)
  m.saveFuture = none(Future[void])

proc scheduleMarketSave*(m: StockMarket) =
  ## Schedules a debounced save (5s)
  m.saveGeneration += 1
  let gen = m.saveGeneration
  let f = performDebounceSave(m, gen)
  m.saveFuture = some(f)

proc forceSave*(m: StockMarket) {.async.} =
  ## Saves immediately, ignoring the debounce
  m.saveGeneration += 1
  if m.saveFuture.isSome:
    await m.saveFuture.get()
    m.saveFuture = none(Future[void])
  saveMarket(m)
