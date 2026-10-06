import std/[unittest, asyncdispatch, strutils, tables, json, os, options]

import ./utils
import ../src/kairosbot/commands/registry
import ../src/kairosbot/config/config
import ../src/kairosbot/twitch/auth
import ../src/kairosbot/twitch/chat
import ../src/kairosbot/twitch/helix
import ../src/kairosbot/plugin
import ../commands/vanish/main as cmd_vanish
import ../commands/vanish/message_log as ml

suite "MessageLog":

  test "add e messagesOf":
    let log = ml.newMessageLog()
    log.add("Mario", "id1")
    log.add("mario", "id2")
    log.add("Luigi", "id3")
    check log.messagesOf("mario") == seq[string](@["id1", "id2"])
    check log.messagesOf("luigi") == seq[string](@["id3"])
    check log.messagesOf("peppe").len == 0
    check log.total == 3

  test "per-user cap: discards the oldest":
    let log = ml.newMessageLog(perUserCap = 3, globalCap = 100)
    for i in 1 .. 5:
      log.add("mario", "id" & $i)
    check log.messagesOf("mario") == @["id3", "id4", "id5"]

  test "global cap: discards the oldest":
    let log = ml.newMessageLog(perUserCap = 100, globalCap = 3)
    log.add("mario", "a")
    log.add("mario", "b")
    log.add("luigi", "c")
    log.add("luigi", "d")  # exceeds the global cap: discards "a"
    check log.total <= 3
    check "a" notin log.messagesOf("mario")
    check "d" in log.messagesOf("luigi")

  test "clearUser e reset":
    let log = ml.newMessageLog()
    log.add("mario", "id1")
    log.add("mario", "id2")
    log.clearUser("mario")
    check log.messagesOf("mario").len == 0
    log.add("luigi", "id3")
    log.reset()
    check log.messagesOf("luigi").len == 0
    check log.total == 0

  test "add ignores the empty id":
    let log = ml.newMessageLog()
    log.add("mario", "")
    check log.messagesOf("mario").len == 0
    check log.total == 0

suite "parseChatMessage":

  test "extracts message_id from the event":
    let chat = newTwitchChat("111", "777",
      TokenSet(accessToken: "t", refreshToken: "r", expiresAt: 0, scope: @[],
               userLogin: "bot", userId: "777"),
      BotConfig(), tkBot)
    let event = parseJson("""
      {
        "chatter_user_login": "mario",
        "message": {"text": "ciao"},
        "broadcaster_user_login": "canale",
        "badges": {},
        "message_id": "abc123"
      }
    """)
    let msg = chat.parseChatMessage(event)
    check msg.username == "mario"
    check msg.content == "ciao"
    check msg.messageId == "abc123"

suite "VanishPlugin":

  test "register registers the command":
    let ctx = makeMockContext("vanish", Port(18920), dir = "commands/vanish")
    cmd_vanish.register(ctx)
    let router = ctx.platform.router
    check router.registry.get("vanish").get().cooldown == 60.0
    check router.handlers.hasKey("vanish")

  test "cmdVanish without the mod scope is inactive":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18921))
      let ctx = makeMockContext("vanish", Port(18921), dir = "commands/vanish")
      cmd_vanish.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("vanish").get()
      # no mod scope in the token
      await cmd_vanish.cmdVanish(mkMsg("!vanish"), cmd, router)
      let sent = sentMessages()
      check sent[0].contains("I need to be a moderator")
    waitFor(runTest())

  test "cmdVanish by the broadcaster is rejected":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18922))
      let ctx = makeMockContext("vanish", Port(18922), dir = "commands/vanish")
      cmd_vanish.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("vanish").get()
      # add the mod scope
      ctx.platform.router.chat.token.scope.add("moderator:manage:chat_messages")
      # the broadcaster is "canale"
      var msg = mkMsg("!vanish", username = "canale")
      await cmd_vanish.cmdVanish(msg, cmd, router)
      let sent = sentMessages()
      check sent[0].contains("I can't make the broadcaster vanish")
    waitFor(runTest())

  test "cmdVanish with the mod scope deletes the messages":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      # mock DELETE /moderation/chat -> 204
      mockAdd("/helix/moderation/chat", 204, "", 5)
      await startMockHttp(Port(18923))
      let ctx = makeMockContext("vanish", Port(18923), dir = "commands/vanish")
      cmd_vanish.register(ctx)
      let router = ctx.platform.router
      let cmd = router.registry.get("vanish").get()
      ctx.platform.router.chat.token.scope.add("moderator:manage:chat_messages")
      # simulate 2 messages from mario in the session
      cmd_vanish.log.add("mario", "id1")
      cmd_vanish.log.add("mario", "id2")

      await cmd_vanish.cmdVanish(mkMsg("!vanish"), cmd, router)

      # 2 DELETE requests made
      var deletes = 0
      for r in mockRequests:
        if r[0] == "DELETE /helix/moderation/chat":
          deletes += 1
      check deletes == 2
      # log cleaned
      check cmd_vanish.log.messagesOf("mario").len == 0
      # response in chat
      let sent = sentMessages()
      check sent[0].contains("i see your secret")
    waitFor(runTest())
