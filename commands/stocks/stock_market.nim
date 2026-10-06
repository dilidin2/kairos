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

  MarketData* = object
    ## Serializable snapshot
    stocks*: seq[Stock]
    holdings*: Table[string, Table[string, int]]
    invested*: Table[string, float]
    lastTick*: float

  StockMarket* = ref object
    stocks*: Table[string, Stock]
    ## item (lowercase) -> Stock
    holdings*: Table[string, Table[string, int]]
    ## user (lowercase) -> item -> qty
    invested*: Table[string, float]
    ## user (lowercase) -> net invested cash (buys - sells)
    dataPath*: string
    saveGeneration*: int
    saveFuture*: Option[Future[void]]
    lastTick*: float
    shockChance*: int
    ## rare event chance per tick, in percent
    shockMin*: int
    ## rare event minimum amplitude, in percent
    shockMax*: int
    ## rare event maximum amplitude, in percent
    crashThreshold*: float
    ## shock >= this is a crash (for the "survivor" trophy)

## Shock and crash defaults (overridable in stocks.json):
## 5% chance per tick, shock amplitude ±20-40%, crash >= 20%.

proc round2*(x: float): float =
  ## Rounds to 2 decimal places
  result = round(x * 100.0) / 100.0

proc normUser*(user: string): string =
  ## Normalizes a username (lowercase)
  result = user.toLowerAscii()

proc newStockMarket*(dataPath: string): StockMarket =
  ## Creates the market and loads the persistent data
  let default = MarketData(
    stocks: @[],
    holdings: initTable[string, Table[string, int]](),
    invested: initTable[string, float](),
    lastTick: 0.0
  )
  let data = loadTyped[MarketData](dataPath, default)
  result = StockMarket(
    stocks: initTable[string, Stock](),
    holdings: data.holdings,
    invested: data.invested,
    dataPath: dataPath,
    saveGeneration: 0,
    saveFuture: none(Future[void]),
    lastTick: data.lastTick,
    shockChance: 5,
    shockMin: 20,
    shockMax: 40,
    crashThreshold: 0.20
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

proc tick*(m: StockMarket): seq[(string, float)] =
  ## One random walk step on every stock. Returns the rare events
  ## (shock >= 20%): (name, shock) with sign. Updates lastTick.
  result = @[]
  for key in m.stocks.keys:
    var item = m.stocks[key]
    item.prevPrice = item.price
    # random walk
    let change = rand(-item.volatility .. item.volatility)
    item.price = round2(item.price * (1.0 + change))
    # rare event: shock with a random amplitude in [shockMin, shockMax]
    if rand(100) < m.shockChance:
      let magnitude = float(rand(m.shockMin .. m.shockMax)) / 100.0
      let dir = if rand(2) == 0: 1.0 else: -1.0
      item.price = round2(item.price * (1.0 + dir * magnitude))
      if abs(magnitude) >= m.crashThreshold:
        result.add((item.name, dir * magnitude))
    m.stocks[key] = item
  m.lastTick = epochTime()
  scheduleMarketSave(m)

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

# --- Persistence -----------------------------------------------------------------

proc saveMarket*(m: StockMarket) =
  ## Saves prices, holdings and invested cash to the JSON file
  let data = MarketData(
    stocks: toSeq(m.stocks.values),
    holdings: m.holdings,
    invested: m.invested,
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
