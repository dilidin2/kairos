import std/[unittest, asyncdispatch, strutils, tables, json, os, options, times]
import std/collections/sequtils

import ./utils
import ../src/kairosbot/commands/registry
import ../src/kairosbot/core/trophy_tracker
import ../commands/trophies/main as cmd_trophies

suite "TrophiesPlugin":

  proc mkTrophy(name, command: string): Trophy =
    Trophy(name: name, command: command, unlockedAt: "2026-10-04T12:00:00")

  test "groupTrophiesByCommand groups by command":
    let trophies = @[
      mkTrophy("Gambler", "slots"),
      mkTrophy("Wisdom", "8ball"),
      mkTrophy("Trifecta", "slots"),
    ]
    let grouped = cmd_trophies.groupTrophiesByCommand(trophies)
    check grouped.len == 2
    check grouped["slots"].len == 2
    check grouped["8ball"].len == 1
    check grouped["slots"][0].name == "Gambler"

  test "groupTrophiesByCommand with an empty list":
    check cmd_trophies.groupTrophiesByCommand(@[]).len == 0

  test "formatTrophies generates a header per command and trophy lines":
    let trophies = @[
      mkTrophy("Gambler", "slots"),
      mkTrophy("Wisdom", "8ball"),
      mkTrophy("Trifecta", "slots"),
    ]
    let lines = cmd_trophies.formatTrophies(trophies)
    check lines.len == 5
    check lines.anyIt(it == "📦 slots:")
    check lines.anyIt(it == "📦 8ball:")
    check lines.anyIt(it == "  🏆 Gambler")
    check lines.anyIt(it == "  🏆 Trifecta")
    check lines.anyIt(it == "  🏆 Wisdom")

  test "formatTrophies with an empty list":
    check cmd_trophies.formatTrophies(@[]).len == 0

  test "register registers !trophy + handler":
    let ctx = makeMockContext("trophies", Port(18850), dir = "commands/trophies")
    cmd_trophies.register(ctx)
    let router = ctx.platform.router
    let trophy = router.registry.get("trophy")
    check trophy.isSome()
    check trophy.get().helpText.len > 0
    check router.handlers.hasKey("trophy")

  test "cmdTrophy with no arguments shows one's own trophies":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18851))

      let ctx = makeMockContext("trophies", Port(18851))
      cmd_trophies.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("trophy").get()
      router.trophyTracker.trophies["mario"] = @[
        mkTrophy("Gambler", "slots"),
        mkTrophy("Wisdom", "8ball"),
      ]
      var msg = mkMsg("!trophy")
      msg.args = ""
      await cmd_trophies.cmdTrophy(msg, cmd, router)
      let sent = sentBodies()
      check sent.len == 1
      check sent[0].contains("Trophies of mario")
      check sent[0].contains("📦 slots:")
      check sent[0].contains("📦 8ball:")
      check sent[0].contains("Gambler")
      check sent[0].contains("Wisdom")
    waitFor(runTest())

  test "cmdTrophy with an explicit user":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18852))

      let ctx = makeMockContext("trophies", Port(18852))
      cmd_trophies.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("trophy").get()
      router.trophyTracker.trophies["pippo"] = @[
        mkTrophy("Trifecta", "slots"),
      ]
      var msg = mkMsg("!trophy pippo")
      msg.args = "pippo"
      await cmd_trophies.cmdTrophy(msg, cmd, router)
      check sentBodies()[0].contains("Trophies of pippo")
      check sentBodies()[0].contains("Trifecta")
    waitFor(runTest())

  test "cmdTrophy for a user without trophies":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18853))

      let ctx = makeMockContext("trophies", Port(18853))
      cmd_trophies.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("trophy").get()
      var msg = mkMsg("!trophy nessuno")
      msg.args = "nessuno"
      await cmd_trophies.cmdTrophy(msg, cmd, router)
      check sentBodies()[0].contains("nessuno")
      check sentBodies()[0].contains("has no trophies yet")
    waitFor(runTest())
