import std/[tables, json, os]

import ./persistence

## Translatable text catalog of a plugin (its messages.json).
## Same concept as the core messages (config/messages.json), but each
## plugin owns its own file: flat key -> message template with
## {placeholder}s, always with an English fallback in the code.

type
  MsgTexts* = Table[string, string]
  ## Translatable user-facing chat texts (key -> template)

proc loadMsgTexts*(path: string): MsgTexts =
  ## Loads messages.json: flat key -> template pairs. Missing or
  ## malformed file -> empty catalog (the caller falls back to the
  ## English defaults)
  result = initTable[string, string]()
  if not fileExists(path):
    return
  let node = loadJson(path)
  if node.kind != JObject:
    return
  for key, value in node.pairs:
    if value.kind == JString:
      result[key] = value.getStr

proc msgText*(texts: MsgTexts, key, fallback: string): string =
  ## A user-facing message template with the English fallback
  result = texts.getOrDefault(key, fallback)
