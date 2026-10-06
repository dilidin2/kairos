import std/[tables, strutils]

## In-memory ring buffer of the session's messages: username -> message_id.
## FIFO with a per-user cap and a global cap. Filled via ctx.onMessage,
## reset at startup (covers only "this live"). No persistence.

type
  MessageLog* = ref object
    perUser*: Table[string, seq[string]]
    ## username (lowercase) -> message_id in arrival order
    order*: seq[(string, string)]
    ## global order (user, id) to evict the oldest
    perUserCap*: int
    globalCap*: int

proc newMessageLog*(perUserCap: int = 500, globalCap: int = 20000): MessageLog =
  ## Creates a new empty log
  result = MessageLog(
    perUser: initTable[string, seq[string]](),
    order: @[],
    perUserCap: perUserCap,
    globalCap: globalCap
  )

proc add*(log: MessageLog, user: string, messageId: string) =
  ## Adds a message_id (FIFO, drops the oldest beyond the caps)
  if messageId.len == 0:
    return
  let u = user.toLowerAscii()
  if not log.perUser.hasKey(u):
    log.perUser[u] = @[]
  log.perUser[u].add(messageId)
  log.order.add((u, messageId))
  # per-user cap: drops the user's oldest
  if log.perUser[u].len > log.perUserCap:
    log.perUser[u].delete(0)
  # global cap: drops the oldest in arrival order
  while log.order.len > log.globalCap:
    let (ou, oid) = log.order[0]
    log.order.delete(0)
    if log.perUser.hasKey(ou):
      let idx = log.perUser[ou].find(oid)
      if idx >= 0:
        log.perUser[ou].delete(idx)

proc messagesOf*(log: MessageLog, user: string): seq[string] =
  ## The user's message_ids in arrival order
  let u = user.toLowerAscii()
  result = log.perUser.getOrDefault(u, @[])

proc clearUser*(log: MessageLog, user: string) =
  ## Empties the user's message_ids
  let u = user.toLowerAscii()
  if log.perUser.hasKey(u):
    log.perUser[u] = @[]

proc total*(log: MessageLog): int =
  ## Total number of tracked IDs
  result = log.order.len

proc reset*(log: MessageLog) =
  ## Resets the log (new session)
  log.perUser = initTable[string, seq[string]]()
  log.order = @[]
