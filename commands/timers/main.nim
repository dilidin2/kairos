import std/[strutils, os, json, asyncdispatch]

import kairosbot/plugin
import kairosbot/data/persistence
import kairosbot/utils/common

type
  TimerState = object
    messages*: seq[string]
    shuffle*: bool
    idx*: int
    ## Next message index when shuffle is off

proc pickMessage(t: var TimerState): string =
  ## Random message (shuffle on) or next in order (shuffle off)
  if t.shuffle or t.messages.len == 1:
    result = randElem(t.messages)
  else:
    result = t.messages[t.idx]
    t.idx = (t.idx + 1) mod t.messages.len

proc register*(ctx: PluginContext) =
  let path = ctx.dir / "config.json"
  if not fileExists(path):
    echo "[PLUGIN] timers: missing config.json: ", path
    return
  let node = loadJson(path)
  if node.kind != JObject:
    echo "[PLUGIN] timers: malformed config.json: ", path
    return
  let enabled =
    if node.hasKey("enabled") and node["enabled"].kind == JBool:
      node["enabled"].getBool
    else:
      true
  if not enabled:
    echo "[PLUGIN] timers: disabled"
    return

  let timers =
    if node.hasKey("timers") and node["timers"].kind == JObject:
      node["timers"]
    else:
      echo "[PLUGIN] timers: no timers configured"
      return

  for name, t in timers.pairs:
    if t.kind != JObject:
      echo "[PLUGIN] timers: timer ", name, " is not an object (skipped)"
      continue
    let intervalMin =
      if t.hasKey("interval_minutes") and t["interval_minutes"].kind == JInt and
          t["interval_minutes"].getInt > 0:
        t["interval_minutes"].getInt
      else:
        echo "[PLUGIN] timers: timer ", name,
             " has no valid interval_minutes (skipped)"
        continue
    var messages: seq[string]
    if t.hasKey("messages") and t["messages"].kind == JArray:
      for m in t["messages"]:
        if m.kind == JString:
          let text = m.getStr.strip
          if text.len > 0:
            messages.add(text)
    if messages.len == 0:
      echo "[PLUGIN] timers: timer ", name, " has no valid messages (skipped)"
      continue
    let shuffle =
      if t.hasKey("shuffle_messages") and t["shuffle_messages"].kind == JBool:
        t["shuffle_messages"].getBool
      else:
        true

    var state = TimerState(messages: messages, shuffle: shuffle)
    ctx.every(intervalMin * 60, proc () {.async.} =
      await ctx.send(pickMessage(state))
    )
    echo "[PLUGIN] timers: timer '", name, "' active (every ", $intervalMin, " min)"
