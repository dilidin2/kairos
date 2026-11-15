import std/[unittest, asyncdispatch, strutils, os, options]
import std/collections/sequtils

import ./utils
import ../src/kairosbot/plugin
import ../commands/timers/main as cmd_timers

suite "TimersPlugin":

  test "makeHandler: each handler owns its own persistent state (closure fix)":
    ## Regression test: before the fix every closure captured the LAST `state`
    ## of the loop, so all timers shared one state and only one timer's
    ## messages ever appeared.
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 8, 200,
        """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18900))
      let ctx = makeMockContext("timers", Port(18900))
      let h1 = cmd_timers.makeHandler(
        ctx, cmd_timers.TimerState(messages: @["A1", "A2"], shuffle: false))
      let h2 = cmd_timers.makeHandler(
        ctx, cmd_timers.TimerState(messages: @["B1", "B2"], shuffle: false))
      await h1()
      await h2()
      await h1()
      await h2()
      let sent = sentMessages()
      # each handler advanced its own index: A1,B1,A2,B2 (not a shared list)
      check sent == @["A1", "B1", "A2", "B2"]
      await ctx.platform.stop()
    waitFor(runTest())

  test "makeHandler: two handlers do not interfere across firings":
    ## With a single shared state (the old bug) the second handler would keep
    ## the first handler's index; here both start at index 0 and wrap
    ## independently.
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 8, 200,
        """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18901))
      let ctx = makeMockContext("timers", Port(18901))
      let h1 = cmd_timers.makeHandler(
        ctx, cmd_timers.TimerState(messages: @["X1", "X2"], shuffle: false))
      let h2 = cmd_timers.makeHandler(
        ctx, cmd_timers.TimerState(messages: @["Y1", "Y2"], shuffle: false))
      # fire h1 twice, then h2 twice: h2 must still start from Y1
      await h1()
      await h1()
      await h2()
      await h2()
      let sent = sentMessages()
      check sent == @["X1", "X2", "Y1", "Y2"]
      await ctx.platform.stop()
    waitFor(runTest())

  test "register: one timer per configured name":
    proc runTest() {.async.} =
      let base = getTempDir() / "kairos_test_timers_reg"
      createDir(base)
      writeFile(base / "config.json", """
        {"enabled": true, "timers": {
          "pausa": {"interval_minutes": 1, "messages": ["P"], "shuffle_messages": false},
          "robe":  {"interval_minutes": 1, "messages": ["R"], "shuffle_messages": false}
        }}
      """)
      let ctx = makeMockContext("timers", Port(18902), dir = base)
      cmd_timers.register(ctx)
      check ctx.platform.timers.len == 2
      await ctx.platform.stop()
    waitFor(runTest())

  test "register: skips timers without a valid interval or messages":
    proc runTest() {.async.} =
      let base = getTempDir() / "kairos_test_timers_reg2"
      createDir(base)
      writeFile(base / "config.json", """
        {"enabled": true, "timers": {
          "no_interval": {"messages": ["A"]},
          "no_messages": {"interval_minutes": 5},
          "ok":          {"interval_minutes": 5, "messages": ["B"]}
        }}
      """)
      let ctx = makeMockContext("timers", Port(18903), dir = base)
      cmd_timers.register(ctx)
      check ctx.platform.timers.len == 1
      await ctx.platform.stop()
    waitFor(runTest())