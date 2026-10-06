import std/[json, os, random]

## Simple quests (fallback): defined in simple_quests.jsonc (translatable
## texts, fixed behaviour). Used only if llm_active is false
## or if the LLM fails. Weighted selection (weight) + cyclic
## (excludes the last 5 given, anti-spam).

type
  SimpleQuest* = object
    id*: string
    text*: string
    requiredText*: string
    requiredCount*: int
    duration*: int            ## minutes
    trophy*: string
    trophyResponse*: string
    weight*: int

proc stripJsonComments*(text: string): string =
  ## Removes // and /* */ comments while respecting string literals
  result = ""
  var i = 0
  var inString, escape = false
  while i < text.len:
    let c = text[i]
    if inString:
      result.add(c)
      if escape:
        escape = false
      elif c == '\\':
        escape = true
      elif c == '"':
        inString = false
      i += 1
    elif c == '"' :
      inString = true
      result.add(c)
      i += 1
    elif c == '/' and i + 1 < text.len and text[i+1] == '/':
      while i < text.len and text[i] != '\n':
        i += 1
    elif c == '/' and i + 1 < text.len and text[i+1] == '*':
      i += 2
      while i + 1 < text.len and not (text[i] == '*' and text[i+1] == '/'):
        i += 1
      i += 2
    else:
      result.add(c)
      i += 1

proc loadSimpleQuests*(path: string): seq[SimpleQuest] =
  ## Parses simple_quests.jsonc (no crash: malformed file → empty list)
  result = @[]
  if not fileExists(path):
    echo "[PLUGIN] quests: simple_quests.jsonc missing: ", path
    return
  let clean = stripJsonComments(readFile(path))
  var node: JsonNode
  try:
    node = parseJson(clean)
  except CatchableError as e:
    echo "[PLUGIN] quests: simple_quests.jsonc malformed: ", e.msg
    return
  if node.kind != JArray:
    echo "[PLUGIN] quests: simple_quests.jsonc is not a list"
    return
  for item in node:
    if item.kind != JObject:
      continue
    var sq: SimpleQuest
    if item.hasKey("id"): sq.id = item["id"].getStr
    if item.hasKey("text"): sq.text = item["text"].getStr
    if item.hasKey("required_text"): sq.requiredText = item["required_text"].getStr
    if item.hasKey("required_count"): sq.requiredCount = item["required_count"].getInt
    if item.hasKey("duration"): sq.duration = item["duration"].getInt
    if item.hasKey("trophy"): sq.trophy = item["trophy"].getStr
    if item.hasKey("trophy_response"): sq.trophyResponse = item["trophy_response"].getStr
    if item.hasKey("weight"): sq.weight = item["weight"].getInt
    else: sq.weight = 1
    if sq.id.len > 0 and sq.text.len > 0 and sq.duration > 0 and sq.requiredCount > 0:
      result.add(sq)

proc pickSimpleQuest*(quests: seq[SimpleQuest], recent: seq[string]): SimpleQuest =
  ## Weighted by weight, cyclic: excludes the last N given (recent).
  ## If all are recent, it takes the whole list back.
  var candidates: seq[SimpleQuest] = @[]
  for sq in quests:
    if sq.id notin recent:
      candidates.add(sq)
  if candidates.len == 0:
    candidates = quests
  if candidates.len == 0:
    return
  var total = 0
  for sq in candidates:
    total += sq.weight
  var r = rand(max(0, total - 1))
  for sq in candidates:
    r -= sq.weight
    if r < 0:
      result = sq
      break
