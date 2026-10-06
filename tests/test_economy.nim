import std/[unittest, asyncdispatch, strutils, tables, json, os, options]
import std/collections/sequtils

import ./utils
import ../src/kairosbot/commands/registry
import ../src/kairosbot/core/economy
import ../src/kairosbot/core/trophy_tracker
import ../src/kairosbot/plugin
import ../commands/economy/main as cmd_econ

suite "EconomyService":

  test "newEconomyService creates the service with empty balances":
    let path = getTempDir() / "kairos_test_econ_svc.json"
    let svc = newEconomyService(path, startBalance = 100, minBet = 1)
    check svc.balances.len == 0
    check svc.startBalance == 100
    check svc.minBet == 1

  test "getBalance assigns the starting balance to a new user":
    let svc = newEconomyService(getTempDir() / "kairos_test_econ_svc2.json")
    check svc.getBalance("mario") == 100
    check svc.balances["mario"] == 100
    # case-insensitive
    check svc.getBalance("MARIO") == 100

  test "transfer moves coins and validates insufficient/self":
    let svc = newEconomyService(getTempDir() / "kairos_test_econ_svc3.json")
    check svc.transfer("mario", "luigi", 30)
    check svc.balances["mario"] == 70
    check svc.balances["luigi"] == 130
    check not svc.transfer("mario", "luigi", 999)  # insufficient
    check not svc.transfer("mario", "mario", 10)   # to itself

  test "applyWager charges the bet and credits the win":
    let svc = newEconomyService(getTempDir() / "kairos_test_econ_svc4.json")
    # loses: -10
    discard svc.applyWager("mario", 10, 0)
    check svc.balances["mario"] == 90
    # wins 15x on 10: payout = 150, net +140
    discard svc.applyWager("mario", 10, 150)
    check svc.balances["mario"] == 230
    check svc.maxWins["mario"] == 150

  test "checkFirstTo assigns the first to reach the threshold only once":
    let svc = newEconomyService(getTempDir() / "kairos_test_econ_svc5.json")
    svc.balances["mario"] = 1000
    check svc.checkFirstTo("mario")
    check svc.firstToThousand == "mario"
    # the second one does not get it
    svc.balances["luigi"] = 1000
    check not svc.checkFirstTo("luigi")
    check svc.firstToThousand == "mario"

  test "topBalances returns the top N in descending order":
    let svc = newEconomyService(getTempDir() / "kairos_test_econ_svc6.json")
    svc.balances["a"] = 10
    svc.balances["b"] = 300
    svc.balances["c"] = 200
    svc.balances["d"] = 50
    let top = svc.topBalances(3)
    check top.len == 3
    check top[0] == ("b", 300)
    check top[1] == ("c", 200)
    check top[2] == ("d", 50)

  test "persistence: the economy state survives a reload":
    let path = getTempDir() / "kairos_test_econ_persist.json"
    let svc1 = newEconomyService(path)
    discard svc1.getBalance("mario")
    svc1.balances["mario"] = 42
    svc1.saveEconomy()
    let svc2 = newEconomyService(path)
    check svc2.balances["mario"] == 42

suite "EconomyPlugin":

  test "register exposes the service and registers the commands":
    let ctx = makeMockContext("economy", Port(18870), dir = "commands/economy")
    cmd_econ.register(ctx)
    let router = ctx.platform.router
    check ctx.platform.services.hasKey("economy")
    let svc = cast[EconomyService](ctx.platform.services["economy"])
    check svc.startBalance == 100
    check router.registry.get("balance").get().cooldown == 0.0
    check router.registry.get("pay").get().cooldown == 10.0
    check router.registry.get("rich").get().cooldown == 10.0
    check router.handlers.hasKey("balance")
    check router.handlers.hasKey("pay")
    check router.handlers.hasKey("rich")
    check router.trophyTracker.rules.hasKey("pay")

  test "cmdBalance shows the balance":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18871))

      let ctx = makeMockContext("economy", Port(18871), dir = "commands/economy")
      cmd_econ.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("balance").get()
      await cmd_econ.cmdBalance(mkMsg("!balance"), cmd, router)
      let sent = sentMessages()
      check sent[0].contains("your balance: 100 🪙")
    waitFor(runTest())

  test "cmdPay gives away coins and handles errors":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 10, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18872))

      let ctx = makeMockContext("economy", Port(18872), dir = "commands/economy")
      cmd_econ.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("pay").get()
      let svc = cast[EconomyService](ctx.platform.services["economy"])

      # correct usage
      var msg = mkMsg("!pay luigi 20")
      msg.args = "luigi 20"
      await cmd_econ.cmdPay(msg, cmd, router)
      check svc.balances["mario"] == 80
      check svc.balances["luigi"] == 120

      # invalid amount
      var bad = mkMsg("!pay luigi abc")
      bad.args = "luigi abc"
      await cmd_econ.cmdPay(bad, cmd, router)
      check svc.balances["mario"] == 80

      # insufficient
      var poor = mkMsg("!pay luigi 999")
      poor.args = "luigi 999"
      await cmd_econ.cmdPay(poor, cmd, router)
      check svc.balances["mario"] == 80
    waitFor(runTest())

  test "cmdRich shows the leaderboard":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18873))

      let ctx = makeMockContext("economy", Port(18873), dir = "commands/economy")
      cmd_econ.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("rich").get()
      let svc = cast[EconomyService](ctx.platform.services["economy"])
      svc.balances["alice"] = 500
      svc.balances["bob"] = 300
      svc.balances["carl"] = 100

      await cmd_econ.cmdRich(mkMsg("!rich"), cmd, router)
      let sent = sentMessages()
      check sent[0].contains("Top balances")
      check sent[0].contains("alice")
      check sent[0].contains("🥇")
    waitFor(runTest())

  test "cmdPay assegna il trofeo 'First to 1000' al destinatario":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 10, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18874))

      let ctx = makeMockContext("economy", Port(18874), dir = "commands/economy")
      cmd_econ.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("pay").get()
      let svc = cast[EconomyService](ctx.platform.services["economy"])
      # mario has 1200, gives 950 to luigi -> luigi from 100 to 1050 (first to 1000)
      svc.balances["mario"] = 1200

      var msg = mkMsg("!pay luigi 950")
      msg.args = "luigi 950"
      await cmd_econ.cmdPay(msg, cmd, router)

      check svc.balances["luigi"] == 1050
      check svc.firstToThousand == "luigi"
      let trophies = router.trophyTracker.getUserTrophies("luigi")
      check trophies.anyIt(it.name == "First to 1000")
    waitFor(runTest())

  test "loadPayrollConfig reads values and falls back to defaults":
    # missing file -> defaults
    let d = cmd_econ.loadPayrollConfig(getTempDir() / "kairos_test_no_payroll.json")
    check d.amount == 10
    check d.intervalMinutes == 60
    check d.firstPayTrophy == "First Paycheck"

    # custom values
    let path = getTempDir() / "kairos_test_payroll_cfg.json"
    writeFile(path, """{"payroll":{"amount":25,"intervalMinutes":15,"message":"Hi {amount}","firstPayTrophy":"Cash In"}}""")
    let c = cmd_econ.loadPayrollConfig(path)
    check c.amount == 25
    check c.intervalMinutes == 15
    check c.message == "Hi {amount}"
    check c.firstPayTrophy == "Cash In"

  test "runPayroll credits users, unlocks the first-pay trophy, broadcasts":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 10, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18880))

      let svc = newEconomyService(getTempDir() / "kairos_test_payroll_svc.json")
      svc.balances["mario"] = 0
      svc.balances["luigi"] = 5
      let ctx = makeMockContext("economy", Port(18880), dir = "commands/economy")
      let tracker = ctx.platform.trophyTracker
      tracker.addRules("payroll", @[
        TrophyRule(name: "First Paycheck", eventType: "payday",
          threshold: 1, description: "Received your first payroll",
          ruleType: trtTotal)
      ])
      let cfg = cmd_econ.PayrollConfig(amount: 10, intervalMinutes: 60,
        message: "💸 Payday! Added {amount} 🪙 to your balance!",
        firstPayTrophy: "First Paycheck")
      let chat = ctx.platform.router.chat
      await cmd_econ.runPayroll(svc, tracker, chat, cfg)

      # balances credited
      check svc.balances["mario"] == 10
      check svc.balances["luigi"] == 15
      # first-pay trophy awarded to both
      check tracker.getUserTrophies("mario").anyIt(it.name == "First Paycheck")
      check tracker.getUserTrophies("luigi").anyIt(it.name == "First Paycheck")
      # message broadcast with the amount substituted
      let sent = sentMessages()
      check sent[0].contains("Added 10")

      # second cycle: balance grows, no duplicate trophy
      let before = tracker.getUserTrophies("mario").len
      await cmd_econ.runPayroll(svc, tracker, chat, cfg)
      check svc.balances["mario"] == 20
      check tracker.getUserTrophies("mario").len == before
    waitFor(runTest())

  test "runPayroll is a no-op when there are no users":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18881))

      let svc = newEconomyService(getTempDir() / "kairos_test_payroll_empty.json")
      let ctx = makeMockContext("economy", Port(18881), dir = "commands/economy")
      let tracker = ctx.platform.trophyTracker
      let cfg = cmd_econ.PayrollConfig(amount: 10, intervalMinutes: 60,
        message: "💸 Payday! Added {amount} 🪙 to your balance!",
        firstPayTrophy: "First Paycheck")
      let chat = ctx.platform.router.chat
      await cmd_econ.runPayroll(svc, tracker, chat, cfg)
      # nobody credited, no message sent
      check svc.balances.len == 0
      check sentMessages().len == 0
    waitFor(runTest())
