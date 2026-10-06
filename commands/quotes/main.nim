import std/[strutils, tables, os, math, asyncdispatch, options, json]

import kairosbot/plugin
import kairosbot/core/command_router
import kairosbot/commands/registry
import kairosbot/twitch/chat
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

proc windowSeconds(): int =
  ## Window length from the `window_seconds` param of !ding
  result = DefaultWindowSeconds
  let spec = specs.getOrDefault("ding", CommandSpec(name: "ding"))
  if spec.params.hasKey("window_seconds") and
      spec.params["window_seconds"].kind == JInt:
    let v = spec.params["window_seconds"].getInt
    if v > 0:
      result = v

# --- Publishing results ----------------------------------------------------------

proc isWinner(g: QuoteGame, user: string): bool =
  ## The user answered correctly
  let resp = g.responses.getOrDefault(user, "")
  result = g.isCorrect(resp)

proc collectResults(g: QuoteGame): (seq[(string, string)], seq[string]) =
  ## (list of username+completed phrase, list of winners)
  for user, resp in g.responses.pairs:
    result[0].add((user, g.complete(resp)))
    if g.isCorrect(resp):
      result[1].add(user)

proc publishResults*(router: CommandRouter, winnerVerb: string) {.async.} =
  ## Publishes the list of answers and announces the winners
  let (lines, winners) = collectResults(game)
  var text: string
  if lines.len == 0:
    text = "⏰ Time's up! Nobody answered."
  else:
    var body: seq[string] = @[]
    for (user, phrase) in lines:
      body.add(user & ": " & phrase)
    text = "⏰ Time's up! The answers:\n" & body.join("\n")
  text &= "\nThe answer was: \"" & game.answer & "\""
  if winners.len > 0:
    text &= "\n🏆 " & winners.join(", ") & " " & winnerVerb
  else:
    text &= "\nNobody got it right."
  game.reset()
  await safeSend(router.chat, text)

# --- Handlers ---------------------------------------------------------------------------

proc cmdDing*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !ding - starts a phrase with a blank and opens the 30s window
  let active = pluginCtx.activeWindow()
  if active.isSome:
    let (name, secs) = active.get()
    await safeSend(router.chat, msg.username &
      ", another event is running: " & name & " (" & $int(round(secs)) & "s left)")
    return
  let phrase = pickDingPhrase()
  if phrase.blank.len == 0:
    await safeSend(router.chat, "No phrases available right now.")
    return
  game.reset()
  game.active = true
  game.mode = qmDing
  game.displayText = phrase.blank
  game.answer = phrase.answer
  game.variants = phrase.variants

  let secs = windowSeconds()
  proc onExpire() {.async.} =
    await publishResults(router, "got it right!")
  if not pluginCtx.beginWindow(WindowName, secs, onExpire):
    game.reset()
    await safeSend(router.chat, msg.username & ", another event is running.")
    return
  await safeSend(router.chat, "🔔 " & msg.username & " started a ding! \"" &
    game.displayText & "\" Answer with !dong <word> (" & $secs & "s)")

proc cmdDong*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !dong <word> - records the answer (during the ding window)
  if not game.active or game.mode != qmDing:
    await safeSend(router.chat, msg.username & ", no ding is in progress")
    return
  let resp = msg.args.strip()
  if resp.len == 0:
    await safeSend(router.chat, msg.username & ", answer with !dong <word>")
    return
  game.responses[msg.username.toLowerAscii()] = resp
  await safeSend(router.chat, msg.username & ", got it: " & resp)

proc cmdRace*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !race [continuation] - starts the incomplete phrase or records the continuation
  let resp = msg.args.strip()
  if resp.len > 0:
    # records the continuation
    if not game.active or game.mode != qmRace:
      await safeSend(router.chat, msg.username & ", no race is in progress")
      return
    game.responses[msg.username.toLowerAscii()] = resp
    await safeSend(router.chat, msg.username & ", got it: " & resp)
    return

  # starts a new race
  let active = pluginCtx.activeWindow()
  if active.isSome:
    let (name, secs) = active.get()
    await safeSend(router.chat, msg.username &
      ", another event is running: " & name & " (" & $int(round(secs)) & "s left)")
    return
  let phrase = pickRacePhrase()
  if phrase.start.len == 0:
    await safeSend(router.chat, "No phrases available right now.")
    return
  game.reset()
  game.active = true
  game.mode = qmRace
  game.displayText = phrase.start
  game.answer = phrase.ending
  game.variants = phrase.variants

  let secs = windowSeconds()
  proc onExpire() {.async.} =
    await publishResults(router, "completed it!")
  if not pluginCtx.beginWindow(WindowName, secs, onExpire):
    game.reset()
    await safeSend(router.chat, msg.username & ", another event is running.")
    return
  await safeSend(router.chat, "🏁 " & msg.username & " started a race! \"" &
    game.displayText & "...\" Complete it with !race <your continuation> (" &
    $secs & "s)")

# --- Registration ------------------------------------------------------------------------

proc register*(ctx: PluginContext) =
  if not ctx.isEnabled():
    echo "[PLUGIN] quotes: disabled in config.json"
    return
  pluginCtx = ctx
  loadPhrases(ctx.dir / "phrases.json")
  var handlers: Table[string, CommandHandler]
  handlers["ding"] = cmdDing
  handlers["dong"] = cmdDong
  handlers["race"] = cmdRace
  specs = loadCommandSpecs(ctx.dir / "commands.json")
  registerCommands(ctx, specs, handlers)
