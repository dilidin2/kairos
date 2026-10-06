import std/[unittest, os, times, tables]

import ../src/kairosbot/core/attempt_tracker

var tmpCounter = 0

proc freshTracker(): AttemptTracker =
  tmpCounter += 1
  result = newAttemptTracker(getTempDir() / ("kairos_test_attempts_" & $tmpCounter & ".json"))

suite "AttemptTracker":

  test "newAttemptTracker creates an empty tracker":
    let tracker = freshTracker()
    check tracker.getAttemptsUsed("mario", "slots") == 0

  test "getAttemptsUsed returns 0 for a new user":
    let tracker = freshTracker()
    check tracker.getAttemptsUsed("nessuno", "8ball") == 0

  test "hasAttemptsLeft returns true when under the limit":
    let tracker = freshTracker()
    check tracker.hasAttemptsLeft("mario", "slots", 5)

  test "hasAttemptsLeft returns false when at the limit":
    let tracker = freshTracker()
    for i in 1 .. 5:
      tracker.useAttempt("mario", "slots")
    check not tracker.hasAttemptsLeft("mario", "slots", 5)
    check tracker.hasAttemptsLeft("mario", "slots", 6)

  test "useAttempt increments the counter":
    let tracker = freshTracker()
    tracker.useAttempt("mario", "slots")
    tracker.useAttempt("mario", "slots")
    check tracker.getAttemptsUsed("mario", "slots") == 2
    # other user/command untouched
    check tracker.getAttemptsUsed("pippo", "slots") == 0
    check tracker.getAttemptsUsed("mario", "8ball") == 0

  test "getRemainingAttempts computes correctly":
    let tracker = freshTracker()
    check tracker.getRemainingAttempts("mario", "slots", 5) == 5
    tracker.useAttempt("mario", "slots")
    tracker.useAttempt("mario", "slots")
    check tracker.getRemainingAttempts("mario", "slots", 5) == 3

  test "getCurrentDate returns the correct UTC date":
    let expected = format(utc(now()), "yyyy-MM-dd")
    check getCurrentDate() == expected

  test "automatic reset when the date changes":
    let tracker = freshTracker()
    tracker.useAttempt("mario", "slots")
    # I simulate a record from yesterday: the count must reset to zero
    var inner = tracker.attempts["mario"]
    inner["slots"] = AttemptEntry(used: 5, date: "2020-01-01")
    tracker.attempts["mario"] = inner
    check tracker.getAttemptsUsed("mario", "slots") == 0
    check tracker.hasAttemptsLeft("mario", "slots", 5)
