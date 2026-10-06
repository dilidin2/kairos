import std/[asyncdispatch, times]

type
  WindowExpireHandler* = proc () {.async.}

  WindowGuard* = ref object
    ## Channel guard: only one timed mini-game at a time.
    activeName*: string
    deadline*: float
    stopping*: bool

proc newWindowGuard*(): WindowGuard =
  ## Creates a new WindowGuard (no active window)
  result = WindowGuard()

proc isActive*(g: WindowGuard): bool =
  ## True if a window is in progress
  result = g.activeName.len > 0

proc remaining*(g: WindowGuard): float =
  ## Seconds remaining of the active window (0 if not active)
  if g.isActive():
    result = max(0.0, g.deadline - epochTime())
  else:
    result = 0.0

proc tryBegin*(g: WindowGuard, name: string, seconds: int,
               onExpire: WindowExpireHandler): bool =
  ## Tries to acquire the channel window. Returns false if one
  ## is already running (immediate rejection, no queue). On expiry the core
  ## releases the window and calls onExpire.
  if g.isActive():
    return false

  g.activeName = name
  g.deadline = epochTime() + float(seconds)

  proc expireTask() {.async.} =
    await sleepAsync(seconds * 1000)
    # releases only if it is still THE SAME window (an endWindow or a
    # new tryBegin may have already replaced/closed it)
    if not g.stopping and g.activeName == name and g.deadline > 0.0:
      g.activeName = ""
      g.deadline = 0.0
      # release the guard BEFORE onExpire: a new mini-game can
      # start while the end-of-window list is being published
      asyncCheck onExpire()

  # the task starts immediately (not awaited): the guard stays free to
  # release the window before the deadline
  let f = expireTask()
  discard f
  result = true

proc release*(g: WindowGuard, name: string) =
  ## Closes the window `name` early (e.g. quiz won: the core
  ## releases immediately, the pending expire task is never invoked)
  if g.activeName == name:
    g.activeName = ""
    g.deadline = 0.0

proc stop*(g: WindowGuard) =
  ## Stops the guard (shutdown): no window stays active
  g.stopping = true
  g.activeName = ""
  g.deadline = 0.0
