import std/[unittest, asyncdispatch, strutils, tables, json, os, options]

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
      sm.Stock(name: "Pasta", price: 10.0, prevPrice: 10.0, volatility: 0.08),
      sm.Stock(name: "GPU", price: 150.0, prevPrice: 150.0, volatility: 0.15)
    ])
    check m.stocks.len == 2
    check m.stock("pasta").isSome
    check m.stock("Pasta").get().price == 10.0
    check m.stock("unknown").isNone

  test "tick updates prices and prevPrice":
    let m = sm.newStockMarket("/tmp/test_stocks_market3.json")
    m.setStocks(@[
      sm.Stock(name: "Pasta", price: 10.0, prevPrice: 10.0, volatility: 0.5)
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
    m.setStocks(@[sm.Stock(name: "Pasta", price: 10.0, prevPrice: 10.0, volatility: 0.08)])
    m.addHolding("Mario", "pasta", 3, 30.0)
    check m.holdingQty("mario", "pasta") == 3
    check m.holdingQty("Mario", "PASTA") == 3
    check m.holdingQty("luigi", "pasta") == 0

  test "removeHolding: ok and insufficient":
    let m = sm.newStockMarket("/tmp/test_stocks_market5.json")
    m.setStocks(@[sm.Stock(name: "Pasta", price: 10.0, prevPrice: 10.0, volatility: 0.08)])
    m.addHolding("mario", "pasta", 5, 50.0)
    check m.removeHolding("mario", "pasta", 2, 20.0)
    check m.holdingQty("mario", "pasta") == 3
    check not m.removeHolding("mario", "pasta", 10, 100.0)
    check m.holdingQty("mario", "pasta") == 3

  test "portfolioValue e pnl":
    let m = sm.newStockMarket("/tmp/test_stocks_market6.json")
    m.setStocks(@[sm.Stock(name: "Pasta", price: 10.0, prevPrice: 10.0, volatility: 0.08)])
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
    m.setStocks(@[sm.Stock(name: "Pasta", price: 10.0, prevPrice: 10.0, volatility: 0.08)])
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
    m.setStocks(@[sm.Stock(name: "Pasta", price: 10.0, prevPrice: 10.0, volatility: 0.0)])
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
      sm.Stock(name: "Pasta", price: 10.0, prevPrice: 10.0, volatility: 0.0),
      sm.Stock(name: "GPU", price: 20.0, prevPrice: 20.0, volatility: 0.0)
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
