import std/[unittest, asyncdispatch, strutils, tables, os, times, options]
import std/collections/sequtils

import ./utils
import ../src/kairosbot/commands/registry
import ../src/kairosbot/utils/chat_helpers
import ../commands/info/main as cmd_info

suite "InfoPlugin":

  test "formatUptime formats days/hours/minutes":
    let current = now().toTime()
    check formatUptime(current - minutes(5) - seconds(42)) == "5m 42s"
    check formatUptime(current - hours(2) - minutes(3)) == "2h 3m 0s"
    check formatUptime(current - days(1) - hours(1)) == "1d 1h 0m 0s"

  test "register registers the 4 commands + handlers":
    let ctx = makeMockContext("info", Port(18830), dir = "commands/info")
    cmd_info.register(ctx)
    let router = ctx.platform.router
    let all = router.registry.listAll()
    check all.len == 4
    for n in @["commands", "help", "uptime", "ping"]:
      check router.registry.get(n).isSome()
      check router.handlers.hasKey(n)

  test "formatCommandsText groups the commands by category":
    let ctx = makeMockContext("info", Port(18831), dir = "commands/info")
    cmd_info.register(ctx)
    let text = formatCommandsText(ctx.platform.router)
    check text.contains("Info:")
    check text.contains("!commands")
    check text.contains("!help")
    check text.contains("!uptime")
    check text.contains("!ping")
    # names only, no help text in the list
    check not text.contains("ping-pong")
    check not text.contains("grouped by category")

  test "formatCommandsText lists a new plugin category automatically":
    let ctx = makeMockContext("info", Port(18831), dir = "commands/info")
    cmd_info.register(ctx)
    let router = ctx.platform.router
    router.registry.register(Command(
      name: "rocket", helpText: "launch a rocket", category: "fun"))
    let text = formatCommandsText(router)
    check text.contains("Fun:")
    check text.contains("!rocket")
    # categories are sorted alphabetically: Fun before Info
    check text.find("Fun:") < text.find("Info:")

  test "formatCommandHelp includes cooldown and attempts if present":
    let plain = Command(name: "ping", helpText: "ping-pong")
    check formatCommandHelp(plain) == "ping: ping-pong"

    let full = Command(name: "slots", helpText: "play the slots",
      cooldown: 10.0, maxAttemptsPerDay: 5)
    let h = formatCommandHelp(full)
    check h.contains("slots: play the slots")
    check h.contains("cooldown: 10s")
    check h.contains("5 attempts/day")

  test "cmdCommands sends the command list in chat":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18832))

      let ctx = makeMockContext("info", Port(18832), dir = "commands/info")
      cmd_info.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("commands").get()
      await cmd_info.cmdCommands(mkMsg("!commands"), cmd, router)
      let sent = sentMessages()
      check sent.len == 1
      check sent[0].contains("here are all the commands")
      check sent[0].contains("Info:")
      check sent[0].contains("!ping")
      check not sent[0].contains("ping-pong")
      check not sent[0].contains("http")
    waitFor(runTest())

  test "cmdCommands splits a long list into messages under the limit":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 20, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18838))

      let ctx = makeMockContext("info", Port(18838), dir = "commands/info")
      cmd_info.register(ctx)
      let router = ctx.platform.router
      # register enough fake commands to overflow one message
      for i in 1 .. 80:
        router.registry.register(Command(
          name: "cmd" & $i, helpText: "help " & $i,
          category: "category" & $(i mod 3)))
      let cmd = router.registry.get("commands").get()
      await cmd_info.cmdCommands(mkMsg("!commands"), cmd, router)
      let sent = sentMessages()
      check sent.len > 1
      for m in sent:
        check m.len <= MaxMessageLength
      check sent[0].contains("here are all the commands")
      check sent.anyIt(it.contains("!cmd30"))
    waitFor(runTest())

  test "cmdHelp with a known command shows the help":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18833))

      let ctx = makeMockContext("info", Port(18833), dir = "commands/info")
      cmd_info.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("help").get()
      var msg = mkMsg("!help ping")
      msg.args = "ping"
      await cmd_info.cmdHelp(msg, cmd, router)
      check sentBodies()[0].contains("ping: ping-pong")
    waitFor(runTest())

  test "cmdHelp with an unknown command replies with an error":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18834))

      let ctx = makeMockContext("info", Port(18834), dir = "commands/info")
      cmd_info.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("help").get()
      var msg = mkMsg("!help inexistente")
      msg.args = "inexistente"
      await cmd_info.cmdHelp(msg, cmd, router)
      check sentBodies()[0].contains("unknown command")
    waitFor(runTest())

  test "cmdHelp with no arguments replies with the usage":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18835))

      let ctx = makeMockContext("info", Port(18835), dir = "commands/info")
      cmd_info.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("help").get()
      var msg = mkMsg("!help")
      msg.args = ""
      await cmd_info.cmdHelp(msg, cmd, router)
      check sentBodies()[0].contains("usage: !help")
    waitFor(runTest())

  test "cmdUptime reports the time online":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18836))

      let ctx = makeMockContext("info", Port(18836), dir = "commands/info")
      cmd_info.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("uptime").get()
      cmd_info.startTime = now().toTime() - minutes(3) - seconds(20)
      await cmd_info.cmdUptime(mkMsg("!uptime"), cmd, router)
      check sentBodies()[0].contains("3m 20s")
    waitFor(runTest())

  test "cmdPing replies with pong":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18837))

      let ctx = makeMockContext("info", Port(18837), dir = "commands/info")
      cmd_info.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("ping").get()
      await cmd_info.cmdPing(mkMsg("!ping"), cmd, router)
      check sentBodies()[0].contains("pong")
    waitFor(runTest())
