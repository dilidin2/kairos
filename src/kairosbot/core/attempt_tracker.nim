import std/[tables, times, asyncdispatch, json]

import ../data/persistence

type
  AttemptEntry* = object
    used*: int
    date*: string

  AttemptTracker* = ref object
    attempts*: Table[string, Table[string, AttemptEntry]]
    dataPath*: string
    saver: DebouncedSaver

proc saveAttempts*(tracker: AttemptTracker) =
  ## Saves the attempts to the JSON file
  saveTyped(tracker.dataPath, tracker.attempts)
  discard

proc newAttemptTracker*(dataPath: string = "data/attempts.json"): AttemptTracker =
  ## Creates a new AttemptTracker and loads the persistent data
  let default = initTable[string, Table[string, AttemptEntry]]()

  let attempts = loadTyped(dataPath, default)

  var tracker = AttemptTracker(attempts: attempts, dataPath: dataPath)
  tracker.saver = newDebouncedSaver(proc () {.closure.} = saveAttempts(tracker))
  result = tracker

proc getCurrentDate*(): string =
  ## Returns the current UTC date in yyyy-MM-dd format
  let format = initTimeFormat("yyyy-MM-dd")

  result = now().utc.format(format)

proc getAttemptsUsed*(tracker: AttemptTracker, user: string, command: string): int =
  ## Returns the attempts used today for a user/command
  if tracker.attempts.hasKey(user) and tracker.attempts[user].hasKey(command):
    let entry = tracker.attempts[user][command]

    if entry.date != getCurrentDate():
      result = 0
    else:
      result = entry.used
  else:
    result = 0

proc hasAttemptsLeft*(tracker: AttemptTracker, user: string, command: string, maxAttempts: int): bool =
  ## Checks whether the user still has attempts available
  if getAttemptsUsed(tracker, user, command) < maxAttempts:
    result = true
  else:
    result = false

proc scheduleSave*(tracker: AttemptTracker) =
  ## Schedules a debounced save (5s)
  tracker.saver.schedule()

proc useAttempt*(tracker: AttemptTracker, user: string, command: string) =
  ## Consumes an attempt for a user/command and schedules a save
  let today = getCurrentDate()

  if not tracker.attempts.hasKey(user):
    tracker.attempts[user] = initTable[string, AttemptEntry]()

  if tracker.attempts[user].hasKey(command):
    let current = tracker.attempts[user][command]
    if current.date == today:
      tracker.attempts[user][command].used += 1
    else:
      tracker.attempts[user][command] = AttemptEntry(used: 1, date: today)
  else:
    tracker.attempts[user][command] = AttemptEntry(used: 1, date: today)

  scheduleSave(tracker)

proc getRemainingAttempts*(tracker: AttemptTracker, user: string, command: string, maxAttempts: int): int =
  ## Returns the remaining attempts

  let used = getAttemptsUsed(tracker, user, command)

  let remaining = maxAttempts - used
  result = remaining

  if used > maxAttempts:
    result = 0

proc forceSave*(tracker: AttemptTracker) {.async.} =
  ## Saves immediately, ignoring the debounce
  tracker.saver.flush()

