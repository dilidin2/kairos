import std/[tables, asyncdispatch, json, os, strutils, algorithm]

import ../data/persistence
import ../plugin

## Virtual economy service: balances, wagers, transfers.
## Lives in the core (not in a plugin) because it is a **shared service**
## exposed via `ctx.services["economy"]` and consumed by multiple plugins
## (economy for !balance/!pay/!rich, games for !bet).

const
  DefaultBigWinner* = 50
  ## Default single-win threshold for the "Big Winner" trophy
  DefaultFirstTo* = 1000
  ## Default balance threshold for the "first to reach" trophy

type
  ## Inherits from Service (base of the shared services) so it can be
  ## stored in `ctx.services["economy"]` and cast by the consumer
  EconomyService* = ref object of Service
    balances*: Table[string, int]
    ## username (lowercase) -> balance
    maxWins*: Table[string, int]
    ## username (lowercase) -> largest single win
    firstToThousand*: string
    ## username of the first to reach 1000 🪙 ("" = nobody)
    startBalance*: int
    minBet*: int
    bigWinner*: int
    ## single-win threshold for the "Big Winner" trophy
    firstTo*: int
    ## balance threshold for the "first to reach" trophy
    dataPath*: string
    saver: DebouncedSaver

  EconomyData* = object
    balances*: Table[string, int]
    maxWins*: Table[string, int]
    firstToThousand*: string

proc saveEconomy*(svc: EconomyService) =
  ## Saves the economy state to the JSON file (atomic)
  let data = EconomyData(
    balances: svc.balances,
    maxWins: svc.maxWins,
    firstToThousand: svc.firstToThousand
  )
  saveTyped(svc.dataPath, data)

proc scheduleSave*(svc: EconomyService) =
  ## Schedules a debounced save (5s)
  svc.saver.schedule()

proc newEconomyService*(dataPath: string, startBalance: int = 100,
                        minBet: int = 1, bigWinner: int = DefaultBigWinner,
                        firstTo: int = DefaultFirstTo): EconomyService =
  ## Creates the service and loads the persistent state
  let default = EconomyData(
    balances: initTable[string, int](),
    maxWins: initTable[string, int](),
    firstToThousand: ""
  )
  let loaded = loadTyped[EconomyData](dataPath, default)
  var svc = EconomyService(
    balances: loaded.balances,
    maxWins: loaded.maxWins,
    firstToThousand: loaded.firstToThousand,
    startBalance: startBalance,
    minBet: minBet,
    bigWinner: bigWinner,
    firstTo: firstTo,
    dataPath: dataPath
  )
  svc.saver = newDebouncedSaver(proc () {.closure.} = saveEconomy(svc))
  result = svc

proc norm(user: string): string =
  ## Twitch usernames are case-insensitive: normalize to lowercase
  result = user.toLowerAscii()

proc getBalance*(svc: EconomyService, user: string): int =
  ## Balance of the user; a new user receives the starting balance
  let key = norm(user)
  if svc.balances.hasKey(key):
    result = svc.balances[key]
  else:
    svc.balances[key] = svc.startBalance
    svc.scheduleSave()
    result = svc.startBalance

proc canAfford*(svc: EconomyService, user: string, amount: int): bool =
  ## The user can afford `amount`
  result = svc.getBalance(user) >= amount

proc transfer*(svc: EconomyService, sender: string, receiver: string,
               amount: int): bool =
  ## Gives `amount` from `sender` to `receiver`. false if insufficient
  ## or if paying oneself
  let f = norm(sender)
  let t = norm(receiver)
  if f == t:
    return false
  if not svc.canAfford(f, amount):
    return false
  svc.balances[f] -= amount
  svc.balances[t] = svc.getBalance(t) + amount
  svc.scheduleSave()
  result = true

proc debit*(svc: EconomyService, user: string, amount: int): bool =
  ## Debits `amount` from the balance. false if insufficient
  let key = norm(user)
  if not svc.canAfford(key, amount):
    return false
  svc.balances[key] -= amount
  svc.scheduleSave()
  result = true

proc credit*(svc: EconomyService, user: string, amount: int) =
  ## Credits `amount` to the balance (assigns the starting balance if new)
  let key = norm(user)
  svc.balances[key] = svc.getBalance(key) + amount
  svc.scheduleSave()

proc applyWager*(svc: EconomyService, user: string, amount: int,
                 wonAmount: int): int =
  ## Debits the wager and credits the gross win.
  ## Updates the largest single win. Returns the amount won.
  let key = norm(user)
  let bal = svc.getBalance(key)
  svc.balances[key] = bal - amount + wonAmount
  if wonAmount > svc.maxWins.getOrDefault(key, 0):
    svc.maxWins[key] = wonAmount
  svc.scheduleSave()
  result = wonAmount

proc checkFirstTo*(svc: EconomyService, user: string): bool =
  ## true if `user` is (becomes) the first to reach the `firstTo` balance
  let key = norm(user)
  if svc.firstToThousand.len == 0 and svc.getBalance(key) >= svc.firstTo:
    svc.firstToThousand = key
    svc.scheduleSave()
    result = true

proc cmpBalanceDesc(a, b: (string, int)): int =
  ## Descending order by balance
  if a[1] > b[1]: return -1
  elif a[1] < b[1]: return 1
  else: return 0

proc topBalances*(svc: EconomyService, n: int): seq[(string, int)] =
  ## Top balances (username, balance) in descending order
  for k, v in svc.balances.pairs:
    result.add((k, v))
  result = result.sorted(cmpBalanceDesc)
  if result.len > n:
    result = result[0 ..< n]

proc forceSave*(svc: EconomyService) {.async.} =
  ## Saves immediately, ignoring the pending debounce (called at shutdown)
  svc.saver.flush()
