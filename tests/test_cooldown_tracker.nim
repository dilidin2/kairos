import std/[unittest, times, os]

import ../src/kairosbot/core/cooldown_tracker

suite "CooldownTracker":

  test "newCooldownTracker creates an empty tracker":
    let tracker = newCooldownTracker()
    check not tracker.isOnCooldown("mario", "slots")
    check tracker.getRemaining("mario", "slots") == 0.0

  test "isOnCooldown returns false for a command not set":
    let tracker = newCooldownTracker()
    check not tracker.isOnCooldown("mario", "8ball")

  test "isOnCooldown returns true during the cooldown":
    let tracker = newCooldownTracker()
    tracker.setCooldown("mario", "slots", 10.0)
    check tracker.isOnCooldown("mario", "slots")

  test "isOnCooldown returns false after expiry":
    let tracker = newCooldownTracker()
    tracker.setCooldown("mario", "slots", 0.05)
    sleep(150)
    check not tracker.isOnCooldown("mario", "slots")

  test "getRemaining returns the correct time":
    let tracker = newCooldownTracker()
    tracker.setCooldown("mario", "slots", 10.0)
    let rem = tracker.getRemaining("mario", "slots")
    check rem > 9.0 and rem <= 10.0
    # expired: 0
    tracker.setCooldown("mario", "8ball", 0.05)
    sleep(150)
    check tracker.getRemaining("mario", "8ball") == 0.0

  test "setCooldown sets a cooldown for user/command":
    let tracker = newCooldownTracker()
    tracker.setCooldown("mario", "slots", 10.0)
    check tracker.isOnCooldown("mario", "slots")
    check not tracker.isOnCooldown("pippo", "slots")    # other user
    check not tracker.isOnCooldown("mario", "8ball")   # other command
    # same pair: overwrites
    tracker.setCooldown("mario", "slots", 20.0)
    check tracker.getRemaining("mario", "slots") > 19.0

  test "cleanupExpired removes expired cooldowns":
    let tracker = newCooldownTracker()
    tracker.setCooldown("mario", "vecchio", 0.05)
    tracker.setCooldown("mario", "attivo", 100.0)
    sleep(150)
    tracker.cleanupExpired()
    check not tracker.isOnCooldown("mario", "vecchio")
    check tracker.isOnCooldown("mario", "attivo")
