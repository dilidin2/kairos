import std/[tables, strutils, json, os]

import kairosbot/data/persistence
import kairosbot/utils/common

## State of the quotes game, shared by !ding and !race (same state,
## different modes). Lives in the plugin: only this plugin uses it.

type
  QuoteMode* = enum
    qmDing
    qmRace

  DingPhrase* = object
    blank*: string
    answer*: string
    variants*: seq[string]

  RacePhrase* = object
    start*: string
    ending*: string
    variants*: seq[string]

  QuoteGame* = ref object
    active*: bool
    mode*: QuoteMode
    displayText*: string
    ## !ding: template with the blank ("I have a ..."); !race: the start ("...")
    answer*: string
    ## expected word (!ding) or expected continuation (!race)
    variants*: seq[string]
    responses*: Table[string, string]
    ## username (lowercase) -> answer

proc newQuoteGame*(): QuoteGame =
  ## Creates the game state (inactive)
  result = QuoteGame(
    active: false,
    mode: qmDing,
    displayText: "",
    answer: "",
    variants: @[],
    responses: initTable[string, string]()
  )

proc reset*(g: QuoteGame) =
  ## Resets the state for a new game
  g.active = false
  g.mode = qmDing
  g.displayText = ""
  g.answer = ""
  g.variants = @[]
  g.responses = initTable[string, string]()

proc complete*(g: QuoteGame, resp: string): string =
  ## Phrase completed with the user's answer
  case g.mode
  of qmDing:
    result = g.displayText.replace("...", resp)
  of qmRace:
    result = g.displayText & " " & resp

# --- Loading phrases -------------------------------------------------------------

var
  dingPhrases: seq[DingPhrase]
  racePhrases: seq[RacePhrase]

proc loadPhrases*(path: string) =
  ## Loads phrases.json: lists of ding and race phrases. If missing/malformed,
  ## the lists stay empty (the commands reply "no phrases available").
  dingPhrases = @[]
  racePhrases = @[]
  if not fileExists(path):
    echo "[PLUGIN] quotes: phrases.json missing: ", path
    return
  let node = loadJson(path)
  if node.kind != JObject:
    echo "[PLUGIN] quotes: phrases.json malformed: ", path
    return
  if node.hasKey("ding") and node["ding"].kind == JArray:
    for item in node["ding"]:
      if item.kind != JObject:
        continue
      var p = DingPhrase()
      if item.hasKey("blank"):
        p.blank = item["blank"].getStr
      if item.hasKey("answer"):
        p.answer = item["answer"].getStr
      if item.hasKey("variants") and item["variants"].kind == JArray:
        for v in item["variants"]:
          p.variants.add(v.getStr)
      if p.blank.len > 0 and p.answer.len > 0:
        dingPhrases.add(p)
  if node.hasKey("race") and node["race"].kind == JArray:
    for item in node["race"]:
      if item.kind != JObject:
        continue
      var p = RacePhrase()
      if item.hasKey("start"):
        p.start = item["start"].getStr
      if item.hasKey("end"):
        p.ending = item["end"].getStr
      if item.hasKey("variants") and item["variants"].kind == JArray:
        for v in item["variants"]:
          p.variants.add(v.getStr)
      if p.start.len > 0 and p.ending.len > 0:
        racePhrases.add(p)

proc pickDingPhrase*(): DingPhrase =
  ## Random ding phrase (empty default if none available)
  if dingPhrases.len > 0:
    result = randElem(dingPhrases)

proc pickRacePhrase*(): RacePhrase =
  ## Random race phrase (empty default if none available)
  if racePhrases.len > 0:
    result = randElem(racePhrases)
