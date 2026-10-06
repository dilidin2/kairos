import std/[tables, times, strutils, asyncdispatch, options, json, sequtils]

import ../data/persistence

type
  TrophyRuleType* = enum
    trtTotal
    trtStreak

  TrophyRule* = object
    name*: string
    eventType*: string
    threshold*: int
    description*: string
    ruleType*: TrophyRuleType

  Trophy* = object
    name*: string
    command*: string
    unlockedAt*: string

  TrophyTracker* = ref object
    rules*: Table[string, seq[TrophyRule]]
    counters*: Table[string, int]
    streaks*: Table[string, int]
    trophies*: Table[string, seq[Trophy]]
    dataPath*: string
    saveGeneration*: int
    saveFuture*: Option[Future[void]]

  TrophyData* = object
    counters*: Table[string, int]
    streaks*: Table[string, int]
    trophies*: Table[string, seq[Trophy]]

proc toIsoString*(t: Time): string =
  ## Converts a Time to an ISO8601 string

  let format = initTimeFormat("yyyy-MM-dd'T'HH:mm:sszzz")

  result = t.utc.format(format)

proc makeCounterKey*(user: string, command: string, eventType: string): string =
  ## Builds the key for counters and streaks
  let sep = "|"

  let conc = user.toLowerAscii() & sep & command & sep & eventType

  result = conc

proc incrementCounter*(tracker: TrophyTracker, key: string) =
  ## Increments a total counter
  tracker.counters[key] = tracker.counters.getOrDefault(key, 0) + 1

proc incrementStreak*(tracker: TrophyTracker, key: string) =
  ## Increments a streak
  tracker.streaks[key] = tracker.streaks.getOrDefault(key, 0) + 1

proc resetOppositeStreak*(tracker: TrophyTracker, user: string, command: string, eventType: string) =
  ## Resets the streak of the opposite event (e.g. win resets the loss streak)
  let opposite =
    if eventType == "win": "loss"
    elif eventType == "loss": "win"
    else: return

  let key = makeCounterKey(user, command, opposite)

  if key in tracker.streaks:
    tracker.streaks[key] = 0

proc saveTrophies*(tracker: TrophyTracker) =
  ## Saves trophies and counters to the JSON file
  let data = TrophyData(counters: tracker.counters, streaks: tracker.streaks, trophies: tracker.trophies)

  saveTyped(tracker.dataPath, data)

proc performDebounceSave*(tracker: TrophyTracker, myGen: int) {.async.} =
  ## Performs the debounced save after 5s if this is still the current generation
  await sleepAsync(5000)

  if myGen != tracker.saveGeneration:
    return
  else:
    saveTrophies(tracker)
    tracker.saveFuture = none(Future[void])

proc scheduleSave*(tracker: TrophyTracker) =
  ## Schedules a debounced save (5s)
  tracker.saveGeneration += 1
  let locGen = tracker.saveGeneration

  let deb = performDebounceSave(tracker, locGen)

  tracker.saveFuture = some(deb)

proc newTrophyTracker*(dataPath: string = "data/trophies.json"): TrophyTracker =
  ## Creates a new TrophyTracker and loads the persistent data
  var rules = initTable[string, seq[TrophyRule]]()

  let default = TrophyData(counters: initTable[string, int](), streaks: initTable[string, int](), trophies: initTable[string, seq[Trophy]]())
  
  let loadedData = loadTyped[TrophyData](dataPath, default)

  result = TrophyTracker(
    rules: rules,
    counters: loadedData.counters,
    streaks: loadedData.streaks,
    trophies: loadedData.trophies,
    dataPath: dataPath,
    saveGeneration: 0,
    saveFuture: none(Future[void])
  )
  
proc addRules*(tracker: TrophyTracker, command: string, rules: seq[TrophyRule]) =
  ## Registers trophy rules for a command
  if command in tracker.rules:
    quit("Duplicated rule found! " & command)

  tracker.rules[command] = rules

proc checkRules*(tracker: TrophyTracker, user: string, command: string, eventType: string): seq[Trophy] =
  ## Checks the rules and returns the trophies to be awarded
  let rules = tracker.rules.getOrDefault(command, @[])
  let key = makeCounterKey(user, command, eventType)
  var userTrophies = tracker.trophies.getOrDefault(user, @[])

  for rule in rules:
    if rule.eventType != eventType:
      continue

    let value =
      if rule.ruleType == trtTotal:
        tracker.counters.getOrDefault(key, 0)
      else:
        tracker.streaks.getOrDefault(key, 0)

    if value < rule.threshold:
      continue

    let alreadyUnlocked = userTrophies.anyIt(it.name == rule.name and it.command == command)
    if alreadyUnlocked:
      continue

    let trophy = Trophy(name: rule.name, command: command, unlockedAt: toIsoString(now().toTime()))

    userTrophies.add(trophy)
    result.add(trophy)

  tracker.trophies[user] = userTrophies

proc awardTrophy*(tracker: TrophyTracker, user: string, trophy: Trophy): bool =
  ## Awards a trophy directly (for results outside the
  ## counter/streak model, e.g. "first to reach 1000"). Dedupes by
  ## (name, command) and schedules a save.
  var userTrophies = tracker.trophies.getOrDefault(user, @[])
  if userTrophies.anyIt(it.name == trophy.name and it.command == trophy.command):
    return false
  userTrophies.add(trophy)
  tracker.trophies[user] = userTrophies
  scheduleSave(tracker)
  result = true

proc recordEvent*(tracker: TrophyTracker, user: string, command: string, eventType: string): seq[Trophy] =
  ## Records an event and returns all the trophies unlocked
  let key = makeCounterKey(user, command, eventType)

  incrementCounter(tracker, key)
  incrementStreak(tracker, key)
  resetOppositeStreak(tracker, user, command, eventType)

  result = checkRules(tracker, user, command, eventType)

  scheduleSave(tracker)

proc getUserTrophies*(tracker: TrophyTracker, user: string): seq[Trophy] =
  ## Returns all the trophies of a user
  result = tracker.trophies.getOrDefault(user, @[])

proc getTrophiesByCommand*(tracker: TrophyTracker, user: string, command: string): seq[Trophy] =
  ## Returns a user's trophies for a specific command
  let trophies = getUserTrophies(tracker, user)

  result = trophies.filterIt(it.command == command)

proc forceSave*(tracker: TrophyTracker) {.async.} =
  ## Saves immediately, ignoring the debounce
  tracker.saveGeneration += 1

  if tracker.saveFuture.isSome:
    await tracker.saveFuture.get()
    tracker.saveFuture = options.none(Future[void])
  saveTrophies(tracker)
