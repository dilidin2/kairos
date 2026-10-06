import std/[unittest, asyncdispatch, strutils, tables, json, os, options, sequtils]

import ./utils
import ../src/kairosbot/commands/registry
import ../src/kairosbot/core/window_guard
import ../src/kairosbot/core/trophy_tracker
import ../src/kairosbot/plugin
import ../commands/quiz/main as cmd_quiz
import ../commands/quiz/quiz as qz

suite "QuizState":

  test "loadQuestions loads the questions":
    qz.loadQuestions("commands/quiz/questions.json")
    let q = qz.pickQuestion()
    check q.question.len > 0
    check q.answer.len > 0
    check q.category.len > 0

  test "norm normalizes lowercase/trim/spaces":
    check qz.norm("  Canberra  ") == "canberra"
    check qz.norm("A  B") == "a b"

  test "isCorrect: exact match, variant and mismatch":
    let s = qz.newQuizState()
    s.answer = "Nile"
    s.variants = @["Nilo"]
    check s.isCorrect("Nile")
    check s.isCorrect("  nile  ")
    check s.isCorrect("Nilo")
    check not s.isCorrect("Tiger")

suite "QuizPlugin":

  test "register registers the command and the trophy rule":
    let ctx = makeMockContext("quiz", Port(18890), dir = "commands/quiz")
    cmd_quiz.register(ctx)
    let router = ctx.platform.router
    check router.registry.get("quiz").get().cooldown == 2.0
    check router.handlers.hasKey("quiz")
    check ctx.platform.trophyTracker.rules.hasKey("quiz")

  test "cmdQuiz starts a question and opens the window":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18891))

      let ctx = makeMockContext("quiz", Port(18891), dir = "commands/quiz")
      cmd_quiz.register(ctx)
      cmd_quiz.quizState.reset()
      let router = ctx.platform.router
      let cmd = router.registry.get("quiz").get()
      await cmd_quiz.cmdQuiz(mkMsg("!quiz"), cmd, router)

      check ctx.platform.windowGuard.isActive()
      check ctx.platform.windowGuard.activeName == "quiz"
      check cmd_quiz.quizState.active
      check cmd_quiz.quizState.question.len > 0
      check cmd_quiz.quizState.winner.len == 0
      let sent = sentMessages()
      check sent[0].contains("!quiz")
    waitFor(runTest())

  test "cmdQuiz <answer> correct wins and releases the window":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 10, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18892))

      let ctx = makeMockContext("quiz", Port(18892), dir = "commands/quiz")
      cmd_quiz.register(ctx)
      cmd_quiz.quizState.reset()
      let router = ctx.platform.router
      let cmd = router.registry.get("quiz").get()
      # quiz state with a known answer
      cmd_quiz.quizState.active = true
      cmd_quiz.quizState.question = "Capital of Australia?"
      cmd_quiz.quizState.answer = "Canberra"
      cmd_quiz.quizState.winner = ""

      var msg = mkMsg("!quiz Canberra")
      msg.args = "Canberra"
      await cmd_quiz.cmdQuiz(msg, cmd, router)

      check cmd_quiz.quizState.winner == "mario"
      check not cmd_quiz.quizState.active
      # window released
      check not ctx.platform.windowGuard.isActive()
      # trophy assigned
      let trophies = router.trophyTracker.getUserTrophies("mario")
      check trophies.anyIt(it.name == "Quiz Wizard" and it.command == "quiz")
      let sent = sentMessages()
      check sent[0].contains("mario")
      check sent[0].contains("won the quiz")
    waitFor(runTest())

  test "cmdQuiz <answer> wrong does not win":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 10, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18893))

      let ctx = makeMockContext("quiz", Port(18893), dir = "commands/quiz")
      cmd_quiz.register(ctx)
      cmd_quiz.quizState.reset()
      let router = ctx.platform.router
      let cmd = router.registry.get("quiz").get()
      cmd_quiz.quizState.active = true
      cmd_quiz.quizState.question = "Capital of Australia?"
      cmd_quiz.quizState.answer = "Canberra"
      cmd_quiz.quizState.winner = ""

      var msg = mkMsg("!quiz Paris")
      msg.args = "Paris"
      await cmd_quiz.cmdQuiz(msg, cmd, router)

      check cmd_quiz.quizState.winner.len == 0
      check cmd_quiz.quizState.active
      let sent = sentMessages()
      check sent[0].contains("nope, try again")
    waitFor(runTest())

  test "cmdQuiz <answer> with no active quiz replies with an error":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18894))

      let ctx = makeMockContext("quiz", Port(18894), dir = "commands/quiz")
      cmd_quiz.register(ctx)
      cmd_quiz.quizState.reset()
      let router = ctx.platform.router
      let cmd = router.registry.get("quiz").get()
      var msg = mkMsg("!quiz Paris")
      msg.args = "Paris"
      await cmd_quiz.cmdQuiz(msg, cmd, router)
      let sent = sentMessages()
      check sent[0].contains("no quiz is in progress")
    waitFor(runTest())

  test "cmdQuiz during its own ongoing quiz warns the others":
    proc runTest() {.async.} =
      mockMany("/helix/chat/messages", 5, 200, """{"data":[{"message_id":"abc","is_sent":true,"drop_reason":null}]}""")
      await startMockHttp(Port(18895))

      let ctx = makeMockContext("quiz", Port(18895), dir = "commands/quiz")
      cmd_quiz.register(ctx)
      cmd_quiz.quizState.reset()
      let router = ctx.platform.router
      let cmd = router.registry.get("quiz").get()
      # first quiz
      await cmd_quiz.cmdQuiz(mkMsg("!quiz"), cmd, router)
      # second quiz: in progress
      await cmd_quiz.cmdQuiz(mkMsg("!quiz"), cmd, router)
      let sent = sentMessages()
      check sent[1].contains("quiz in progress")
    waitFor(runTest())
