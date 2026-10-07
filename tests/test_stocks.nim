import std/[unittest, asyncdispatch, strutils, tables, json, os, options]

import ./utils
import ../src/kairosbot/commands/registry
import ../src/kairosbot/core/economy
import ../src/kairosbot/plugin
import ../commands/stocks/main as cmd_stocks
import ../commands/stocks/stock_market as sm
import ../commands/economy/main as cmd_econ

suite "StocksPlugin":

  test "register registers the 4 commands and hooks up the economy":
    let ctx = makeMockContext("stocks", Port(18900), dir = "commands/stocks")
    cmd_econ.register(newPluginContext(ctx.platform, "economy", dir = "commands/economy"))
    cmd_stocks.register(ctx)
    let router = ctx.platform.router
    check router.registry.get("stock").isSome
    check router.registry.get("buy").isSome
    check router.registry.get("sell").isSome
    check router.registry.get("portfolio").isSome
    check cmd_stocks.econ != nil
    check cmd_stocks.market.stocks.len > 0

  test "cmdStock lists the stocks with price and trend":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18901))
      let ctx = makeMockContext("stocks", Port(18901), dir = "commands/stocks")
      cmd_econ.register(newPluginContext(ctx.platform, "economy", dir = "commands/economy"))
      cmd_stocks.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("stock").get()
      await cmd_stocks.cmdStock(mkMsg("!stock"), cmd, router)
      let sent = sentMessages()
      check sent[0].contains("Pasta")
      check sent[0].contains("GPU")
    waitFor(runTest())

  test "cmdBuy buys: charges the economy and updates the holdings":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18902))
      let ctx = makeMockContext("stocks", Port(18902), dir = "commands/stocks")
      cmd_econ.register(newPluginContext(ctx.platform, "economy", dir = "commands/economy"))
      cmd_stocks.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("buy").get()
      let econ = cast[EconomyService](ctx.platform.services["economy"])
      let balBefore = econ.getBalance("mario")

      var msg = mkMsg("!buy pasta 5")
      msg.args = "pasta 5"
      await cmd_stocks.cmdBuy(msg, cmd, router)

      check cmd_stocks.market.holdingQty("mario", "pasta") == 5
      # cost = 5 * 10 = 50, plus the broker fee (derived from the market model)
      check econ.getBalance("mario") == balBefore - 50 -
        cmd_stocks.market.brokerFeeFor(50.0)
    waitFor(runTest())

  test "cmdBuy with insufficient balance does not buy":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18903))
      let ctx = makeMockContext("stocks", Port(18903), dir = "commands/stocks")
      cmd_econ.register(newPluginContext(ctx.platform, "economy", dir = "commands/economy"))
      cmd_stocks.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("buy").get()
      let econ = cast[EconomyService](ctx.platform.services["economy"])
      # GPU costs 150: mario only has 100
      var msg = mkMsg("!buy GPU 1")
      msg.args = "GPU 1"
      await cmd_stocks.cmdBuy(msg, cmd, router)
      check cmd_stocks.market.holdingQty("mario", "GPU") == 0
      let sent = sentMessages()
      # the balance is data: it must appear in any translation
      check sent[0].contains("100")
    waitFor(runTest())

  test "cmdBuy with an unknown stock":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18904))
      let ctx = makeMockContext("stocks", Port(18904), dir = "commands/stocks")
      cmd_econ.register(newPluginContext(ctx.platform, "economy", dir = "commands/economy"))
      cmd_stocks.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("buy").get()
      var msg = mkMsg("!buy dragon 1")
      msg.args = "dragon 1"
      await cmd_stocks.cmdBuy(msg, cmd, router)
      let sent = sentMessages()
      # the unknown item is echoed: data that must appear in any translation
      check sent[0].contains("dragon")
    waitFor(runTest())

  test "cmdBuy with invalid arguments":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18905))
      let ctx = makeMockContext("stocks", Port(18905), dir = "commands/stocks")
      cmd_econ.register(newPluginContext(ctx.platform, "economy", dir = "commands/economy"))
      cmd_stocks.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("buy").get()
      var msg = mkMsg("!buy pasta")
      msg.args = "pasta"
      await cmd_stocks.cmdBuy(msg, cmd, router)
      let sent = sentMessages()
      # the usage shows prefix+command: data that must appear in any translation
      check sent[0].contains("!buy")
    waitFor(runTest())

  test "cmdSell sells: credits the economy and removes the holdings":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18906))
      let ctx = makeMockContext("stocks", Port(18906), dir = "commands/stocks")
      cmd_econ.register(newPluginContext(ctx.platform, "economy", dir = "commands/economy"))
      cmd_stocks.register(ctx)
      let router = ctx.platform.router
      let buy = router.registry.get("buy").get()
      let sell = router.registry.get("sell").get()
      let econ = cast[EconomyService](ctx.platform.services["economy"])
      # buys 5 pasta
      var bmsg = mkMsg("!buy pasta 5")
      bmsg.args = "pasta 5"
      await cmd_stocks.cmdBuy(bmsg, buy, router)
      let balAfterBuy = econ.getBalance("mario")
      # sells 2 pasta (proceeds 20)
      var smsg = mkMsg("!sell pasta 2")
      smsg.args = "pasta 2"
      await cmd_stocks.cmdSell(smsg, sell, router)
      check cmd_stocks.market.holdingQty("mario", "pasta") == 3
      # proceeds 2 * 10 = 20, minus the broker fee (market model)
      check econ.getBalance("mario") == balAfterBuy + 20 -
        cmd_stocks.market.brokerFeeFor(20.0)
    waitFor(runTest())

  test "cmdSell without sufficient holdings":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18907))
      let ctx = makeMockContext("stocks", Port(18907), dir = "commands/stocks")
      cmd_econ.register(newPluginContext(ctx.platform, "economy", dir = "commands/economy"))
      cmd_stocks.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("sell").get()
      var msg = mkMsg("!sell pasta 5")
      msg.args = "pasta 5"
      await cmd_stocks.cmdSell(msg, cmd, router)
      let sent = sentMessages()
      # the stock name is echoed: data that must appear in any translation
      check sent[0].contains("Pasta")
    waitFor(runTest())

  test "cmdPortfolio shows the holdings and the PnL":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18908))
      let ctx = makeMockContext("stocks", Port(18908), dir = "commands/stocks")
      cmd_econ.register(newPluginContext(ctx.platform, "economy", dir = "commands/economy"))
      cmd_stocks.register(ctx)
      let router = ctx.platform.router
      let buy = router.registry.get("buy").get()
      let port = router.registry.get("portfolio").get()
      var bmsg = mkMsg("!buy pasta 5")
      bmsg.args = "pasta 5"
      await cmd_stocks.cmdBuy(bmsg, buy, router)
      await cmd_stocks.cmdPortfolio(mkMsg("!portfolio"), port, router)
      let sent = sentMessages()
      # the item and its value are data: they must appear in any translation
      check sent[1].contains("Pasta")
      check sent[1].contains("50")
    waitFor(runTest())

  test "cmdPortfolio with no holdings":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18909))
      let ctx = makeMockContext("stocks", Port(18909), dir = "commands/stocks")
      cmd_econ.register(newPluginContext(ctx.platform, "economy", dir = "commands/economy"))
      cmd_stocks.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("portfolio").get()
      await cmd_stocks.cmdPortfolio(mkMsg("!portfolio"), cmd, router)
      let sent = sentMessages()
      check sent[0].contains("mario")
    waitFor(runTest())
