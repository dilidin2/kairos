import std/[json, os, strutils, sequtils, math, random, algorithm, tables, stats]

import commands/stocks/stock_market as sm

## Drift simulation (self-contained, no StockMarket dependency for "old").
## Measures the price drift (final/initial - 1) per stock after `ticks` ticks
## of `runs` independent markets with no holdings.
##
## Modes:
##   old            - the ORIGINAL tick logic (copied here)
##   old-nofloor    - old logic without the minPrice clamp
##   old-noshocks   - old logic without surges/crashes
##   old-noround    - old logic without round2
##   new            - the new supply/demand model (mirrors stock_market.nim tick)
##   real           - the ACTUAL StockMarket.tick() from stock_market.nim
## Usage: nim c -r tools/drift_sim.nim <mode> [runs] [ticks]

const
  minPriceOld = 1.0   # the original floor (reflecting wall)
  minPrice = 0.01     # the new safety-net floor
  maxPrice = 100000.0
  shockChance = 5
  shockMin = 20
  shockMax = 40
  crashChance = 5

type OStock = object
  name*: string
  basePrice, price, prevPrice, volatility*: float
  supply*: int

proc round2(x: float): float =
  round(x * 100.0) / 100.0

# --- old logic (faithful copy of the pre-change tick) ---
proc oldTick(stocks: var Table[string, OStock], pending: var Table[string, bool],
             nofloor, noshocks, noround: bool) =
  var crashedThisTick: Table[string, bool]
  for key in toSeq(pending.keys):
    if stocks.hasKey(key):
      var item = stocks[key]
      let magnitude = float(rand(shockMin .. shockMax)) / 100.0
      item.price = if nofloor: max(item.price * exp(-magnitude), 0.01)
                   else: max(round2(item.price * exp(-magnitude)), minPriceOld)
      stocks[key] = item
      crashedThisTick[key] = true
  pending = initTable[string, bool]()
  for key in stocks.keys:
    var item = stocks[key]
    if not crashedThisTick.hasKey(key):
      item.prevPrice = item.price
    let change = rand(-item.volatility .. item.volatility)
    item.price = if noround: item.price * exp(change)
                 else: round2(item.price * exp(change))
    if not noshocks:
      if rand(99) < shockChance:
        let magnitude = float(rand(shockMin .. shockMax)) / 100.0
        item.price = if noround: item.price * exp(magnitude)
                     else: round2(item.price * exp(magnitude))
      if rand(99) < crashChance:
        pending[key] = true
    if not nofloor:
      item.price = clamp(item.price, minPriceOld, maxPrice)
    stocks[key] = item

# --- new logic (must mirror stock_market.nim tick) ---
proc newTick(stocks: var Table[string, OStock], reversion, noiseScale,
             demandExp: float) =
  for key in stocks.keys:
    var item = stocks[key]
    item.prevPrice = item.price
    let held = 0  # no holdings in the sim
    let eq = item.basePrice * pow(1.0 + float(held) / float(item.supply),
                                  demandExp)
    item.price += reversion * (eq - item.price)
    item.price += rand(-1.0 .. 1.0) * item.volatility * noiseScale * item.price
    if rand(99) < shockChance:
      let magnitude = float(rand(shockMin .. shockMax)) / 100.0
      if rand(1) == 0:
        item.price *= exp(-magnitude)
      else:
        item.price *= exp(magnitude)
    item.price = clamp(round2(item.price), minPrice, maxPrice)
    stocks[key] = item

proc med(xs: seq[float]): float =
  let s = xs.sorted()
  if s.len mod 2 == 1: result = s[s.len div 2]
  else: result = (s[s.len div 2 - 1] + s[s.len div 2]) / 2.0

var
  mode = "old"
  runs = 500
  ticks = 2000

# nim c -r passes the program path as param 0
# paramStr(0) is the program name; args start at index 1
if paramCount() >= 1: mode = paramStr(1)
if paramCount() >= 2: runs = parseInt(paramStr(2))
if paramCount() >= 3: ticks = parseInt(paramStr(3))

let cfg = parseJson(readFile("commands/stocks/stocks.json"))
var stocks: seq[OStock] = @[]
for item in cfg["stocks"]:
  let p = item["price"].getFloat
  stocks.add(OStock(name: item["name"].getStr, basePrice: p, price: p,
    prevPrice: p, volatility: item["volatility"].getFloat,
    supply: if item.hasKey("supply"): item["supply"].getInt else: cfg["defaultSupply"].getInt))

randomize()
var allDrifts: seq[seq[float]]
for i in 0 ..< stocks.len: allDrifts.add(@[])

for r in 1 ..< runs:
  if mode == "real":
    let rm = sm.newStockMarket("/tmp/drift_real_" & $r & ".json")
    var rstocks: seq[sm.Stock] = @[]
    for s in stocks:
      rstocks.add(sm.Stock(name: s.name, basePrice: s.basePrice, price: s.price,
                           prevPrice: s.prevPrice, volatility: s.volatility,
                           supply: s.supply))
    rm.setStocks(rstocks)
    for t2 in 1 ..< ticks:
      discard rm.tick()
    for i in 0 ..< stocks.len:
      allDrifts[i].add(rm.stocks[stocks[i].name.toLowerAscii()].price /
                       stocks[i].basePrice - 1.0)
    continue
  var st: Table[string, OStock]
  for s in stocks: st[s.name.toLowerAscii()] = s
  var pending: Table[string, bool]
  for t in 1 ..< ticks:
    case mode
    of "old": st.oldTick(pending, false, false, false)
    of "old-clean": st.oldTick(pending, true, true, true)
    of "old-nofloor": st.oldTick(pending, true, false, false)
    of "old-noshocks": st.oldTick(pending, false, true, false)
    of "old-noround": st.oldTick(pending, false, false, true)
    of "new": st.newTick(0.15, 0.5, 1.0)
    else: echo "unknown mode: ", mode; quit(1)
  for i in 0 ..< stocks.len:
    allDrifts[i].add(st[stocks[i].name.toLowerAscii()].price /
                     stocks[i].basePrice - 1.0)

echo "mode=", mode, " runs=", runs, " ticks/run=", ticks
echo "stock      median     mean      min      max"
for i in 0 ..< stocks.len:
  let d = allDrifts[i]
  let m = $med(d)
  let a = $mean(d)
  let lo = $min(d)
  let hi = $max(d)
  echo stocks[i].name.align(10), "  ", m.align(9), "  ", a.align(9),
       "  ", lo.align(9), "  ", hi.align(9)
