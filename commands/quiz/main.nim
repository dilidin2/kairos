import std/[strutils, tables, os, math, asyncdispatch, options, json]

import kairosbot/plugin
import kairosbot/core/command_router
import kairosbot/core/trophy_tracker
import kairosbot/commands/registry
import kairosbot/twitch/chat
import kairosbot/utils/chat_helpers
import ./quiz

const
  DefaultWindowSeconds = 30
  WindowName = "quiz"

var
  pluginCtx*: PluginContext
  ## Plugin context: the handlers use it for the channel window
  quizState*: QuizState = newQuizState()
  ## State of the active quiz
  specs*: Table[string, CommandSpec]
  ## Metadata read from commands.json in register()

proc windowSeconds(): int =
  ## Window length from the `window_seconds` param of !quiz
  result = DefaultWindowSeconds
  let spec = specs.getOrDefault("quiz", CommandSpec(name: "quiz"))
  if spec.params.hasKey("window_seconds") and
      spec.params["window_seconds"].kind == JInt:
    let v = spec.params["window_seconds"].getInt
    if v > 0:
      result = v

proc cmdQuiz*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !quiz [answer] - starts a question or attempts an answer
  let resp = msg.args.strip()
  if resp.len > 0:
    # attempts the answer
    if not quizState.active:
      await safeSend(router.chat, msg.username & ", no quiz is in progress")
      return
    if quizState.winner.len > 0:
      await safeSend(router.chat, msg.username & ", the quiz is already won")
      return
    if quizState.isCorrect(resp):
      quizState.winner = msg.username
      # trophy: quiz won (total)
      discard router.trophyTracker.recordEvent(msg.username, "quiz", "win")
      # early release of the window
      pluginCtx.endWindow(WindowName)
      quizState.active = false
      await safeSend(router.chat, "🎉 " & msg.username & " won the quiz! The answer was: \"" &
        quizState.answer & "\"")
    else:
      await safeSend(router.chat, msg.username & ", nope, try again!")
    return

  # starts a new question
  let active = pluginCtx.activeWindow()
  if active.isSome:
    let (name, secs) = active.get()
    if name == WindowName:
      await safeSend(router.chat, msg.username & ", quiz in progress, " &
        $int(round(secs)) & "s left, answer!")
    else:
      await safeSend(router.chat, msg.username &
        ", another event is running: " & name & " (" & $int(round(secs)) & "s left)")
    return
  let q = pickQuestion()
  if q.question.len == 0:
    await safeSend(router.chat, "No questions available right now.")
    return
  quizState.active = true
  quizState.category = q.category
  quizState.question = q.question
  quizState.answer = q.answer
  quizState.variants = q.variants
  quizState.winner = ""

  let secs = windowSeconds()
  proc onExpire() {.async.} =
    # no winner: reveals the answer
    if quizState.active:
      await safeSend(router.chat, "⏰ Time's up! The answer was: \"" &
        quizState.answer & "\"")
      quizState.active = false
  if not pluginCtx.beginWindow(WindowName, secs, onExpire):
    quizState.active = false
    return
  await safeSend(router.chat, "🧠 " & msg.username & " started a quiz! [" &
    quizState.category & "] " & quizState.question &
    " Answer with !quiz <answer> (" & $secs & "s)")

# --- Registration ------------------------------------------------------------------------

proc register*(ctx: PluginContext) =
  if not ctx.isEnabled():
    echo "[PLUGIN] quiz: disabled in config.json"
    return
  pluginCtx = ctx
  loadQuestions(ctx.dir / "questions.json")
  var handlers: Table[string, CommandHandler]
  handlers["quiz"] = cmdQuiz
  specs = loadCommandSpecs(ctx.dir / "commands.json")
  registerCommands(ctx, specs, handlers)
  # trophy: quiz won (from commands.json, built-in default as fallback)
  let trophies = ctx.platform.trophyTracker
  let fromJson = loadTrophyRules(specs.getOrDefault("quiz", CommandSpec(name: "quiz")))
  trophies.addRules("quiz",
    if fromJson.len > 0: fromJson
    else: @[
      TrophyRule(
        name: "Quiz Wizard",
        eventType: "win",
        threshold: 1,
        description: "Won a quiz",
        ruleType: trtTotal
      )
    ])
