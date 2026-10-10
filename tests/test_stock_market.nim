import std/[unittest, asyncdispatch, strutils, tables, json, os, options, math]

import ./utils
import ../commands/stocks/stock_market as sm

suite "StockMarket":

  test "newStockMarket creates an empty market":
    let m = sm.newStockMarket("/tmp/test_stocks_market.json")
    check m.stocks.len == 0
    check m.holdings.len == 0

  test "setStocks defines the stocks":
    let m = sm.newStockMarket("/tmp/test_stocks_market2.json")
    m.setStocks(@[
      sm.Stock(name: "Pasta", basePrice: 10.0, price: 10.0, prevPrice: 10.0, volatility: 0.08),
      sm.Stock(name: "GPU", basePrice: 150.0, price: 150.0, prevPrice: 150.0, volatility: 0.15)
    ])
    check m.stocks.len == 2
    check m.stock("pasta").isSome
    check m.stock("Pasta").get().price == 10.0
    check m.stock("unknown").isNone

  test "tick updates prices and prevPrice":
    let m = sm.newStockMarket("/tmp/test_stocks_market3.json")
    m.setStocks(@[
      sm.Stock(name: "Pasta", basePrice: 10.0, price: 10.0, prevPrice: 10.0, volatility: 0.5)
    ])
    # high volatility: the price should change (probabilistically)
    var changed = false
    for _ in 0 ..< 20:
      let before = m.stock("pasta").get().price
      discard m.tick()
      if m.stock("pasta").get().price != before:
        changed = true
        break
    check changed
    check m.stock("pasta").get().prevPrice >= 0.0
    check m.lastTick > 0.0

  test "addHolding e holdingQty":
    let m = sm.newStockMarket("/tmp/test_stocks_market4.json")
    m.setStocks(@[sm.Stock(name: "Pasta", basePrice: 10.0, price: 10.0, prevPrice: 10.0, volatility: 0.08)])
    m.addHolding("Mario", "pasta", 3, 30.0)
    check m.holdingQty("mario", "pasta") == 3
    check m.holdingQty("Mario", "PASTA") == 3
    check m.holdingQty("luigi", "pasta") == 0

  test "removeHolding: ok and insufficient":
    let m = sm.newStockMarket("/tmp/test_stocks_market5.json")
    m.setStocks(@[sm.Stock(name: "Pasta", basePrice: 10.0, price: 10.0, prevPrice: 10.0, volatility: 0.08)])
    m.addHolding("mario", "pasta", 5, 50.0)
    check m.removeHolding("mario", "pasta", 2, 20.0)
    check m.holdingQty("mario", "pasta") == 3
    check not m.removeHolding("mario", "pasta", 10, 100.0)
    check m.holdingQty("mario", "pasta") == 3

  test "portfolioValue e pnl":
    let m = sm.newStockMarket("/tmp/test_stocks_market6.json")
    m.setStocks(@[sm.Stock(name: "Pasta", basePrice: 10.0, price: 10.0, prevPrice: 10.0, volatility: 0.08)])
    # buys 3 pasta at 10 (cost 30)
    m.addHolding("mario", "pasta", 3, 30.0)
    check m.portfolioValue("mario") == 30.0
    check m.pnl("mario") == 0.0
    # the price rises to 15
    m.stocks["pasta"].price = 15.0
    check m.portfolioValue("mario") == 45.0
    check m.pnl("mario") == 15.0

  test "persistence: save and reload":
    let path = "/tmp/test_stocks_persist.json"
    if fileExists(path):
      removeFile(path)
    let m = sm.newStockMarket(path)
    m.setStocks(@[sm.Stock(name: "Pasta", basePrice: 10.0, price: 10.0, prevPrice: 10.0, volatility: 0.08)])
    m.addHolding("mario", "pasta", 4, 40.0)
    m.saveMarket()

    let m2 = sm.newStockMarket(path)
    check m2.stocks.len == 1
    check m2.holdingQty("mario", "pasta") == 4
    check m2.invested["mario"] == 40.0
    if fileExists(path):
      removeFile(path)

  test "dividends accrue and pay out whole coins":
    let m = sm.newStockMarket("/tmp/test_stocks_market7.json")
    m.setStocks(@[sm.Stock(name: "Pasta", basePrice: 10.0, price: 10.0, prevPrice: 10.0, volatility: 0.0, supply: 100)])
    m.shockChance = 0  # deterministic: no random shocks
    m.dividendPct = 0.05  # 5% of the holdings value per tick
    m.addHolding("mario", "pasta", 1, 10.0)
    discard m.tick()  # accrual: 10 * 0.05 = 0.5
    check m.payDividends("mario") == 0  # 0.5 < 1 coin: nothing to pay
    discard m.tick()  # accrual: 0.5 + 0.5 = 1.0
    check m.payDividends("mario") == 1  # pays the whole coin
    check m.payDividends("mario") == 0  # nothing left
    check m.payDividends("nobody") == 0

  test "dividends are credited per stock proportionally":
    let m = sm.newStockMarket("/tmp/test_stocks_market8.json")
    m.setStocks(@[
      sm.Stock(name: "Pasta", basePrice: 10.0, price: 10.0, prevPrice: 10.0, volatility: 0.0),
      sm.Stock(name: "GPU", basePrice: 20.0, price: 20.0, prevPrice: 20.0, volatility: 0.0)
    ])
    m.addHolding("mario", "pasta", 1, 10.0)  # value 10
    m.addHolding("mario", "gpu", 1, 20.0)    # value 20
    m.dividendAccrual["mario"] = 10.0  # 10 coins to split 1/3 - 2/3
    check m.payDividends("mario") == 10
    check m.dividendsPaid("mario", "pasta") == 3
    check m.dividendsPaid("mario", "gpu") == 7
    check m.dividendsPaid("mario", "unknown") == 0
    check m.payDividends("mario") == 0

  test "round2 arrotonda a 2 decimali":
    check sm.round2(1.005) == 1.0  # bankers/rounding to 2 digits
    check sm.round2(1.234) == 1.23
    check sm.round2(1.999) == 2.0

  test "price reverts to the supply/demand equilibrium":
    let m = sm.newStockMarket("/tmp/test_stocks_equil.json")
    m.setStocks(@[sm.Stock(name: "Pasta", basePrice: 10.0, price: 10.0,
                           prevPrice: 10.0, volatility: 0.0, supply: 100)])
    m.shockChance = 0
    m.noiseScale = 0.0  # no noise: pure mean reversion
    m.reversion = 0.5
    # half the supply held: eq = 10 * (1 + 50/100)^1 = 15
    m.addHolding("mario", "pasta", 50, 500.0)
    check m.stock("pasta").get().price < 15.0
    for _ in 0 ..< 20:
      discard m.tick()
    # the price converges to the equilibrium (15)
    check abs(m.stock("pasta").get().price - 15.0) < 0.5

  test "fake holdings are isolated from real holdings and drive the price":
    let m = sm.newStockMarket("/tmp/test_stocks_fake.json")
    m.setStocks(@[sm.Stock(name: "Pasta", basePrice: 10.0, price: 10.0,
                           prevPrice: 10.0, volatility: 0.0, supply: 100)])
    m.shockChance = 0
    m.noiseScale = 0.0
    m.reversion = 1.0  # snap to the equilibrium in one tick
    # a fake investor holds 50: totalHeld = 50, eq = 10 * 1.5 = 15
    m.addFakeHolding("bot1", "pasta", 50)
    check m.totalHeld("pasta") == 50
    check m.fakeTotalHeld("pasta") == 50
    check m.holdingQty("mario", "pasta") == 0  # isolated: not a real user
    discard m.tick()
    check abs(m.stock("pasta").get().price - 15.0) < 0.5
    # remove the fake holding: eq back to 10
    check m.removeFakeHolding("bot1", "pasta", 50)
    check m.totalHeld("pasta") == 0
    discard m.tick()
    check abs(m.stock("pasta").get().price - 10.0) < 0.5

  test "fake holdings: remove more than held fails":
    let m = sm.newStockMarket("/tmp/test_stocks_fake2.json")
    m.setStocks(@[sm.Stock(name: "Pasta", basePrice: 10.0, price: 10.0,
                           prevPrice: 10.0, volatility: 0.0, supply: 100)])
    m.addFakeHolding("bot1", "pasta", 5)
    check not m.removeFakeHolding("bot1", "pasta", 10)
    check m.fakeHoldingQty("bot1", "pasta") == 5
    check m.removeFakeHolding("bot1", "pasta", 5)
    check m.fakeHoldingQty("bot1", "pasta") == 0
