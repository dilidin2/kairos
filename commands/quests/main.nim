import std/[strutils, tables, json, random, options, times, asyncdispatch, os, logging, sequtils]

import kairosbot/plugin
import kairosbot/config/config
import kairosbot/commands/registry
import kairosbot/core/command_router
import kairosbot/core/llm
import kairosbot/core/peerbus
import kairosbot/core/trophy_tracker
import kairosbot/twitch/chat
import kairosbot/data/persistence

import simpleQuests

## Quest system.
##
## Users enter the pool with !adventure (OP IN). Every
## `periodic_quest_call` minutes the LLM picks a quest and the users from
## the pool and announces the quest in character. Completion is verified
## periodically with a yes/no precheck; on expiry the "defeated" message
## goes out, followed by the separate failure message from config.json.
## The simple quests (simple_quests.jsonc) are the fallback
## when the LLM is inactive or fails.
##
## All internal prompts are in English; `bot_language` (global config)
## controls the language of the generated text.

const
  DefaultInactiveMinutes = 10
  ## users inactive longer than this leave the pool
  DefaultMaxPickAttempts = 3
  ## LLM attempts to pick a valid quest
  DefaultCheckTickMs = 15_000
  ## quest check loop period
  DefaultQuestFailedMsgSingle = "You have failed the quest!"
  DefaultQuestFailedMsgMulti = "You have failed the quest!"
  ## separate messages sent when a quest times out (translatable,
  ## quest_failed_message_single / quest_failed_message_multi in
  ## config.json)

type
  QuestDefinition* = object
    id*: string
    systemPrompt*: string
    objective*: string
    completedWhen*: string
    requiredUsers*: int
    duration*: int            ## minutes
    trophy*: string
    trophyResponse*: string

  ActiveQuest* = object
    instanceId*: string
    defId*: string
    isLlm*: bool
    users*: seq[string]
    startedAt*: Time
    durationMin*: int
    systemPrompt*: string
    objective*: string
    completedWhen*: string
    requiredText*: string
    requiredCount*: int
    progress*: int
    transcript*: seq[string]
    hintUsed*: bool
    lastCheckAt*: Time
    trophy*: string
    trophyResponse*: string

  QuestData* = object
    completedCount*: Table[string, int]
    recentSimple*: seq[string]
    lastQuestDefId*: string
    ## id of the last LLM quest picked: excluded from the pool of the
    ## next pick (persisted in data/quests.json)

  QuestState* = ref object
    cfg*: BotConfig
    channel*: string
    inactiveMin*: int
    maxPickAttempts*: int
    checkTickMs*: int
    questFailedMsgSingle*: string
    questFailedMsgMulti*: string
    definitions*: Table[string, QuestDefinition]
    simpleQuests*: seq[SimpleQuest]
    pool*: seq[string]
    active*: Table[string, ActiveQuest]
    data*: QuestData
    lastMsg*: Table[string, Time]
    llm*: LlmClient
    instanceCounter*: int
    stop*: bool

var
  trophyTexts: Table[string, TrophyText]
  ## Translatable one-off trophy texts from trophies.json
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

# --- Helpers --------------------------------------------------------------------

proc extractJson(text: string): Option[JsonNode] =
  ## Extracts the first JSON object from an LLM response (markdown-tolerant)
  let start = text.find('{')
  let finish = text.rfind('}')
  if start >= 0 and finish > start:
    try:
      result = some(parseJson(text.substr(start, finish)))
    except CatchableError:
      result = none(JsonNode)
  else:
    result = none(JsonNode)

proc levenshtein(a, b: string): int =
  ## Classic edit distance (insertions, deletions, substitutions)
  var prev: seq[int] = newSeq[int](b.len + 1)
  for j in 0 .. b.len:
    prev[j] = j
  for i in 1 .. a.len:
    var curr: seq[int] = newSeq[int](b.len + 1)
    curr[0] = i
    for j in 1 .. b.len:
      let cost = if a[i - 1] == b[j - 1]: 0 else: 1
      curr[j] = min(min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost)
    prev = curr
  result = prev[b.len]

proc closestMatch(candidate: string, options: seq[string]): Option[string] =
  ## The option closest to the candidate by edit distance, case-insensitive.
  ## Accepted only when the distance is small relative to the length
  ## (a typo, not a different word)
  var best: string = ""
  var bestDist = high(int)
  for o in options:
    let d = levenshtein(candidate.toLowerAscii(), o.toLowerAscii())
    if d < bestDist:
      bestDist = d
      best = o
  if best.len > 0 and bestDist <= max(1, candidate.len div 4):
    result = some(best)

proc checkInterval(durationMin: int): Duration =
  ## Check interval derived from the duration: max(15, min(60, dur*12)) s
  let sec = max(15, min(60, durationMin * 12))
  result = initDuration(seconds = sec)

proc loadDefinitions(path: string): Table[string, QuestDefinition] =
  ## Parses quest_definitions.json (duration and objective required)
  result = initTable[string, QuestDefinition]()
  if not fileExists(path):
    echo "[PLUGIN] quests: quest_definitions.json missing: ", path
    return
  let node = loadJson(path)
  if node.kind != JObject:
    echo "[PLUGIN] quests: quest_definitions.json malformed"
    return
  for id, def in node.pairs:
    if def.kind != JObject:
      continue
    var q: QuestDefinition
    q.id = id
    if def.hasKey("system_prompt"): q.systemPrompt = def["system_prompt"].getStr
    if def.hasKey("objective"): q.objective = def["objective"].getStr
    if def.hasKey("completed_when"): q.completedWhen = def["completed_when"].getStr
    if def.hasKey("required_users"): q.requiredUsers = def["required_users"].getInt
    else: q.requiredUsers = 1
    if def.hasKey("duration"): q.duration = def["duration"].getInt
    if def.hasKey("trophy"): q.trophy = def["trophy"].getStr
    if def.hasKey("trophy_response"): q.trophyResponse = def["trophy_response"].getStr
    if q.duration <= 0:
      echo "[PLUGIN] quests: quest ", id, " without duration, ignored"
      continue
    if q.objective.len == 0:
      echo "[PLUGIN] quests: quest ", id, " without objective, ignored"
      continue
    result[id] = q

proc removeFromPool(state: QuestState, user: string) =
  for i, u in state.pool:
    if u == user:
      state.pool.delete(i)
      return

proc removeActive(state: QuestState, instId: string) =
  var tmp: ActiveQuest
  discard state.active.pop(instId, tmp)

proc markSimpleUsed(state: QuestState, id: string) =
  state.data.recentSimple.add(id)
  if state.data.recentSimple.len > 5:
    state.data.recentSimple.delete(0)

proc questJson(state: QuestState): JsonNode {.gcsafe.} =
  ## Quest state for the /v1/quest route (unified GUI)
  if state.active.len == 0:
    result = %*{"active": false}
    return
  var quests: JsonNode = %[]
  for _, q in state.active.pairs:
    quests.add(%*{"quest": %q.defId, "users": %q.users})
  result = %*{"active": %true, "quests": quests}

# --- Prompts (all in English) --------------------------------------------------

proc buildPickPrompt(state: QuestState, available: seq[QuestDefinition]): string =
  var s = "You are the quest director for a Twitch chat bot. "
  s &= "These users are ready for a quest: " & state.pool.join(", ") & ". "
  s &= "These quests are available:\n"
  for q in available:
    s &= "- " & q.id & ": personality \"" & q.systemPrompt &
         "\", objective \"" & q.objective &
         "\", needs " & $q.requiredUsers & " user(s)\n"
  s &= "Pick ONE quest and exactly the number of users it needs, all from the "
  s &= "ready list. Write the opening message IN CHARACTER as the quest's "
  s &= "personality. You MUST address each selected user by their exact "
  s &= "username (with the @ prefix) somewhere in the message; never use "
  s &= "generic terms like 'dear', 'friend' or 'everyone' without the real "
  s &= "name. "
  s &= "Language: " & state.cfg.botLanguage & ". "
  s &= "Respond with ONLY a JSON object: "
  s &= "{\"quest\": \"<quest_id>\", \"users\": [\"<user1>\", ...], \"message\": \"...\"}. "
  s &= "No preamble, no explanation, no markdown code fences (do NOT wrap "
  s &= "the JSON in ```json): the first character of your reply must be { and "
  s &= "the last one }."
  result = s

proc buildPrecheckPrompt(q: ActiveQuest, language: string): string =
  result =
    "You are the quest master. Adopt this personality: \"" & q.systemPrompt &
    "\". Quest: " & q.objective & ". " &
    "Completion condition: " & q.completedWhen & ". " &
    "Here are the chat messages from the user(s) since the quest started:\n" &
    q.transcript.join("\n") & "\n" &
    "Respond with ONLY a JSON object: " &
    "{\"completed\": \"yes\" | \"no\", \"message\": \"...\"}. " &
    "No preamble, no explanation, no markdown code fences (do NOT wrap " &
    "the JSON in ```json): the first character of your reply must be { " &
    "and the last one }. " &
    "\"message\" is ALWAYS required and must never be empty. " &
    "If it IS completed, set \"completed\" to \"yes\" and write in " &
    "\"message\" a brief in-character congratulation as the personality, " &
    "addressing the user(s) by their username(s) and thanking them. " &
    "If it is NOT completed, set \"completed\" to \"no\" and write in " &
    "\"message\" a brief in-character reply as the personality explaining " &
    "WHY you are not yet convinced that the quest is done, addressing the " &
    "user(s) by their username(s) and guiding them toward the goal. " &
    "Language: " & language & "."

proc buildDefeatPrompt(q: ActiveQuest, language: string): string =
  result =
    "You are the quest master. Adopt this personality: \"" & q.systemPrompt &
    "\". Quest: " & q.objective & ". " &
    "The time is up and the user(s) " & q.users.join(", ") &
    " did not complete the quest. " &
    "Respond with a defeated phrase in character. Language: " & language &
    ". Keep it brief."

proc buildHintPrompt(q: ActiveQuest, language: string): string =
  result =
    "You are the quest master. Adopt this personality: \"" & q.systemPrompt &
    "\". Quest: " & q.objective & ". Completion condition: " & q.completedWhen &
    ". The user(s) " & q.users.join(", ") & " are trying. " &
    "Here are their messages so far:\n" & q.transcript.join("\n") & "\n" &
    "Give them ONE helpful hint in character. Language: " & language &
    ". Keep it brief."

# --- Lifecycle ------------------------------------------------------------------

proc finishQuestComplete(ctx: PluginContext, state: QuestState,
                        q: ActiveQuest, announcement: string) {.async.} =
  ## Trophies + announcement + peer event (does NOT remove from state.active)
  let tracker = ctx.platform.trophyTracker
  let ts = toIsoString(now().toTime())
  var newTrophies: seq[(string, Trophy)] = @[]
  ## (user, trophy) pairs newly unlocked: notified in chat
  for user in q.users:
    state.data.completedCount[user] = state.data.completedCount.getOrDefault(user, 0) + 1
    let n = state.data.completedCount[user]
    if q.trophy.len > 0:
      let t = Trophy(name: q.trophy, command: "quest", unlockedAt: ts)
      if tracker.awardTrophy(user, t):
        newTrophies.add((user, t))
    let qc = trophyText(trophyTexts, "quest_completer", "Quest Completer", "")
    let qm = trophyText(trophyTexts, "quest_master", "Quest Master", "")
    if n >= 1:
      let t = Trophy(name: qc.name, command: "quest", unlockedAt: ts)
      if tracker.awardTrophy(user, t):
        newTrophies.add((user, t))
    if n >= 5:
      let t = Trophy(name: qm.name, command: "quest", unlockedAt: ts)
      if tracker.awardTrophy(user, t):
        newTrophies.add((user, t))
  saveTyped(ctx.statePath, state.data)

  ctx.setBusy("quest completed")
  await ctx.send(announcement)
  let tpl = trophyText(trophyTexts, "unlock", "",
    "🏆 {user} unlocked the trophy \"{name}\"!")
  for (user, t) in newTrophies:
    await ctx.send(tpl.message.replace("{user}", user).replace("{name}", t.name))
  ctx.clearBusy()

  ctx.broadcastEvent(PeerEvent(eventType: "quest_done",
                               user: q.users[0], detail: "completed"))

proc finishQuestTimeout(ctx: PluginContext, state: QuestState,
                       q: ActiveQuest) {.async.} =
  if q.isLlm and state.llm != nil:
    let resp = await state.llm.chatCompletion(
      @[LlmMessage(role: "user", content: buildDefeatPrompt(q, state.cfg.botLanguage))])
    if resp.len > 0:
      await ctx.send(resp)
    else:
      warn "[PLUGIN] quests: LLM defeat message is empty for ", q.instanceId
  else:
    await ctx.send(mtext("time_up", "⏰ Time's up, @{user}! The quest is over.")
                   .replace("{user}", q.users[0]))
  # separate, translatable failure message (only on expiry, never on a
  # precheck "no")
  let failedMsg =
    if q.users.len == 1: state.questFailedMsgSingle
    else: state.questFailedMsgMulti
  await ctx.send(failedMsg)
  ctx.broadcastEvent(PeerEvent(eventType: "quest_done",
                               user: q.users[0], detail: "abandoned"))

proc startLlmQuest(ctx: PluginContext, state: QuestState, questId: string,
                   users: seq[string], message: string) {.async.} =
  let qdef = state.definitions[questId]
  state.data.lastQuestDefId = questId
  saveTyped(ctx.statePath, state.data)
  state.instanceCounter += 1
  let nowT = now().toTime()
  state.active["q" & $state.instanceCounter] = ActiveQuest(
    instanceId: "q" & $state.instanceCounter,
    defId: questId,
    isLlm: true,
    users: users,
    startedAt: nowT,
    durationMin: qdef.duration,
    systemPrompt: qdef.systemPrompt,
    objective: qdef.objective,
    completedWhen: qdef.completedWhen,
    transcript: @[],
    hintUsed: false,
    lastCheckAt: nowT,
    trophy: qdef.trophy,
    trophyResponse: qdef.trophyResponse
  )
  for u in users:
    removeFromPool(state, u)
  ctx.setBusy("announcing quest")
  await ctx.send(message)
  ctx.clearBusy()
  ctx.broadcastEvent(PeerEvent(eventType: "quest_active",
                               user: users[0], detail: questId))

proc startSimpleQuest(ctx: PluginContext, state: QuestState) {.async.} =
  if state.simpleQuests.len == 0 or state.pool.len == 0:
    return
  let sq = pickSimpleQuest(state.simpleQuests, state.data.recentSimple)
  let user = state.pool[rand(state.pool.high)]
  state.instanceCounter += 1
  let nowT = now().toTime()
  state.active["q" & $state.instanceCounter] = ActiveQuest(
    instanceId: "q" & $state.instanceCounter,
    defId: sq.id,
    isLlm: false,
    users: @[user],
    startedAt: nowT,
    durationMin: sq.duration,
    objective: sq.text,
    requiredText: sq.requiredText.split("{streamer}").join(state.channel),
    requiredCount: sq.requiredCount,
    progress: 0,
    transcript: @[],
    hintUsed: false,
    lastCheckAt: nowT,
    trophy: sq.trophy,
    trophyResponse: sq.trophyResponse
  )
  removeFromPool(state, user)
  markSimpleUsed(state, sq.id)
  ctx.setBusy("announcing quest")
  await ctx.send(mtext("simple_announce", "📜 @{user}, your quest: {text}")
                 .replace("{user}", user)
                 .replace("{text}", sq.text))
  ctx.clearBusy()
  ctx.broadcastEvent(PeerEvent(eventType: "quest_active", user: user, detail: sq.id))

proc tryLlmAssignment(ctx: PluginContext, state: QuestState): Future[bool] {.async.} =
  ## The LLM picks quest + users (max 3 attempts, same conversation).
  ## true = quest assigned, false = the simple fallback is needed.
  var activeDefs: seq[string] = @[]
  for _, q in state.active.pairs:
    activeDefs.add(q.defId)
  var available: seq[QuestDefinition] = @[]
  for id, q in state.definitions.pairs:
    if id notin activeDefs:
      available.add(q)
  if available.len == 0:
    return false
  # The last quest picked is excluded, so the same quest is not chosen
  # again and again (only when there is at least one alternative)
  if available.len > 1:
    available = available.filterIt(it.id != state.data.lastQuestDefId)

  var convo: seq[LlmMessage] = @[LlmMessage(role: "user",
    content: buildPickPrompt(state, available))]
  for attempt in 0 ..< state.maxPickAttempts:
    let resp = await state.llm.chatCompletion(convo)
    debug "[PLUGIN] quests: pick attempt ", $attempt, " — LLM response: ", resp
    let node = extractJson(resp)
    if node.isNone:
      warn "[PLUGIN] quests: pick attempt ", $attempt,
           " — response is not valid JSON: ",
           resp.substr(0, min(resp.len, 500))
    var questId = ""
    var users: seq[string] = @[]
    var message = ""
    if node.isSome:
      let n = node.get()
      if n.hasKey("quest") and n["quest"].kind == JString:
        questId = n["quest"].getStr
      if n.hasKey("users") and n["users"].kind == JArray:
        for u in n["users"]:
          if u.kind == JString:
            users.add(u.getStr)
      if n.hasKey("message") and n["message"].kind == JString:
        message = n["message"].getStr

    # Fuzzy repair for typos in the quest id and usernames
    if questId.len > 0 and not state.definitions.hasKey(questId):
      let m = closestMatch(questId, toSeq(state.definitions.keys))
      if m.isSome:
        warn "[PLUGIN] quests: quest id typo \"", questId, "\" -> \"", m.get(), "\""
        questId = m.get()
    var fuzzyFrom: Table[string, string]
    ## corrected username -> raw (misspelled) string from the LLM
    for i, u in users:
      if u notin state.pool:
        let m = closestMatch(u, state.pool)
        if m.isSome:
          warn "[PLUGIN] quests: username typo \"", u, "\" -> \"", m.get(), "\""
          fuzzyFrom[m.get()] = u
          users[i] = m.get()

    # Checks: valid quest, users in the pool, count, active.
    # `reason` carries the exact rejection cause for the log.
    var reason = ""
    if questId.len == 0:
      reason = "missing quest id"
    elif not state.definitions.hasKey(questId):
      reason = "unknown quest: " & questId
    elif message.len == 0:
      reason = "empty message"
    elif users.len != state.definitions[questId].requiredUsers:
      reason = "wrong user count (needs " &
               $state.definitions[questId].requiredUsers & ", got " &
               $users.len & ")"
    else:
      for u in users:
        if u notin state.pool:
          reason = "user not in the pool: " & u
          break
        if now().toTime() - state.lastMsg.getOrDefault(u, initTime(0, 0)) >
            initDuration(minutes = state.inactiveMin):
          reason = "user inactive for more than " & $state.inactiveMin &
                   " minutes: " & u
          break
      # the message must mention every chosen user (no generic text);
      # a fuzzy-corrected user is mentioned if the raw (misspelled)
      # string is in the message
      if reason.len == 0:
        let msgLower = message.toLowerAscii()
        for u in users:
          let raw = fuzzyFrom.getOrDefault(u, "")
          if u.toLowerAscii() notin msgLower and
              raw.toLowerAscii() notin msgLower:
            reason = "message does not mention the user: " & u
            break
    if reason.len == 0:
      await startLlmQuest(ctx, state, questId, users, message)
      return true

    warn "[PLUGIN] quests: pick attempt ", $attempt, " rejected — ", reason,
         " (questId=", questId, ", users=", users.join("|"), ")"
    warn "[PLUGIN] quests: pick attempt ", $attempt, " message: ", message
    convo.add(LlmMessage(role: "assistant", content: resp))
    convo.add(LlmMessage(role: "user", content:
      "You did not pick a valid quest, or you did not use the right number " &
      "of users from the ready list, or you used names that are not in the " &
      "ready list. Try again."))
  return false

# --- Loops ----------------------------------------------------------------------

proc questLoop(ctx: PluginContext, state: QuestState) {.async.} =
  let intervalMs = state.cfg.questSystem.periodicQuestCall * 60_000
  while not state.stop:
    await sleepAsync(intervalMs)
    if state.stop:
      break
    # removes from the pool users inactive for more than 10 minutes
    var i = 0
    while i < state.pool.len:
      let u = state.pool[i]
      if now().toTime() - state.lastMsg.getOrDefault(u, initTime(0, 0)) >
          initDuration(minutes = state.inactiveMin):
        state.pool.delete(i)
      else:
        i += 1
    if state.pool.len == 0:
      continue
    if state.cfg.questSystem.llmActive and state.llm != nil:
      if not await tryLlmAssignment(ctx, state):
        await startSimpleQuest(ctx, state)
    else:
      await startSimpleQuest(ctx, state)

proc checkLoop(ctx: PluginContext, state: QuestState) {.async.} =
  var lastTranscriptLen: Table[string, int]
  ## transcript length at the last precheck, per quest instance:
  ## a rejection is logged only if new messages were evaluated
  while not state.stop:
    await sleepAsync(state.checkTickMs)
    if state.stop:
      break
    # snapshot of the keys: state.active can change during the awaits
    var keys: seq[string] = @[]
    for k, _ in state.active.pairs:
      keys.add(k)
    for instId in keys:
      if not state.active.hasKey(instId):
        continue
      let q = state.active[instId]
      let elapsed = now().toTime() - q.startedAt
      if elapsed >= initDuration(minutes = q.durationMin):
        try:
          await finishQuestTimeout(ctx, state, q)
        except CatchableError as e:
          echo "[PLUGIN] quests: timeout send failed for ", instId, ": ", e.msg
        removeActive(state, instId)
        continue
      if now().toTime() - q.lastCheckAt >= checkInterval(q.durationMin):
        state.active[instId].lastCheckAt = now().toTime()
        if q.isLlm and state.llm != nil:
          let resp = await state.llm.chatCompletion(
            @[LlmMessage(role: "user",
              content: buildPrecheckPrompt(q, state.cfg.botLanguage))])
          debug "[PLUGIN] quests: precheck ", instId, " — LLM response: ", resp
          let node = extractJson(resp)
          if node.isNone:
            warn "[PLUGIN] quests: precheck ", instId,
                 " — response is not valid JSON: ",
                 resp.substr(0, min(resp.len, 500))
          var completed = false
          var message = ""
          if node.isSome:
            let n = node.get()
            if n.hasKey("completed") and n["completed"].kind == JString:
              completed = n["completed"].getStr.strip().toLowerAscii() == "yes"
            if n.hasKey("message") and n["message"].kind == JString:
              message = n["message"].getStr
          let hadNewMessages =
            q.transcript.len > lastTranscriptLen.getOrDefault(instId, 0)
          lastTranscriptLen[instId] = q.transcript.len
          if not completed and hadNewMessages:
            info "[PLUGIN] quests: precheck ", instId,
                 " — rejected the latest answer(s)"
            if message.len > 0:
              try:
                await ctx.send(message)
              except CatchableError as e:
                echo "[PLUGIN] quests: precheck rejection send failed for ",
                     instId, ": ", e.msg
          if completed:
            var ann =
              if message.len > 0:
                if q.trophyResponse.len > 0:
                  message & " " & q.trophyResponse
                else:
                  message
              else:
                q.trophyResponse
            if ann.len == 0:
              warn "[PLUGIN] quests: completion announcement is empty for ",
                   instId
            try:
              await finishQuestComplete(ctx, state, q, ann)
            except CatchableError as e:
              echo "[PLUGIN] quests: completion send failed for ", instId, ": ", e.msg
            removeActive(state, instId)

proc loadQuestConfig(path: string): (int, int, int, string, string) =
  ## (inactive_minutes, max_pick_attempts, check_tick_ms,
  ## quest_failed_message_single, quest_failed_message_multi) from
  ## config.json; defaults if missing
  result = (DefaultInactiveMinutes, DefaultMaxPickAttempts, DefaultCheckTickMs,
            DefaultQuestFailedMsgSingle, DefaultQuestFailedMsgMulti)
  if not fileExists(path):
    return
  let node = loadJson(path)
  if node.kind != JObject:
    return
  if node.hasKey("inactive_minutes") and node["inactive_minutes"].kind == JInt:
    let v = node["inactive_minutes"].getInt
    if v > 0: result[0] = v
  if node.hasKey("max_pick_attempts") and node["max_pick_attempts"].kind == JInt:
    let v = node["max_pick_attempts"].getInt
    if v > 0: result[1] = v
  if node.hasKey("check_tick_ms") and node["check_tick_ms"].kind == JInt:
    let v = node["check_tick_ms"].getInt
    if v > 0: result[2] = v
  if node.hasKey("quest_failed_message_single") and
      node["quest_failed_message_single"].kind == JString:
    let v = node["quest_failed_message_single"].getStr
    if v.len > 0: result[3] = v
  if node.hasKey("quest_failed_message_multi") and
      node["quest_failed_message_multi"].kind == JString:
    let v = node["quest_failed_message_multi"].getStr
    if v.len > 0: result[4] = v

# --- Registration ---------------------------------------------------------------

proc register*(ctx: PluginContext) =
  if not ctx.isEnabled():
    echo "[PLUGIN] quests: disabled in config.json"
    return
  let cfg = ctx.platform.router.config
  if not cfg.questSystem.enabled:
    echo "[PLUGIN] quests: disabled in config"
    return
  if cfg.questSystem.periodicQuestCall <= 0:
    echo "[PLUGIN] quests: periodic_quest_call not valid in config"
    return

  let (inactiveMin, maxPick, checkTick, failedSingle, failedMulti) =
    loadQuestConfig(ctx.dir / "config.json")
  trophyTexts = loadTrophyTexts(ctx.dir / "trophies.json")
  msgTexts = loadMsgs(ctx.dir / "messages.json")
  let state = QuestState(
    cfg: cfg,
    channel: cfg.channel,
    inactiveMin: inactiveMin,
    maxPickAttempts: maxPick,
    checkTickMs: checkTick,
    questFailedMsgSingle: failedSingle,
    questFailedMsgMulti: failedMulti,
    definitions: loadDefinitions(ctx.dir / "quest_definitions.json"),
    simpleQuests: loadSimpleQuests(ctx.dir / "simple_quests.jsonc"),
    pool: @[],
    active: initTable[string, ActiveQuest](),
    data: loadTyped[QuestData](ctx.statePath, QuestData()),
    lastMsg: initTable[string, Time](),
    llm: if cfg.llmServer.isValid: newLlmClient(cfg.llmServer) else: nil,
    instanceCounter: 0,
    stop: false
  )

  # chat: last message tracking + transcript + simple quest progress
  ctx.onMessage(proc(msg: ChatMessage) {.async.} =
    state.lastMsg[msg.username] = now().toTime()
    var completed: seq[string] = @[]
    for instId, q in state.active.pairs:
      if msg.username notin q.users:
        continue
      state.active[instId].transcript.add(msg.username & ": " & msg.content)
      if not state.active[instId].isLlm:
        let req = state.active[instId].requiredText
        if req.len > 0 and
            msg.content.toLowerAscii().contains(req.toLowerAscii()):
          state.active[instId].progress += 1
          if state.active[instId].progress >= state.active[instId].requiredCount:
            completed.add(instId)
    for instId in completed:
      let q = state.active[instId]
      removeActive(state, instId)
      var ann = mtext("completed",
                      "🏆 {user} completed the quest!")
                  .replace("{user}", q.users[0])
      if q.trophyResponse.len > 0:
        ann = ann & " " & q.trophyResponse
      await finishQuestComplete(ctx, state, q, ann)
  )

  # route for the unified GUI
  ctx.httpRoute("/v1/quest", proc(body: JsonNode): Future[JsonNode] {.async, gcsafe.} =
    result = questJson(state)
  )

  # commands
  let specs = loadCommandSpecs(ctx.dir / "commands.json")
  var handlers: Table[string, CommandHandler]
  handlers["adventure"] = proc(msg: ChatMessage, cmd: Command,
                               router: CommandRouter) {.async.} =
    let user = msg.username
    if user in state.pool:
      await ctx.send(mtext("already_in_pool",
                           "{user}, you're already up for a quest!")
                     .replace("{user}", user))
      return
    var inActive = false
    for _, q in state.active.pairs:
      if user in q.users:
        inActive = true
        break
    if inActive:
      await ctx.send(mtext("has_active",
                           "{user}, you already have an active quest!")
                     .replace("{user}", user))
      return
    state.pool.add(user)
    await ctx.send(mtext("added_to_pool",
                         "{user}, you're up for a quest! 📜")
                   .replace("{user}", user))
  handlers["noadventure"] = proc(msg: ChatMessage, cmd: Command,
                                 router: CommandRouter) {.async.} =
    let user = msg.username
    removeFromPool(state, user)
    await ctx.send(mtext("left_pool",
                         "{user}, you're out of the quest pool.")
                   .replace("{user}", user))
  handlers["quest"] = proc(msg: ChatMessage, cmd: Command,
                           router: CommandRouter) {.async.} =
    let user = msg.username
    var found: Option[string] = none(string)
    for instId, q in state.active.pairs:
      if user in q.users:
        found = some(instId)
        break
    if found.isNone:
      await ctx.send(mtext("no_active",
                           "{user}, you don't have an active quest.")
                     .replace("{user}", user))
      return
    let instId = found.get()
    let q = state.active[instId]
    if q.hintUsed:
      await ctx.send(mtext("hint_used",
                           "{user}, you already used your hint for this quest.")
                     .replace("{user}", user))
      return
    state.active[instId].hintUsed = true
    if not q.isLlm:
      await ctx.send(mtext("simple_objective",
                           "Your quest: {objective}")
                     .replace("{objective}", q.objective))
      return
    let resp = await state.llm.chatCompletion(
      @[LlmMessage(role: "user",
        content: buildHintPrompt(q, state.cfg.botLanguage))])
    if resp.len > 0:
      await ctx.send(resp)
    else:
      warn "[PLUGIN] quests: LLM hint response is empty for ", instId
  registerCommands(ctx, specs, handlers)

  # shutdown
  ctx.onShutdown(proc() {.async.} =
    state.stop = true
    saveTyped(ctx.statePath, state.data)
  )

  if state.llm == nil:
    echo "[PLUGIN] quests: LLM not available, only simple quests"
  asyncCheck questLoop(ctx, state)
  asyncCheck checkLoop(ctx, state)
