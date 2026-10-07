import std/[strutils, tables, os, math, asyncdispatch, options, json]

import kairosbot/plugin
import kairosbot/core/command_router
import kairosbot/core/trophy_tracker
import kairosbot/data/persistence
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
  msgTexts*: Table[string, string]
  ## Translatable user-facing chat texts from messages.json

# --- Texts --------------------------------------------------------------------

proc loadMsgs(path: string): Table[string, string] =
  ## Loads messages.json: flat key -> template pairs
  result = initTable[string, string]()
  if not fileExists(path):
    return
  let node = loadJson(path)
  if node.kind != JObject:
    return
  for key, value in node.pairs:
    if value.kind == JString:
      result[key] = value.getStr

proc mtext(key, fallback: string): string =
  ## A user-facing message template (messages.json) with English fallback
  if msgTexts.hasKey(key):
    result = msgTexts[key]
  else:
    result = fallback

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
      await safeSend(router.chat,
        mtext("no_quiz", "{user}, no quiz is in progress")
          .replace("{user}", msg.username))
      return
    if quizState.winner.len > 0:
      await safeSend(router.chat,
        mtext("already_won", "{user}, the quiz is already won")
          .replace("{user}", msg.username))
      return
    if quizState.isCorrect(resp):
      quizState.winner = msg.username
      # trophy: quiz won (total)
      discard router.trophyTracker.recordEvent(msg.username, "quiz", "win")
      # early release of the window
      pluginCtx.endWindow(WindowName)
      quizState.active = false
      await safeSend(router.chat,
        mtext("won", "🎉 {user} won the quiz! The answer was: \"{answer}\"")
          .replace("{user}", msg.username)
          .replace("{answer}", quizState.answer))
    else:
      await safeSend(router.chat,
        mtext("wrong_answer", "{user}, nope, try again!")
          .replace("{user}", msg.username))
    return

  # starts a new question
  let active = pluginCtx.activeWindow()
  if active.isSome:
    let (name, secs) = active.get()
    if name == WindowName:
      await safeSend(router.chat,
        mtext("in_progress", "{user}, quiz in progress, {secs}s left, answer!")
          .replace("{user}", msg.username)
          .replace("{secs}", $int(round(secs))))
    else:
      await safeSend(router.chat,
        mtext("other_event",
              "{user}, another event is running: {name} ({secs}s left)")
          .replace("{user}", msg.username)
          .replace("{name}", name)
          .replace("{secs}", $int(round(secs))))
    return
  let q = pickQuestion()
  if q.question.len == 0:
    await safeSend(router.chat, mtext("no_questions",
      "No questions available right now."))
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
      await safeSend(router.chat,
        mtext("time_up", "⏰ Time's up! The answer was: \"{answer}\"")
          .replace("{answer}", quizState.answer))
      quizState.active = false
  if not pluginCtx.beginWindow(WindowName, secs, onExpire):
    quizState.active = false
    return
  await safeSend(router.chat,
    mtext("started",
          "🧠 {user} started a quiz! [{category}] {question} " &
          "Answer with !quiz <answer> ({secs}s)")
        .replace("{user}", msg.username)
        .replace("{category}", quizState.category)
        .replace("{question}", quizState.question)
        .replace("{secs}", $secs))

# --- Registration ------------------------------------------------------------------------

proc register*(ctx: PluginContext) =
  if not ctx.isEnabled():
    echo "[PLUGIN] quiz: disabled in config.json"
    return
  pluginCtx = ctx
  loadQuestions(ctx.dir / "questions.json")
  msgTexts = loadMsgs(ctx.dir / "messages.json")
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
