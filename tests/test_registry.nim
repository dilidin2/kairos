import std/[unittest, options]

import ../src/kairosbot/commands/registry

proc mkCmd(name: string, category = "general"): Command =
  Command(name: name, helpText: "aiuto " & name, cooldown: 1.0,
    maxAttemptsPerDay: 5, category: category)

suite "Registry":

  test "newCommandRegistry starts empty":
    let reg = newCommandRegistry()
    check reg.listAll().len == 0
    check reg.get("qualsiasi").isNone()

  test "register + get finds the command, case-insensitive":
    let reg = newCommandRegistry()
    let cmd = mkCmd("8ball")
    reg.register(cmd)

    let found = reg.get("8ball")
    check found.isSome()
    check found.get().name == "8ball"
    check found.get().helpText == "aiuto 8ball"
    check found.get().cooldown == 1.0
    check found.get().maxAttemptsPerDay == 5

    # case-insensitive
    check reg.get("8BALL").isSome()
    check reg.get("8Ball").get().name == "8ball"

  test "get for a nonexistent command returns none":
    let reg = newCommandRegistry()
    check reg.get("inesistente").isNone()
    check reg.get("").isNone()

  test "register with the same name overwrites":
    let reg = newCommandRegistry()
    reg.register(mkCmd("slots"))
    let new = Command(name: "SLOTS", helpText: "nuova help", cooldown: 2.0,
      maxAttemptsPerDay: 3, category: "games")
    reg.register(new)

    check reg.listAll().len == 1
    let found = reg.get("slots").get()
    check found.helpText == "nuova help"
    check found.cooldown == 2.0

  test "listAll returns the commands sorted by name":
    let reg = newCommandRegistry()
    for n in @["zeta", "alpha", "8ball", "M medio"]:
      reg.register(mkCmd(n))
    let all = reg.listAll()
    check all.len == 4
    check all[0].name == "8ball"
    check all[1].name == "alpha"
    check all[2].name == "M medio"   # uppercase sorted like lowercase
    check all[3].name == "zeta"

  test "listByCategory filters by category (case-insensitive) and sorts":
    let reg = newCommandRegistry()
    reg.register(mkCmd("zeta", "Games"))
    reg.register(mkCmd("alpha", "games"))
    reg.register(mkCmd("beta", "General"))
    reg.register(mkCmd("gamma", "GAMES"))

    let games = reg.listByCategory("games")
    check games.len == 3
    check games[0].name == "alpha"
    check games[1].name == "gamma"
    check games[2].name == "zeta"

    check reg.listByCategory("general").len == 1
    check reg.listByCategory("inexistente").len == 0

  test "listCategories returns the distinct categories sorted":
    let reg = newCommandRegistry()
    reg.register(mkCmd("alpha", "zeta_cat"))
    reg.register(mkCmd("beta", "alpha_cat"))
    reg.register(mkCmd("gamma", "zeta_cat"))
    reg.register(mkCmd("delta", "alpha_cat"))
    check reg.listCategories() == @["alpha_cat", "zeta_cat"]
