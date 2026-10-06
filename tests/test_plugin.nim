import std/[unittest, asyncdispatch, strutils, tables, json, os, options, times]
import std/collections/sequtils

import ./utils
import ../src/kairosbot/commands/registry
import ../src/kairosbot/core/command_router
import ../src/kairosbot/core/trophy_tracker
import ../src/kairosbot/core/window_guard
import ../src/kairosbot/plugin
import ../src/kairosbot/twitch/chat

suite "PluginContext":

  # --- WindowGuard -----------------------------------------------------------

  test "window guard: first window acquired, second rejected":
    let g = newWindowGuard()
    proc expire() {.async.} = discard
    check g.tryBegin("quotes", 30, expire)
    check g.isActive()
    check g.activeName == "quotes"
    check g.remaining() > 29.0
    # second window: immediate rejection
    check not g.tryBegin("quiz", 30, expire)
    g.release("quotes")
    check not g.isActive()
    # now it can be acquired again
    check g.tryBegin("quiz", 30, expire)
    g.stop()
    check not g.isActive()

  test "window guard: onExpire invoked on expiry, guard released":
    proc runTest() {.async.} =
      var expired = false
      proc onExpire() {.async.} =
        expired = true
      let g = newWindowGuard()
      check g.tryBegin("quotes", 1, onExpire)
      check not expired
      await sleepAsync(1300)
      check expired
      check not g.isActive()
    waitFor(runTest())

  test "window guard: early end does not invoke onExpire":
    proc runTest() {.async.} =
      var expired = false
      proc onExpire() {.async.} =
        expired = true
      let g = newWindowGuard()
      check g.tryBegin("quotes", 1, onExpire)
      g.release("quotes")
      await sleepAsync(1300)
      check not expired
    waitFor(runTest())

  test "beginWindow/endWindow/activeWindow via context":
    proc runTest() {.async.} =
      let ctx = makeMockContext("win", Port(18827))
      proc expire() {.async.} = discard
      check ctx.beginWindow("quotes", 30, expire)
      let opt = ctx.activeWindow()
      check opt.isSome()
      check opt.get()[0] == "quotes"
      check opt.get()[1] > 29.0
      check not ctx.beginWindow("quiz", 30, expire)
      ctx.endWindow("quotes")
      check ctx.activeWindow().isNone()
      await ctx.platform.stop()
    waitFor(runTest())

  # --- Timer -------------------------------------------------------------------

  test "every starts a periodic timer, stop stops it":
    proc runTest() {.async.} =
      let ctx = makeMockContext("timer", Port(18828))
      var ticks = 0
      proc tick() {.async.} =
        ticks += 1
      ctx.every(1, tick)
      check ticks == 0
      await sleepAsync(2300)
      check ticks >= 2
      await ctx.platform.stop()
      let before = ticks
      await sleepAsync(1200)
      check ticks == before
    waitFor(runTest())

  # --- send ---------------------------------------------------------------------

  test "send sends to chat via safeSend":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18829))
      let ctx = makeMockContext("send", Port(18829))
      await ctx.send("ciao mondo")
      let sent = sentBodies()
      check sent.len == 1
      check sent[0].contains("ciao mondo")
    waitFor(runTest())

  # --- botInfo --------------------------------------------------------------------

  test "botInfo returns the bot's identifying data":
    let ctx = makeMockContext("info", Port(18830))
    let bi = ctx.botInfo()
    check bi.botName == "kairosbot"
    check bi.broadcasterId == "111"
    check bi.botId == "777"
    check bi.channel == "canale"
    check ctx.statePath.endsWith("info.json")

  # --- loadCommandSpecs --------------------------------------------------------------

  test "loadCommandSpecs parses a complete spec (aliases, role, params)":
    let base = getTempDir() / "kairos_test_specs_1"
    createDir(base)
    let path = base / "commands.json"
    writeFile(path, """
      {"!flip": {
         "help": "Flip a coin",
         "cooldown": 10,
         "max_attempts_per_day": 0,
         "aliases": ["!f", "!münze"],
         "role": "mod",
         "extra": 42
      }}
    """)
    let specs = loadCommandSpecs(path)
    check specs.len == 1
    let s = specs["flip"]
    check s.help == "Flip a coin"
    check s.cooldown == 10.0
    check s.maxAttemptsPerDay == 0
    check s.aliases == @["f", "münze"]
    check s.role == crMod
    check s.params["extra"].getInt == 42

  test "loadCommandSpecs: missing file -> empty table":
    check loadCommandSpecs("/non/esistente/commands.json").len == 0

  test "loadTrophyTexts loads names, messages and templates":
    let base = getTempDir() / "kairos_test_trophy_texts"
    createDir(base)
    let path = base / "trophies.json"
    writeFile(path, "{\"unlock\": \"T {name}!\", \"bw\": {\"name\": \"BW\", \"message\": \"M {user}\"}}")
    let texts = loadTrophyTexts(path)
    check texts.len == 2
    check texts["unlock"].message.contains("{name}")
    check texts["bw"].name == "BW"
    check loadTrophyTexts("/non/esistente/trophies.json").len == 0

  test "trophyText falls back to the defaults":
    var texts = initTable[string, TrophyText]()
    let t = trophyText(texts, "x", "DefName", "DefMsg")
    check t.name == "DefName" and t.message == "DefMsg"

  test "loadTrophyRules parses the trophies param (defaults and validation)":
    var spec = CommandSpec(name: "slots")
    check loadTrophyRules(spec).len == 0  # no param
    spec.params["trophies"] = %*[
      {"name": "Gambler", "event": "win", "threshold": 1,
       "description": "First win", "type": "total"},
      {"name": "Streak", "event": "win", "threshold": 3,
       "description": "3 in a row", "type": "streak"},
      {"name": "", "event": "win", "threshold": 1},          # invalid: no name
      {"name": "NoEvent", "threshold": 1}                    # invalid: no event
    ]
    let rules = loadTrophyRules(spec)
    check rules.len == 2
    check rules[0].name == "Gambler"
    check rules[0].ruleType == trtTotal
    check rules[1].ruleType == trtStreak

  test "loadCommandSpecs: missing fields -> defaults":
    let base = getTempDir() / "kairos_test_specs_2"
    createDir(base)
    let path = base / "commands.json"
    writeFile(path, """{"!x": {}}""")
    let specs = loadCommandSpecs(path)
    check specs["x"].help == ""
    check specs["x"].cooldown == 0.0
    check specs["x"].maxAttemptsPerDay == 0
    check specs["x"].role == crEveryone

  # --- registerCommands -----------------------------------------------------------------

  test "registerCommands: handler without a JSON entry -> default + registered":
    let ctx = makeMockContext("reg1", Port(18831))
    proc handler(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} = discard
    var handlers: Table[string, CommandHandler]
    handlers["orphan"] = handler
    registerCommands(ctx, initTable[string, CommandSpec](), handlers)
    let router = ctx.platform.router
    check router.registry.get("orphan").isSome()
    check router.registry.get("orphan").get().helpText == ""
    check router.handlers.hasKey("orphan")

  test "registerCommands: JSON entry without a handler -> skipped":
    let ctx = makeMockContext("reg2", Port(18832))
    var specs = initTable[string, CommandSpec]()
    specs["ghost"] = CommandSpec(name: "ghost", help: "h")
    registerCommands(ctx, specs, initTable[string, CommandHandler]())
    let router = ctx.platform.router
    check router.registry.get("ghost").isNone()
    check not router.handlers.hasKey("ghost")

  test "registerCommand exposes aliases and role in the registry":
    let ctx = makeMockContext("reg3", Port(18833))
    proc handler(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} = discard
    let spec = CommandSpec(name: "roast", aliases: @["röst"], role: crMod)
    ctx.registerCommand(spec, handler)
    let router = ctx.platform.router
    check router.registry.get("roast").isSome()
    check router.registry.get("röst").isSome()
    check router.registry.get("RÖST").get().name == "roast"
    check router.registry.get("roast").get().role == crMod

  # --- subscribers (onMessage) -----------------------------------------------------------

  test "onMessage: the plugin receives every message, bot messages not":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18834))
      let ctx = makeMockContext("sub", Port(18834))
      var seen: seq[string] = @[]
      proc handler(msg: ChatMessage) {.async.} =
        seen.add(msg.username)
      ctx.onMessage(handler)
      let router = ctx.platform.router
      await router.process(mkMsg("ciao", username = "mario"))
      await router.process(mkMsg("ciao", username = "pippo"))
      await router.process(mkMsg("ciao", username = "mario", isBot = true))
      await sleepAsync(100)  # the subscribers run via asyncCheck
      check seen == @["mario", "pippo"]
    waitFor(runTest())

  # --- router: role check ------------------------------------------------------------------

  test "router blocks a role=mod command for non-mods":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18835))
      let ctx = makeMockContext("role", Port(18835))
      var called = false
      proc handler(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
        called = true
      ctx.registerCommand(CommandSpec(name: "vanish", role: crMod), handler)
      let router = ctx.platform.router
      # regular user
      await router.process(mkMsg("!vanish", username = "mario"))
      check not called
      check sentBodies().anyIt(it.contains("moderator role"))
      # mod: passes
      await router.process(mkMsg("!vanish", username = "mario",
        badges = @["moderator"]))
      check called
    waitFor(runTest())

  test "router blocks a role=broadcaster command for non-broadcasters":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18836))
      let ctx = makeMockContext("role2", Port(18836))
      var called = false
      proc handler(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
        called = true
      ctx.registerCommand(CommandSpec(name: "clear", role: crBroadcaster), handler)
      let router = ctx.platform.router
      await router.process(mkMsg("!clear", username = "mario",
        badges = @["moderator"]))
      check not called
      check sentBodies().anyIt(it.contains("only the broadcaster"))
      await router.process(mkMsg("!clear", username = "mario",
        badges = @["broadcaster"]))
      check called
    waitFor(runTest())

  # --- alias nel router ---------------------------------------------------------------------

  test "router: the alias resolves to the canonical command":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18837))
      let ctx = makeMockContext("alias", Port(18837))
      var gotArgs = ""
      proc handler(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
        gotArgs = msg.args
      ctx.registerCommand(CommandSpec(name: "roast", aliases: @["röst"]), handler)
      let router = ctx.platform.router
      await router.process(mkMsg("!röst mario"))
      check gotArgs == "mario"
    waitFor(runTest())
