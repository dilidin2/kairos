import std/[strutils, tables, os, math, asyncdispatch, options]

import kairosbot/plugin
import kairosbot/core/command_router
import kairosbot/commands/registry
import kairosbot/data/messages
import kairosbot/twitch/chat
import kairosbot/utils/answers
import kairosbot/utils/chat_helpers
import ./quote_game

const
  DefaultWindowSeconds = 30
  WindowName = "quotes"

var
  pluginCtx*: PluginContext
  ## Plugin context: the handlers use it for the channel window
  game*: QuoteGame = newQuoteGame()
  ## Shared state of !ding and !race
  specs*: Table[string, CommandSpec]
  ## Metadata read from commands.json in register()
  msgTexts*: MsgTexts
  ## Translatable user-facing chat texts from messages.json

proc windowSeconds(): int =
  ## Window length from the `window_seconds` param of !ding
  let spec = specs.getOrDefault("ding", CommandSpec(name: "ding"))
  result = specIntParam(spec, "window_seconds", DefaultWindowSeconds, 1)

# --- Publishing results ----------------------------------------------------------

proc isWinner(g: QuoteGame, user: string): bool =
  ## The user answered correctly
  let resp = g.responses.getOrDefault(user, "")
  result = answerMatches(g.answer, g.variants, resp)

proc collectResults(g: QuoteGame): (seq[(string, string)], seq[string]) =
  ## (list of username+completed phrase, list of winners)
  for user, resp in g.responses.pairs:
    result[0].add((user, g.complete(resp)))
    if answerMatches(g.answer, g.variants, resp):
      result[1].add(user)

proc publishResults*(router: CommandRouter, winnerVerb: string) {.async.} =
  ## Publishes the list of answers and announces the winners
  let (lines, winners) = collectResults(game)
  var text: string
  if lines.len == 0:
    text = msgText(msgTexts, "time_up_no_answers", "⏰ Time's up! Nobody answered.")
  else:
    var body: seq[string] = @[]
    for (user, phrase) in lines:
      body.add(user & ": " & phrase)
    text = msgText(msgTexts, "time_up_answers", "⏰ Time's up! The answers:\n{lines}")
      .replace("{lines}", body.join("\n"))
  text &= "\n" & msgText(msgTexts, "answer_was", "The answer was: \"{answer}\"")
      .replace("{answer}", game.answer)
  if winners.len > 0:
    text &= "\n" & msgText(msgTexts, "winners_line", "🏆 {winners} {verb}")
        .replace("{winners}", winners.join(", "))
        .replace("{verb}", winnerVerb)
  else:
    text &= "\n" & msgText(msgTexts, "nobody_right", "Nobody got it right.")
  game.reset()
  await safeSend(router.chat, text)

# --- Handlers ---------------------------------------------------------------------------

proc cmdDing*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !ding - starts a phrase with a blank and opens the 30s window
  let active = pluginCtx.activeWindow()
  if active.isSome:
    let (name, secs) = active.get()
    await safeSend(router.chat,
      msgText(msgTexts, "other_event",
            "{user}, another event is running: {name} ({secs}s left)")
        .replace("{user}", msg.username)
        .replace("{name}", name)
        .replace("{secs}", $int(round(secs))))
    return
  let phrase = pickDingPhrase()
  if phrase.blank.len == 0:
    await safeSend(router.chat, msgText(msgTexts, "no_phrases",
      "No phrases available right now."))
    return
  game.reset()
  game.active = true
  game.mode = qmDing
  game.displayText = phrase.blank
  game.answer = phrase.answer
  game.variants = phrase.variants

  let secs = windowSeconds()
  proc onExpire() {.async.} =
    await publishResults(router, msgText(msgTexts, "ding_won", "got it right!"))
  if not pluginCtx.beginWindow(WindowName, secs, onExpire):
    game.reset()
    await safeSend(router.chat,
      msgText(msgTexts, "other_event_short",
            "{user}, another event is running.").replace("{user}", msg.username))
    return
  await safeSend(router.chat,
    msgText(msgTexts, "ding_started",
          "🔔 {user} started a ding! \"{text}\" Answer with !dong <word> ({secs}s)")
        .replace("{user}", msg.username)
        .replace("{text}", game.displayText)
        .replace("{secs}", $secs))

proc cmdDong*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !dong <word> - records the answer (during the ding window)
  if not game.active or game.mode != qmDing:
    await safeSend(router.chat,
      msgText(msgTexts, "no_ding", "{user}, no ding is in progress")
        .replace("{user}", msg.username))
    return
  let resp = msg.args.strip()
  if resp.len == 0:
    await safeSend(router.chat,
      msgText(msgTexts, "dong_usage", "{user}, answer with !dong <word>")
        .replace("{user}", msg.username))
    return
  game.responses[msg.username.toLowerAscii()] = resp
  await safeSend(router.chat,
    msgText(msgTexts, "got_it", "{user}, got it: {resp}")
      .replace("{user}", msg.username)
      .replace("{resp}", resp))

proc cmdRace*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !race [continuation] - starts the incomplete phrase or records the continuation
  let resp = msg.args.strip()
  if resp.len > 0:
    # records the continuation
    if not game.active or game.mode != qmRace:
      await safeSend(router.chat,
        msgText(msgTexts, "no_race", "{user}, no race is in progress")
          .replace("{user}", msg.username))
      return
    game.responses[msg.username.toLowerAscii()] = resp
    await safeSend(router.chat,
      msgText(msgTexts, "got_it", "{user}, got it: {resp}")
        .replace("{user}", msg.username)
        .replace("{resp}", resp))
    return

  # starts a new race
  let active = pluginCtx.activeWindow()
  if active.isSome:
    let (name, secs) = active.get()
    await safeSend(router.chat,
      msgText(msgTexts, "other_event",
            "{user}, another event is running: {name} ({secs}s left)")
        .replace("{user}", msg.username)
        .replace("{name}", name)
        .replace("{secs}", $int(round(secs))))
    return
  let phrase = pickRacePhrase()
  if phrase.start.len == 0:
    await safeSend(router.chat, msgText(msgTexts, "no_phrases",
      "No phrases available right now."))
    return
  game.reset()
  game.active = true
  game.mode = qmRace
  game.displayText = phrase.start
  game.answer = phrase.ending
  game.variants = phrase.variants

  let secs = windowSeconds()
  proc onExpire() {.async.} =
    await publishResults(router, msgText(msgTexts, "race_won", "completed it!"))
  if not pluginCtx.beginWindow(WindowName, secs, onExpire):
    game.reset()
    await safeSend(router.chat,
      msgText(msgTexts, "other_event_short",
            "{user}, another event is running.").replace("{user}", msg.username))
    return
  await safeSend(router.chat,
    msgText(msgTexts, "race_started",
          "🏁 {user} started a race! \"{text}...\" " &
          "Complete it with !race <your continuation> ({secs}s)")
        .replace("{user}", msg.username)
        .replace("{text}", game.displayText)
        .replace("{secs}", $secs))

# --- Registration ------------------------------------------------------------------------

proc register*(ctx: PluginContext) =
  if not ctx.isEnabled():
    echo "[PLUGIN] quotes: disabled in config.json"
    return
  pluginCtx = ctx
  loadPhrases(ctx.dir / "phrases.json")
  msgTexts = loadMsgTexts(ctx.dir / "messages.json")
  var handlers: Table[string, CommandHandler]
  handlers["ding"] = cmdDing
  handlers["dong"] = cmdDong
  handlers["race"] = cmdRace
  specs = loadCommandSpecs(ctx.dir / "commands.json")
  registerCommands(ctx, specs, handlers)
