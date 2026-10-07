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
      check sent.len == 1
      # the balance value is data: it must appear in any translation
      check sent[0].contains("100")
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
      # usernames are data: they must appear in any translation
      check sent.len == 1
      check sent[0].contains("alice")
      check sent[0].contains("bob")
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
      # the trophy name comes from the plugin data (trophies.json): derive
      # the expectation from the same source, never hardcode the string
      let ft = trophyText(cmd_econ.trophyTexts, "first_to", "First to 1000",
                          "🏆 {user} unlocked the trophy \"{name}\"!")
      let expected = ft.name.replace("{amount}", $svc.firstTo)
      let trophies = router.trophyTracker.getUserTrophies("luigi")
      check trophies.anyIt(it.name == expected)
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

  test "payrollTick: per-user clock, first-pay trophy, public announce":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 20, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18882))

      let ctx = makeMockContext("economy", Port(18882), dir = "commands/economy")
      cmd_econ.register(ctx)
      let svc = cast[EconomyService](ctx.platform.services["economy"])
      # reset shared module state: the mock temp dirs persist across runs
      svc.balances = initTable[string, int]()
      cmd_econ.nextPayAt = initTable[string, int]()
      let tracker = ctx.platform.trophyTracker
      let chat = ctx.platform.router.chat
      let cfg = cmd_econ.PayrollConfig(amount: 10, intervalMinutes: 60,
        message: "💸 {user}, added {amount} 🪙 to your balance!",
        firstPayTrophy: "First Paycheck")
      let now0 = 1_000_000

      # mario enters at now0
      discard svc.getBalance("mario")
      # first tick: mario is scheduled, not paid yet
      await cmd_econ.payrollTick(chat, tracker, cfg, now0)
      check svc.balances["mario"] == 100
      check sentMessages().len == 0
      # 30 min later: still not due
      await cmd_econ.payrollTick(chat, tracker, cfg, now0 + 1800)
      check svc.balances["mario"] == 100
      check sentMessages().len == 0
      # 60 min after entry: due -> paid + trophy + public announce
      await cmd_econ.payrollTick(chat, tracker, cfg, now0 + 3600)
      check svc.balances["mario"] == 110
      # the trophy name comes from the rule registered from the plugin data
      let payRule = tracker.rules["payroll"][0]
      check tracker.getUserTrophies("mario").anyIt(it.name == payRule.name)
      let sent = sentMessages()
      check sent.anyIt(it.contains(payRule.name))
      # username and amount are data: they must appear in any translation
      check sent.anyIt(it.contains("mario") and it.contains("10"))
      # second pay an hour later: balance grows, no duplicate trophy
      await cmd_econ.payrollTick(chat, tracker, cfg, now0 + 7200)
      check svc.balances["mario"] == 120
      check tracker.getUserTrophies("mario").len == 1
    waitFor(runTest())

  test "payrollTick: two users are paid on their own clocks":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 20, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18883))

      let ctx = makeMockContext("economy", Port(18883), dir = "commands/economy")
      cmd_econ.register(ctx)
      let svc = cast[EconomyService](ctx.platform.services["economy"])
      # reset shared module state: the mock temp dirs persist across runs
      svc.balances = initTable[string, int]()
      cmd_econ.nextPayAt = initTable[string, int]()
      let tracker = ctx.platform.trophyTracker
      let chat = ctx.platform.router.chat
      let cfg = cmd_econ.PayrollConfig(amount: 10, intervalMinutes: 60,
        message: "💸 {user}, added {amount} 🪙 to your balance!",
        firstPayTrophy: "First Paycheck")
      let now0 = 1_000_000

      # a enters at now0
      discard svc.getBalance("a")
      await cmd_econ.payrollTick(chat, tracker, cfg, now0)
      # b enters 25 min later
      discard svc.getBalance("b")
      await cmd_econ.payrollTick(chat, tracker, cfg, now0 + 1800)
      # 25 min in: neither is due yet
      check svc.balances["a"] == 100
      check svc.balances["b"] == 100
      # at now0+3600: a is due on a's own clock, b is NOT
      await cmd_econ.payrollTick(chat, tracker, cfg, now0 + 3600)
      check svc.balances["a"] == 110
      check svc.balances["b"] == 100
      # at now0+5400: b is due, a is not (a next due at now0+7200)
      await cmd_econ.payrollTick(chat, tracker, cfg, now0 + 5400)
      check svc.balances["a"] == 110
      check svc.balances["b"] == 110
    waitFor(runTest())

  test "payrollTick: no catch-up storm after downtime":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 20, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18884))

      let ctx = makeMockContext("economy", Port(18884), dir = "commands/economy")
      cmd_econ.register(ctx)
      let svc = cast[EconomyService](ctx.platform.services["economy"])
      # reset shared module state: the mock temp dirs persist across runs
      svc.balances = initTable[string, int]()
      cmd_econ.nextPayAt = initTable[string, int]()
      let tracker = ctx.platform.trophyTracker
      let chat = ctx.platform.router.chat
      let cfg = cmd_econ.PayrollConfig(amount: 10, intervalMinutes: 60,
        message: "💸 {user}, added {amount} 🪙 to your balance!",
        firstPayTrophy: "First Paycheck")
      let now0 = 1_000_000

      # mario scheduled at now0+3600, then the bot is "offline" for 5 hours
      discard svc.getBalance("mario")
      await cmd_econ.payrollTick(chat, tracker, cfg, now0)
      # 5 hours later: overdue by way more than one interval -> paid ONCE
      await cmd_econ.payrollTick(chat, tracker, cfg, now0 + 18000)
      check svc.balances["mario"] == 110
      # and the next pay is rescheduled to >= now+interval (not due yet)
      await cmd_econ.payrollTick(chat, tracker, cfg, now0 + 19800)
      check svc.balances["mario"] == 110
    waitFor(runTest())
