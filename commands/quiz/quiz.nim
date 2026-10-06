import std/[strutils, json, os, random]

import kairosbot/data/persistence

## State of the timed trivia quiz. Lives in the plugin: only this plugin uses it.

type
  Question* = object
    category*: string
    question*: string
    answer*: string
    variants*: seq[string]

  QuizState* = ref object
    active*: bool
    category*: string
    question*: string
    answer*: string
    variants*: seq[string]
    winner*: string
    ## username of the winner (empty until someone wins)

proc newQuizState*(): QuizState =
  ## Creates the quiz state (inactive)
  result = QuizState(
    active: false,
    category: "",
    question: "",
    answer: "",
    variants: @[],
    winner: ""
  )

proc reset*(s: QuizState) =
  ## Resets the state for a new question
  s.active = false
  s.category = ""
  s.question = ""
  s.answer = ""
  s.variants = @[]
  s.winner = ""

proc norm*(s: string): string =
  ## Normalizes an answer: lowercase, trim, multiple spaces collapsed
  result = s.toLowerAscii().strip()
  while "  " in result:
    result = result.replace("  ", " ")

proc isCorrect*(s: QuizState, resp: string): bool =
  ## The (normalized) answer matches the correct answer or a variant
  let n = norm(resp)
  result = (n == norm(s.answer))
  if result:
    return
  for v in s.variants:
    if n == norm(v):
      result = true
      return

# --- Loading questions -------------------------------------------------------------

var
  questions: seq[Question]

proc loadQuestions*(path: string) =
  ## Loads questions.json: a list of questions. If missing/malformed, the list
  ## stays empty (the command replies "no questions available").
  questions = @[]
  if not fileExists(path):
    echo "[PLUGIN] quiz: questions.json missing: ", path
    return
  let node = loadJson(path)
  if node.kind != JArray:
    echo "[PLUGIN] quiz: questions.json malformed: ", path
    return
  for item in node:
    if item.kind != JObject:
      continue
    var q = Question()
    if item.hasKey("category"):
      q.category = item["category"].getStr
    if item.hasKey("question"):
      q.question = item["question"].getStr
    if item.hasKey("answer"):
      q.answer = item["answer"].getStr
    if item.hasKey("variants") and item["variants"].kind == JArray:
      for v in item["variants"]:
        q.variants.add(v.getStr)
    if q.question.len > 0 and q.answer.len > 0:
      questions.add(q)

proc pickQuestion*(): Question =
  ## Random question (empty default if none available)
  if questions.len > 0:
    result = questions[rand(questions.len - 1)]
