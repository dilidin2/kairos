import std/[unittest, asyncdispatch, strutils, tables, json, os, options, times]

import ./utils
import ../src/kairosbot/commands/registry
import ../src/kairosbot/core/trophy_tracker
import ../src/kairosbot/core/attempt_tracker
import ../src/kairosbot/core/economy
import ../src/kairosbot/plugin
import ../commands/games/main as cmd_games
import ../commands/economy/main as cmd_econ

suite "GamesPlugin":

  test "getSlotSymbols returns the list of symbols":
    let symbols = cmd_games.getSlotSymbols()
    check symbols.len == 8
    check "🍒" in symbols
    check "7️⃣" in symbols

  test "getWinningCombos: 5 combos of 3 symbols":
    let combos = cmd_games.getWinningCombos()
    check combos.len == 5
    for c in combos:
      check c.len == 3
      check c[0] == c[1] and c[1] == c[2]

  test "generateWinningCombo always returns a winning combo":
    for i in 1 .. 50:
      let c = cmd_games.generateWinningCombo()
      check cmd_games.getWinningCombos().contains(c)

  test "generateLosingCombo never matches a winning combo":
    let combos = cmd_games.getWinningCombos()
    for i in 1 .. 200:
      let c = cmd_games.generateLosingCombo()
      check c.len == 3
      check not combos.contains(c)

  test "generateSlotResult with probability 1.0 always wins":
    for i in 1 .. 50:
      let r = cmd_games.generateSlotResult(1.0)
      check r.isWin
      check cmd_games.getWinningCombos().contains(r.symbols)
      check r.winCombo.len > 0

  test "generateSlotResult with probability 0.0 always loses":
    for i in 1 .. 50:
      let r = cmd_games.generateSlotResult(0.0)
      check not r.isWin
      check r.winCombo == ""
      check not cmd_games.getWinningCombos().contains(r.symbols)

  test "get8ballResponse returns a non-empty response":
    for i in 1 .. 20:
      check cmd_games.get8ballResponse().len > 0

  test "formatSlotResult winning/losing, with and without bet":
    let win = cmd_games.SlotResult(symbols: @["🍀", "🍀", "🍀"],
      isWin: true, winCombo: "🍀 🍀 🍀")
    let w1 = cmd_games.formatSlotResult(win, "")
    check w1.contains("WIN")
    check w1.contains("🍀 🍀 🍀")
    let w2 = cmd_games.formatSlotResult(win, "🍀")
    check w2.contains("guessed")

    let lose = cmd_games.SlotResult(symbols: @["🍒", "💎", "🔔"],
      isWin: false, winCombo: "")
    let l1 = cmd_games.formatSlotResult(lose, "")
    check l1.contains("🍒 💎 🔔")
    check not l1.contains("WIN")
    let l2 = cmd_games.formatSlotResult(lose, "🍒")
    check l2.contains("Bet on 🍒")

  test "getWinProbability: default and spec override":
    var spec = CommandSpec(name: "slots")
    check cmd_games.getWinProbability(spec) == cmd_games.DefaultWinProbability

    spec.params["win_probability"] = newJFloat(0.3)
    check cmd_games.getWinProbability(spec) == 0.3

  test "createSlotsRules, create8ballRules e createFlipRules":
    let slotsRules = cmd_games.createSlotsRules()
    check slotsRules.len == 3
    check slotsRules[0].name == "Gambler"
    check slotsRules[0].eventType == "win"
    check slotsRules[2].ruleType == trtStreak

    let ballRules = cmd_games.create8ballRules()
    check ballRules.len == 2
    check ballRules[0].eventType == "ask"

    let flipRules = cmd_games.createFlipRules()
    check flipRules.len == 2
    check flipRules[0].eventType == "flip"
    check flipRules[1].ruleType == trtStreak
    check flipRules[1].eventType == "win"

  test "register registers commands, trophy rules and handlers":
    let ctx = makeMockContext("games", Port(18840), dir = "commands/games")
    cmd_games.register(ctx)
    let router = ctx.platform.router
    let slots = router.registry.get("slots").get()
    check slots.cooldown == 30.0
    check slots.maxAttemptsPerDay == 5
    check router.registry.get("8ball").get().maxAttemptsPerDay == 0
    check router.registry.get("flip").get().cooldown == 5.0
    check router.trophyTracker.rules.hasKey("slots")
    check router.trophyTracker.rules.hasKey("8ball")
    check router.trophyTracker.rules.hasKey("flip")
    check router.handlers.hasKey("8ball")
    check router.handlers.hasKey("slots")
    check router.handlers.hasKey("flip")

  test "cmd8ball sends the response and records the event":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18841))

      let ctx = makeMockContext("games", Port(18841))
      cmd_games.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("8ball").get()
      await cmd_games.cmd8ball(mkMsg("!8ball"), cmd, router)
      # 1 response + 1 trophy notification (first question -> "Wisdom")
      let sent = sentBodies()
      check sent.len == 2
      check sent[0].len > 5
      check sent[1].contains("Wisdom")
      let trophies = router.trophyTracker.getUserTrophies("mario")
      check trophies.len == 1
      check trophies[0].name == "Wisdom"
    waitFor(runTest())

  test "cmdFlip with no argument flips the coin and records the flip":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18843))

      let ctx = makeMockContext("games", Port(18843), dir = "commands/games")
      cmd_games.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("flip").get()
      # the outcomes come from the plugin data (commands.json): derive them
      let (heads, tails) = cmd_games.getFlipOutcomes()
      await cmd_games.cmdFlip(mkMsg("!flip"), cmd, router)
      let sent = sentMessages()
      check sent[0].contains(heads & "!") or sent[0].contains(tails & "!")
      check router.trophyTracker.counters[
        makeCounterKey("mario", "flip", "flip")] == 1
    waitFor(runTest())

  test "cmdFlip with a bet records win/loss":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 10, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18844))

      let ctx = makeMockContext("games", Port(18844), dir = "commands/games")
      cmd_games.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("flip").get()
      # bet on a REAL outcome from the plugin data (commands.json)
      let (heads, tails) = cmd_games.getFlipOutcomes()
      var msg = mkMsg("!flip " & heads)
      msg.args = heads
      await cmd_games.cmdFlip(msg, cmd, router)
      let sent = sentMessages()
      # the bet is echoed (data) and the outcome is announced
      check sent[0].contains(heads.toLowerAscii())
      check sent[0].contains(heads & "!") or sent[0].contains(tails & "!")
      # the flip always counts, plus win or loss
      check router.trophyTracker.counters[
        makeCounterKey("mario", "flip", "flip")] == 1
      let win = router.trophyTracker.counters.getOrDefault(
        makeCounterKey("mario", "flip", "win"), 0)
      let loss = router.trophyTracker.counters.getOrDefault(
        makeCounterKey("mario", "flip", "loss"), 0)
      check (win == 1 and loss == 0) or (win == 0 and loss == 1)
    waitFor(runTest())

  test "cmdSlots sends the result and records win/loss":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18842))

      let ctx = makeMockContext("games", Port(18842))
      cmd_games.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("slots").get()
      var msg = mkMsg("!slots 🍀")
      msg.args = "🍀"
      # probability 0: always loses, 'loss' event
      cmd_games.specs["slots"] = CommandSpec(name: "slots")
      cmd_games.specs["slots"].params["win_probability"] = newJFloat(0.0)
      await cmd_games.cmdSlots(msg, cmd, router)
      let sent = sentBodies()
      check sent.len == 1
      check sent[0].contains("nope, try again")
      check router.trophyTracker.counters[
        makeCounterKey("mario", "slots", "loss")] == 1
    waitFor(runTest())

  test "slotMultiplier returns the multiplier per combo":
    check cmd_games.slotMultiplier(@["🍒", "🍒", "🍒"]) == 2
    check cmd_games.slotMultiplier(@["💎", "💎", "💎"]) == 5
    check cmd_games.slotMultiplier(@["🔔", "🔔", "🔔"]) == 8
    check cmd_games.slotMultiplier(@["7️⃣", "7️⃣", "7️⃣"]) == 10
    check cmd_games.slotMultiplier(@["🍀", "🍀", "🍀"]) == 15

  test "cmdBet with flip: correct usage and balance":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 10, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18845))

      let ctx = makeMockContext("games", Port(18845), dir = "commands/games")
      cmd_econ.register(newPluginContext(ctx.platform, "economy", dir = "commands/economy"))
      cmd_games.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("bet").get()
      let svc = cast[EconomyService](ctx.platform.services["economy"])

      # wrong usage
      var bad = mkMsg("!bet abc flip")
      bad.args = "abc flip"
      await cmd_games.cmdBet(bad, cmd, router)
      check svc.balances.getOrDefault("mario", 0) == 0

      # valid bet on flip: the balance changes (wins or loses)
      var msg = mkMsg("!bet 10 flip")
      msg.args = "10 flip"
      await cmd_games.cmdBet(msg, cmd, router)
      let bal = svc.balances["mario"]
      # if it wins: 100 - 10 + 20 = 110; if it loses: 100 - 10 = 90
      check bal == 110 or bal == 90
    waitFor(runTest())

  test "cmdBet with slots consumes the daily attempt":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 10, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18846))

      let ctx = makeMockContext("games", Port(18846), dir = "commands/games")
      cmd_econ.register(newPluginContext(ctx.platform, "economy", dir = "commands/economy"))
      cmd_games.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("bet").get()

      var msg = mkMsg("!bet 5 slots")
      msg.args = "5 slots"
      await cmd_games.cmdBet(msg, cmd, router)
      check router.attemptTracker.getAttemptsUsed("mario", "slots") == 1
    waitFor(runTest())

  test "cmdBet with insufficient balance does not touch the balance":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 10, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18847))

      let ctx = makeMockContext("games", Port(18847), dir = "commands/games")
      cmd_econ.register(newPluginContext(ctx.platform, "economy", dir = "commands/economy"))
      cmd_games.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("bet").get()
      let svc = cast[EconomyService](ctx.platform.services["economy"])

      var msg = mkMsg("!bet 999 flip")
      msg.args = "999 flip"
      await cmd_games.cmdBet(msg, cmd, router)
      # mario gets the starting balance (100) but the bet does not go out
      check svc.balances.getOrDefault("mario", 0) == 100
    waitFor(runTest())
