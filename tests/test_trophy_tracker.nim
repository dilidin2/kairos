import std/[unittest, os, tables]

import ../src/kairosbot/core/trophy_tracker

var tmpCounter = 0

proc freshTracker(): TrophyTracker =
  tmpCounter += 1
  result = newTrophyTracker(getTempDir() / ("kairos_test_trophies_" & $tmpCounter & ".json"))

proc mkRule(name, eventType: string, threshold: int, ruleType = trtTotal): TrophyRule =
  TrophyRule(name: name, eventType: eventType, threshold: threshold,
    description: "desc " & name, ruleType: ruleType)

suite "TrophyTracker":

  test "newTrophyTracker creates an empty tracker":
    let tracker = freshTracker()
    check tracker.getUserTrophies("mario").len == 0

  test "addRules registers rules per command":
    let tracker = freshTracker()
    let rules = @[mkRule("Primo", "win", 1), mkRule("Trictrac", "win", 3)]
    tracker.addRules("slots", rules)
    check tracker.rules["slots"].len == 2
    check tracker.rules["slots"][0].name == "Primo"

  test "recordEvent increments counters":
    let tracker = freshTracker()
    discard tracker.recordEvent("mario", "slots", "win")
    discard tracker.recordEvent("mario", "slots", "win")
    let key = makeCounterKey("mario", "slots", "win")
    check tracker.counters[key] == 2
    check tracker.streaks[key] == 2

  test "recordEvent awards a trophy when the threshold is reached":
    let tracker = freshTracker()
    tracker.addRules("slots", @[mkRule("Gambler", "win", 2)])
    let t1 = tracker.recordEvent("mario", "slots", "win")
    check t1.len == 0
    let t2 = tracker.recordEvent("mario", "slots", "win")
    check t2.len == 1
    check t2[0].name == "Gambler"
    check t2[0].command == "slots"
    # already unlocked: no duplicates
    check tracker.recordEvent("mario", "slots", "win").len == 0

  test "recordEvent awards all matching trophies":
    let tracker = freshTracker()
    tracker.addRules("slots", @[
      mkRule("Primo", "win", 1),
      mkRule("Trictrac", "win", 2)
    ])
    let t1 = tracker.recordEvent("mario", "slots", "win")
    check t1.len == 1 and t1[0].name == "Primo"
    let t2 = tracker.recordEvent("mario", "slots", "win")
    check t2.len == 1 and t2[0].name == "Trictrac"
    check tracker.getUserTrophies("mario").len == 2

  test "getUserTrophies returns the user's trophies":
    let tracker = freshTracker()
    tracker.addRules("slots", @[mkRule("Gambler", "win", 1)])
    discard tracker.recordEvent("mario", "slots", "win")
    check tracker.getUserTrophies("mario").len == 1
    check tracker.getUserTrophies("pippo").len == 0

  test "getTrophiesByCommand filters by command":
    let tracker = freshTracker()
    tracker.addRules("slots", @[mkRule("Gambler", "win", 1)])
    tracker.addRules("8ball", @[mkRule("Saggezza", "win", 1)])
    discard tracker.recordEvent("mario", "slots", "win")
    discard tracker.recordEvent("mario", "8ball", "win")
    let bySlots = tracker.getTrophiesByCommand("mario", "slots")
    check bySlots.len == 1 and bySlots[0].command == "slots"
    check tracker.getTrophiesByCommand("mario", "8ball").len == 1
    check tracker.getTrophiesByCommand("mario", "inexistente").len == 0

  test "resetOppositeStreak resets the opposite streak":
    let tracker = freshTracker()
    let lossKey = makeCounterKey("mario", "slots", "loss")
    tracker.incrementStreak(lossKey)
    tracker.incrementStreak(lossKey)
    check tracker.streaks[lossKey] == 2
    tracker.resetOppositeStreak("mario", "slots", "win")
    check tracker.streaks[lossKey] == 0
    # eventType with no opposite (draw): no-op
    tracker.incrementStreak(lossKey)
    tracker.resetOppositeStreak("mario", "slots", "draw")
    check tracker.streaks[lossKey] == 1

  test "streak rule type works correctly":
    let tracker = freshTracker()
    tracker.addRules("slots", @[mkRule("Hot Streak", "win", 2, trtStreak)])
    check tracker.recordEvent("mario", "slots", "win").len == 0
    check tracker.recordEvent("mario", "slots", "win").len == 1
    # a loss breaks the streak: the next win does not complete the threshold
    discard tracker.recordEvent("mario", "slots", "loss")
    check tracker.recordEvent("mario", "slots", "win").len == 0
