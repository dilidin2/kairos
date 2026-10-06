import std/[unittest, asyncdispatch, strutils, tables, json, os, options]

import ./utils
import ../src/kairosbot/commands/registry
import ../src/kairosbot/core/window_guard
import ../src/kairosbot/plugin
import ../commands/quotes/main as cmd_quotes
import ../commands/quotes/quote_game as qg

suite "QuoteGame":

  test "loadPhrases loads the ding and race phrases":
    qg.loadPhrases("commands/quotes/phrases.json")
    let d = qg.pickDingPhrase()
    check d.blank.len > 0
    check d.answer.len > 0
    let r = qg.pickRacePhrase()
    check r.start.len > 0
    check r.ending.len > 0

  test "norm normalizes lowercase/trim/spaces":
    check qg.norm("  Dream  ") == "dream"
    check qg.norm("A  B") == "a b"
    check qg.norm("  ") == ""

  test "isCorrect: exact match, variant and mismatch":
    let g = qg.newQuoteGame()
    g.answer = "dream"
    g.variants = @["sogno"]
    check g.isCorrect("Dream")
    check g.isCorrect("  dream  ")
    check g.isCorrect("sogno")
    check not g.isCorrect("car")

  test "complete: ding replaces the blank, race concatenates":
    let g = qg.newQuoteGame()
    g.mode = qg.qmDing
    g.displayText = "I have a ..."
    check g.complete("dream") == "I have a dream"
    g.mode = qg.qmRace
    g.displayText = "You only live"
    check g.complete("once") == "You only live once"

suite "QuotesPlugin":

  test "register registers the 3 commands":
    let ctx = makeMockContext("quotes", Port(18880), dir = "commands/quotes")
    cmd_quotes.register(ctx)
    cmd_quotes.game.reset()
    let router = ctx.platform.router
    check router.registry.get("ding").get().cooldown == 60.0
    check router.registry.get("dong").get().cooldown == 2.0
    check router.registry.get("race").get().cooldown == 60.0
    check router.handlers.hasKey("ding")
    check router.handlers.hasKey("dong")
    check router.handlers.hasKey("race")

  test "cmdDing opens the window and the ding game":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18881))

      let ctx = makeMockContext("quotes", Port(18881), dir = "commands/quotes")
      cmd_quotes.register(ctx)
      cmd_quotes.game.reset()
      let router = ctx.platform.router
      let cmd = router.registry.get("ding").get()
      await cmd_quotes.cmdDing(mkMsg("!ding"), cmd, router)

      # window acquired, ding game active
      check ctx.platform.windowGuard.isActive()
      check ctx.platform.windowGuard.activeName == "quotes"
      check cmd_quotes.game.active
      check cmd_quotes.game.mode == qg.qmDing
      check cmd_quotes.game.answer.len > 0
      let sent = sentMessages()
      check sent[0].contains("!dong")
    waitFor(runTest())

  test "cmdDing during an ongoing window is rejected":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18882))

      let ctx = makeMockContext("quotes", Port(18882), dir = "commands/quotes")
      cmd_quotes.register(ctx)
      cmd_quotes.game.reset()
      let router = ctx.platform.router
      let cmd = router.registry.get("ding").get()
      # first ding
      await cmd_quotes.cmdDing(mkMsg("!ding"), cmd, router)
      # second ding: rejected
      await cmd_quotes.cmdDing(mkMsg("!ding"), cmd, router)
      let sent = sentMessages()
      check sent[1].contains("another event is running")
    waitFor(runTest())

  test "cmdDong records the answer during the window":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 10, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18883))

      let ctx = makeMockContext("quotes", Port(18883), dir = "commands/quotes")
      cmd_quotes.register(ctx)
      cmd_quotes.game.reset()
      let router = ctx.platform.router
      let ding = router.registry.get("ding").get()
      let dong = router.registry.get("dong").get()
      await cmd_quotes.cmdDing(mkMsg("!ding"), ding, router)

      var msg = mkMsg("!dong dream")
      msg.args = "dream"
      await cmd_quotes.cmdDong(msg, dong, router)
      check cmd_quotes.game.responses.hasKey("mario")
      check cmd_quotes.game.responses["mario"] == "dream"
    waitFor(runTest())

  test "cmdDong with no active window replies with an error":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18884))

      let ctx = makeMockContext("quotes", Port(18884), dir = "commands/quotes")
      cmd_quotes.register(ctx)
      cmd_quotes.game.reset()
      let router = ctx.platform.router
      let dong = router.registry.get("dong").get()
      var msg = mkMsg("!dong dream")
      msg.args = "dream"
      await cmd_quotes.cmdDong(msg, dong, router)
      let sent = sentMessages()
      check sent[0].contains("no ding is in progress")
    waitFor(runTest())

  test "cmdRace opens the window in race mode":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18885))

      let ctx = makeMockContext("quotes", Port(18885), dir = "commands/quotes")
      cmd_quotes.register(ctx)
      cmd_quotes.game.reset()
      let router = ctx.platform.router
      let cmd = router.registry.get("race").get()
      await cmd_quotes.cmdRace(mkMsg("!race"), cmd, router)
      check ctx.platform.windowGuard.isActive()
      check cmd_quotes.game.active
      check cmd_quotes.game.mode == qg.qmRace
      check cmd_quotes.game.answer.len > 0
      let sent = sentMessages()
      check sent[0].contains("!race")
    waitFor(runTest())

  test "cmdRace records the continuation during the window":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 10, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18886))

      let ctx = makeMockContext("quotes", Port(18886), dir = "commands/quotes")
      cmd_quotes.register(ctx)
      cmd_quotes.game.reset()
      let router = ctx.platform.router
      let race = router.registry.get("race").get()
      await cmd_quotes.cmdRace(mkMsg("!race"), race, router)

      var msg = mkMsg("!race once")
      msg.args = "once"
      await cmd_quotes.cmdRace(msg, race, router)
      check cmd_quotes.game.responses["mario"] == "once"
    waitFor(runTest())

  test "publishResults announces the winner and resets the game":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18887))

      let ctx = makeMockContext("quotes", Port(18887), dir = "commands/quotes")
      cmd_quotes.register(ctx)
      cmd_quotes.game.reset()
      let router = ctx.platform.router
      # ding state with one correct and one wrong answer
      cmd_quotes.game.active = true
      cmd_quotes.game.mode = qg.qmDing
      cmd_quotes.game.displayText = "I have a ..."
      cmd_quotes.game.answer = "dream"
      cmd_quotes.game.responses = initTable[string, string]()
      cmd_quotes.game.responses["mario"] = "dream"
      cmd_quotes.game.responses["luigi"] = "car"

      await cmd_quotes.publishResults(router, "got it right!")
      let sent = sentMessages()
      check sent[0].contains("mario: I have a dream")
      check sent[0].contains("luigi: I have a car")
      check sent[0].contains("mario")
      check sent[0].contains("got it right")
      check not cmd_quotes.game.active
    waitFor(runTest())
