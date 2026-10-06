import std/[strutils, random, asyncdispatch, tables, json, os, times, parseutils]

import kairosbot/plugin
import kairosbot/core/command_router
import kairosbot/commands/registry
import kairosbot/core/trophy_tracker
import kairosbot/core/attempt_tracker
import kairosbot/core/economy
import kairosbot/twitch/chat
import kairosbot/utils/chat_helpers

const
  DefaultWinProbability* = 0.15
  DefaultSlotSymbols* = @[
    "🍒", "🍋", "🍊", "💎", "7️⃣", "🔔", "⭐", "🍀"
  ]
  DefaultFlipOutcomes* = ("Heads", "Tails")
  Default8ballResponses* = @[
    "It is certain.",
    "Without a doubt.",
    "It is decided, but wait a little longer.",
    "The signs say yes, for now.",
    "Don't count on it.",
    "Better not tell you now.",
    "My sources say no.",
    "Outlook not so good.",
    "Absolutely not.",
    "Very doubtful.",
    "You'll know soon enough.",
    "Ask again later.",
  ]

type
  SlotCombo* = object
    symbols*: seq[string]
    multiplier*: int

  SlotResult* = object
    symbols*: seq[string]
    isWin*: bool
    winCombo*: string

var
  defaultSlotCombos: seq[SlotCombo] = @[
    SlotCombo(symbols: @["🍒", "🍒", "🍒"], multiplier: 2),
    SlotCombo(symbols: @["💎", "💎", "💎"], multiplier: 5),
    SlotCombo(symbols: @["7️⃣", "7️⃣", "7️⃣"], multiplier: 10),
    SlotCombo(symbols: @["🔔", "🔔", "🔔"], multiplier: 8),
    SlotCombo(symbols: @["🍀", "🍀", "🍀"], multiplier: 15),
  ]

var
  specs*: Table[string, CommandSpec]
  ## Metadata read from commands.json in register(): the handlers
  ## read the extra parameters (e.g. win_probability) from here
  econ*: EconomyService
  ## Economy service (exposed by the economy plugin): used by !bet
  trophyTexts*: Table[string, TrophyText]
  ## Translatable one-off trophy texts from trophies.json

# --- Slot machine ------------------------------------------------------------------

proc slotsSpec(): CommandSpec =
  ## The !slots spec from commands.json (empty default if not loaded)
  result = specs.getOrDefault("slots", CommandSpec(name: "slots"))

proc paramStrSeq(spec: CommandSpec, key: string): seq[string] =
  ## The string list from a spec param (empty if missing/malformed)
  if spec.params.hasKey(key) and spec.params[key].kind == JArray:
    for s in spec.params[key]:
      if s.kind == JString and s.getStr.len > 0:
        result.add(s.getStr)

proc getSlotSymbols*(): seq[string] =
  ## Available symbols from the `slot_symbols` param. Each symbol is a
  ## whole string: some emoji (e.g. 7️⃣) are multi-codepoint, so
  ## comparisons are always whole-string against whole-string, never
  ## char/Rune.
  let syms = paramStrSeq(slotsSpec(), "slot_symbols")
  result = if syms.len > 0: syms else: DefaultSlotSymbols

proc getSlotCombos*(): seq[SlotCombo] =
  ## Winning combos with multipliers from the `slot_combos` param
  let node = slotsSpec().params.getOrDefault("slot_combos", nil)
  if node.isNil or node.kind != JArray:
    return defaultSlotCombos
  var combos: seq[SlotCombo] = @[]
  for item in node:
    if item.kind != JObject:
      continue
    var c: SlotCombo
    if item.hasKey("combo") and item["combo"].kind == JArray:
      for s in item["combo"]:
        if s.kind == JString:
          c.symbols.add(s.getStr)
    if item.hasKey("multiplier") and item["multiplier"].kind == JInt:
      c.multiplier = item["multiplier"].getInt
    if c.symbols.len > 0 and c.multiplier > 0:
      combos.add(c)
  result = if combos.len > 0: combos else: defaultSlotCombos

proc getWinningCombos*(): seq[seq[string]] =
  ## List of the winning combos
  for c in getSlotCombos():
    result.add(c.symbols)

proc generateWinningCombo*(): seq[string] =
  ## Generates a random winning combo
  let combos = getWinningCombos()
  result = combos[rand(combos.len - 1)]

proc generateLosingCombo*(): seq[string] =
  ## Generates a losing combo: by construction it does not match any
  ## winning combo (element-by-element comparison on whole strings)
  var combo: seq[string]
  let combos = getWinningCombos()
  let symbols = getSlotSymbols()
  while true:
    combo = @[]
    for i in 0 .. 2:
      combo.add(symbols[rand(symbols.len - 1)])
    if not combos.contains(combo):
      break
  result = combo

proc generateSlotResult*(winProbability: float): SlotResult =
  ## Generates the slot result: winning with the given probability,
  ## losing (never a winning combo) otherwise
  if rand(1.0) < winProbability:
    let combo = generateWinningCombo()
    result = SlotResult(symbols: combo, isWin: true, winCombo: combo.join(" "))
  else:
    let combo = generateLosingCombo()
    result = SlotResult(symbols: combo, isWin: false, winCombo: "")

proc formatSlotResult*(res: SlotResult, betOn: string): string =
  ## Formats the slot result for the chat
  let line = res.symbols.join(" ")
  var text: string
  if res.isWin:
    text = "🎉 " & line & " 🎉 WIN!"
    if betOn.len > 0 and res.symbols.contains(betOn):
      text &= " You even guessed the " & betOn & "!"
  else:
    if betOn.len > 0:
      text = "Bet on " & betOn & ": " & line & " — nope, try again!"
    else:
      text = line & " — nope, try again!"
  result = text

# --- Palla magica --------------------------------------------------------------------

proc get8ballResponse*(): string =
  ## Returns a random magic 8-ball response (from the `responses` param)
  let spec = specs.getOrDefault("8ball", CommandSpec(name: "8ball"))
  let resp = paramStrSeq(spec, "responses")
  let list = if resp.len > 0: resp else: Default8ballResponses
  result = list[rand(list.len - 1)]

proc getFlipOutcomes*(): (string, string) =
  ## (heads, tails) from the `flip_outcomes` param of !flip
  let spec = specs.getOrDefault("flip", CommandSpec(name: "flip"))
  let opts = paramStrSeq(spec, "flip_outcomes")
  if opts.len == 2:
    result = (opts[0], opts[1])
  else:
    result = DefaultFlipOutcomes

# --- Parameters -----------------------------------------------------------------------

proc getWinProbability*(spec: CommandSpec): float =
  ## Win probability from the params of commands.json (default 0.15)
  result = DefaultWinProbability
  if spec.params.hasKey("win_probability"):
    let n = spec.params["win_probability"]
    if n.kind == JInt or n.kind == JFloat:
      result = n.getFloat

# --- Trofei --------------------------------------------------------------------------

proc createSlotsRules*(): seq[TrophyRule] =
  ## Trophy rules for !slots
  result = @[
    TrophyRule(name: "Gambler", eventType: "win", threshold: 1,
      description: "First slot machine win", ruleType: trtTotal),
    TrophyRule(name: "Trifecta", eventType: "win", threshold: 3,
      description: "3 slot machine wins", ruleType: trtTotal),
    TrophyRule(name: "Golden Streak", eventType: "win", threshold: 3,
      description: "3 slot machine wins in a row", ruleType: trtStreak),
  ]

proc createFlipRules*(): seq[TrophyRule] =
  ## Trophy rules for !flip
  result = @[
    TrophyRule(name: "Coin Flipper", eventType: "flip", threshold: 1,
      description: "First coin flip", ruleType: trtTotal),
    TrophyRule(name: "Lucky Streak", eventType: "win", threshold: 3,
      description: "3 coin flip wins in a row", ruleType: trtStreak),
  ]

proc create8ballRules*(): seq[TrophyRule] =
  ## Trophy rules for !8ball
  result = @[
    TrophyRule(name: "Wisdom", eventType: "ask", threshold: 1,
      description: "First question to the magic 8-ball", ruleType: trtTotal),
    TrophyRule(name: "Philosopher", eventType: "ask", threshold: 10,
      description: "10 questions to the magic 8-ball", ruleType: trtTotal),
  ]

# --- Handlers ---------------------------------------------------------------------------

proc sendTrophyNotifs(chat: TwitchChat, username: string,
                      trophies: seq[Trophy]) {.async.} =
  let tpl = trophyText(trophyTexts, "unlock", "",
    "🏆 {user} unlocked the trophy \"{name}\"!")
  for t in trophies:
    let msg = tpl.message.replace("{user}", username).replace("{name}", t.name)
    await safeSend(chat, msg)

proc cmd8ball*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !8ball - magic answer to the user's question
  let resp = get8ballResponse()
  let trophies = router.trophyTracker.recordEvent(msg.username, "8ball", "ask")
  await safeSend(router.chat, msg.username & ", " & resp)
  await sendTrophyNotifs(router.chat, msg.username, trophies)

proc cmdSlots*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !slots [symbol] - slot machine with a win probability
  let betOn = msg.args.strip()
  let spec = specs.getOrDefault("slots", CommandSpec(name: "slots"))
  let prob = getWinProbability(spec)
  let result = generateSlotResult(prob)
  let event = if result.isWin: "win" else: "loss"
  let trophies = router.trophyTracker.recordEvent(msg.username, "slots", event)
  await safeSend(router.chat, msg.username & ", " & formatSlotResult(result, betOn))
  await sendTrophyNotifs(router.chat, msg.username, trophies)

# --- Moneta ------------------------------------------------------------------------

proc cmdFlip*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !flip [heads|tails] - coin flip; with an argument it is a 50/50 bet
  let arg = msg.args.strip().toLowerAscii()
  let (heads, tails) = getFlipOutcomes()
  let outcome = if rand(2) == 0: heads else: tails
  let bet = arg
  var trophies = router.trophyTracker.recordEvent(msg.username, "flip", "flip")
  var text: string
  if bet == heads.toLowerAscii() or bet == tails.toLowerAscii():
    let won = (bet == outcome.toLowerAscii())
    trophies.add(router.trophyTracker.recordEvent(
      msg.username, "flip", if won: "win" else: "loss"))
    let verdict = if won: "You bet " & bet & " — WIN! 🎉"
                  else: "You bet " & bet & " — lose."
    text = outcome & "! " & verdict
  else:
    text = outcome & "!"
  await safeSend(router.chat, msg.username & ", " & text)
  await sendTrophyNotifs(router.chat, msg.username, trophies)

# --- Bet (economy) -----------------------------------------------------------------

proc slotMultiplier*(combo: seq[string]): int =
  ## Win multiplier for a winning combo (from `slot_combos`)
  for c in getSlotCombos():
    if c.symbols == combo:
      return c.multiplier
  result = 1

proc cmdBet*(msg: ChatMessage, cmd: Command, router: CommandRouter) {.async.} =
  ## !bet <amount> <flip|slots> - bet coins on a game of chance
  if econ.isNil:
    await safeSend(router.chat, msg.username & ", the economy is not available")
    return
  let parts = msg.args.strip().splitWhitespace()
  if parts.len != 2:
    await safeSend(router.chat, msg.username & ", usage: !bet <amount> <flip|slots>")
    return
  var amount = 0
  if parseInt(parts[0], amount) == 0 or amount < econ.minBet:
    await safeSend(router.chat, msg.username & ", enter a valid amount (min " &
      $econ.minBet & ")")
    return
  let game = parts[1].toLowerAscii()
  if game != "flip" and game != "slots":
    await safeSend(router.chat, msg.username & ", bet on flip or slots")
    return
  if not econ.canAfford(msg.username, amount):
    let bal = econ.getBalance(msg.username)
    await safeSend(router.chat, msg.username & ", you only have " & $bal & " 🪙")
    return

  var payout = 0
  var gameText: string
  if game == "flip":
    let (heads, tails) = getFlipOutcomes()
    let outcome = if rand(2) == 0: heads else: tails
    let won = rand(2) == 0
    if won: payout = amount * 2
    let verdict = if won: "You win " & $amount & " 🪙! 🎉"
                 else: "You lose " & $amount & " 🪙."
    gameText = outcome & "! " & verdict
  else:
    let spec = specs.getOrDefault("slots", CommandSpec(name: "slots"))
    let prob = getWinProbability(spec)
    let result = generateSlotResult(prob)
    if result.isWin:
      payout = amount * slotMultiplier(result.symbols)
    let verdict = if result.isWin: "You win " & $payout & " 🪙! 🎉"
                 else: "You lose " & $amount & " 🪙."
    gameText = formatSlotResult(result, "") & " " & verdict

  discard econ.applyWager(msg.username, amount, payout)
  # the slots bet also consumes the daily attempt
  if game == "slots":
    router.attemptTracker.useAttempt(msg.username, "slots")

  await safeSend(router.chat, msg.username & ", " & gameText)
  # "Big Winner" trophy for the largest single win
  if payout >= econ.bigWinner:
    let bw = trophyText(trophyTexts, "big_winner", "Big Winner",
      "🏆 {user} unlocked the trophy \"{name}\"!")
    let isNew = router.trophyTracker.awardTrophy(msg.username,
      Trophy(name: bw.name, command: "economy",
             unlockedAt: toIsoString(now().toTime())))
    if isNew:
      let msg = bw.message.replace("{user}", msg.username)
        .replace("{name}", bw.name)
      await safeSend(router.chat, msg)

# --- Registration ------------------------------------------------------------------------

proc register*(ctx: PluginContext) =
  if not ctx.isEnabled():
    echo "[PLUGIN] games: disabled in config.json"
    return
  specs = loadCommandSpecs(ctx.dir / "commands.json")
  trophyTexts = loadTrophyTexts(ctx.dir / "trophies.json")
  econ = cast[EconomyService](ctx.platform.services.getOrDefault("economy", nil))
  var handlers: Table[string, CommandHandler]
  handlers["8ball"] = cmd8ball
  handlers["slots"] = cmdSlots
  handlers["flip"] = cmdFlip
  handlers["bet"] = cmdBet
  registerCommands(ctx, specs, handlers)
  # trophy rules from commands.json, built-in defaults as fallback
  let ballRules = loadTrophyRules(specs.getOrDefault("8ball", CommandSpec(name: "8ball")))
  ctx.trophyRules("8ball", if ballRules.len > 0: ballRules else: create8ballRules())
  let slotsRules = loadTrophyRules(specs.getOrDefault("slots", CommandSpec(name: "slots")))
  ctx.trophyRules("slots", if slotsRules.len > 0: slotsRules else: createSlotsRules())
  let flipRules = loadTrophyRules(specs.getOrDefault("flip", CommandSpec(name: "flip")))
  ctx.trophyRules("flip", if flipRules.len > 0: flipRules else: createFlipRules())
