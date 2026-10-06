import std/[tables, times]

type
  CooldownEntry* = object
    timestamp*: float
    duration*: float

  CooldownTracker* = ref object
    cooldowns*: Table[string, Table[string, CooldownEntry]]

proc newCooldownTracker*(): CooldownTracker =
  ## Creates a new CooldownTracker
  var cooldowns = initTable[string, Table[string, CooldownEntry]]()

  result = CooldownTracker(cooldowns: cooldowns)


proc isOnCooldown*(tracker: CooldownTracker, user: string, command: string): bool =
  ## Checks whether a user is on cooldown for a command
  if tracker.cooldowns.hasKey(user) and tracker.cooldowns[user].hasKey(command):
    let entry = tracker.cooldowns[user][command]
    let cooldown = entry.duration + entry.timestamp

    if epochTime() < cooldown:
      result = true
    else:
      result = false
  else:
    result = false

proc getRemaining*(tracker: CooldownTracker, user: string, command: string): float =
  ## Returns the remaining cooldown seconds (0 if not on cooldown)
  if tracker.cooldowns.hasKey(user) and tracker.cooldowns[user].hasKey(command):
    let entry = tracker.cooldowns[user][command]
    let endsIn = entry.duration + entry.timestamp

    if epochTime() > endsIn:
      result = 0
    else:
      result = endsIn - epochTime()

proc setCooldown*(tracker: CooldownTracker, user: string, command: string, duration: float) =
  ## Sets a cooldown for a user and command
  if tracker.cooldowns.hasKey(user) == false:
    tracker.cooldowns[user] = initTable[string, CooldownEntry]()

  tracker.cooldowns[user][command] = CooldownEntry(timestamp: epochTime(), duration: duration)

proc cleanupExpired*(tracker: CooldownTracker) =
  ## Removes expired cooldowns

  var deletable: seq[(string,string)] = @[]

  for userName, userCooldowns in tracker.cooldowns.pairs():
    for command, entry in userCooldowns.pairs:
      if entry.timestamp + entry.duration < epochTime():
        deletable.add((userName, command))

  for (user, command) in deletable: tracker.cooldowns[user].del(command)
