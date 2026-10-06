import std/[unittest, asyncdispatch, strutils, tables, json, os, options]

import ./utils
import ../src/kairosbot/commands/registry
import ../src/kairosbot/core/trophy_tracker
import ../src/kairosbot/plugin
import ../commands/fun/main as cmd_fun

suite "FunPlugin":

  test "loadContent loads the 4 lists from content.json":
    cmd_fun.loadContent("commands/fun/content.json")
    for key in @["roasts", "jokes", "truths", "dares"]:
      check cmd_fun.content.hasKey(key)
      check cmd_fun.content[key].len >= 5

  test "loadContent with a missing file leaves the lists empty":
    cmd_fun.loadContent("/non/esiste/content.json")
    check cmd_fun.content.getOrDefault("roasts", @[]).len == 0

  test "pick returns an element of the list, '' if empty":
    cmd_fun.loadContent("commands/fun/content.json")
    for i in 1 .. 20:
      let r = cmd_fun.pick("roasts")
      check r.len > 0
      check r in cmd_fun.content["roasts"]
    cmd_fun.content["vuota"] = @[]
    check cmd_fun.pick("vuota") == ""

  test "createRoastRules e createJokeRules":
    let roastRules = cmd_fun.createRoastRules()
    check roastRules.len == 2
    check roastRules[0].name == "Hot Sauce"
    check roastRules[0].eventType == "roast"
    check roastRules[0].ruleType == trtTotal

    let jokeRules = cmd_fun.createJokeRules()
    check jokeRules.len == 2
    check jokeRules[0].name == "Class Clown"
    check jokeRules[0].eventType == "joke"

  test "register registers the 4 commands, aliases and trophy rules":
    let ctx = makeMockContext("fun", Port(18860), dir = "commands/fun")
    cmd_fun.register(ctx)
    let router = ctx.platform.router
    let roast = router.registry.get("roast").get()
    check roast.cooldown == 5.0
    check roast.maxAttemptsPerDay == 0
    check "röst" in roast.aliases
    check router.registry.get("joke").get().helpText.len > 0
    check router.registry.get("truth").get().helpText.len > 0
    check router.registry.get("dare").get().helpText.len > 0
    check router.handlers.hasKey("roast")
    check router.handlers.hasKey("joke")
    check router.handlers.hasKey("truth")
    check router.handlers.hasKey("dare")
    check router.trophyTracker.rules.hasKey("roast")
    check router.trophyTracker.rules.hasKey("joke")

  test "cmdRoast with no arguments roasts the requester":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18861))

      let ctx = makeMockContext("fun", Port(18861), dir = "commands/fun")
      cmd_fun.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("roast").get()
      await cmd_fun.cmdRoast(mkMsg("!roast"), cmd, router)
      let sent = sentMessages()
      check sent.len == 2  # roast + trophy notification "Hot Sauce"
      check sent[0].startsWith("mario, ")
      check sent[1].contains("Hot Sauce")
      let trophies = router.trophyTracker.getUserTrophies("mario")
      check trophies.len == 1
      check trophies[0].name == "Hot Sauce"
    waitFor(runTest())

  test "cmdRoast with a user roasts the mentioned user":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18862))

      let ctx = makeMockContext("fun", Port(18862), dir = "commands/fun")
      cmd_fun.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("roast").get()
      var msg = mkMsg("!roast luigi")
      msg.args = "luigi"
      await cmd_fun.cmdRoast(msg, cmd, router)
      let sent = sentMessages()
      check sent[0].startsWith("luigi, ")
    waitFor(runTest())

  test "cmdJoke sends a joke and records the trophy":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18863))

      let ctx = makeMockContext("fun", Port(18863), dir = "commands/fun")
      cmd_fun.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("joke").get()
      await cmd_fun.cmdJoke(mkMsg("!joke"), cmd, router)
      let sent = sentMessages()
      check sent.len == 2  # joke + trophy notification "Class Clown"
      check sent[0].startsWith("mario, ")
      check sent[1].contains("Class Clown")
    waitFor(runTest())

  test "cmdTruth and cmdDare answer the user":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 10, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18864))

      let ctx = makeMockContext("fun", Port(18864), dir = "commands/fun")
      cmd_fun.register(ctx)
      let router = ctx.platform.router
      let truth = router.registry.get("truth").get()
      let dare = router.registry.get("dare").get()
      await cmd_fun.cmdTruth(mkMsg("!truth"), truth, router)
      await cmd_fun.cmdDare(mkMsg("!dare"), dare, router)
      let sent = sentMessages()
      check sent.len == 2
      check sent[0].startsWith("mario, ")
      check sent[1].startsWith("mario, your dare: ")
    waitFor(runTest())
