import std/[logging, os, times, dirs]

## Logger on console + file with manual daily rotation.
##
## `std/logging` does not do rotation: here we use one file per day
## (`logs/kairos-YYYY-MM-DD.log`) and at startup we delete the files older
## than a threshold (`cleanupOldLogs`).

var LogDir* = "logs"

const LogFilePrefix = "kairos-"

# Handlers registered by initLogger: used to replace them in case of
# re-initialization (e.g. in tests) without duplicating them.
var activeHandlers: seq[Logger] = @[]

proc getLogFilePath*(): string =
  ## Returns the log file path for the current date (UTC)
  result = LogDir / (LogFilePrefix & format(utc(now()), "yyyy-MM-dd") & ".log")

proc cleanupOldLogs*(maxDays: int = 14) =
  ## Removes log files whose date (in the name) is older than maxDays.
  ## Files whose name does not match the pattern are left untouched.
  if not dirExists(LogDir):
    return
  let cutoff = utc(now()) - days(maxDays)
  for kind, f in walkDir(LogDir):
    if kind != pcFile:
      continue
    let (_, base, ext) = splitFile(f)
    if ext != ".log" or base.len <= LogFilePrefix.len:
      continue
    let dateStr = base[LogFilePrefix.len .. ^1]
    try:
      let d = parse(dateStr, "yyyy-MM-dd", utc())
      if d < cutoff:
        removeFile(f)
    except CatchableError:
      discard   # name not in date format: it is not one of our logs

proc initLogger*(logLevel: Level = lvlInfo) =
  ## Initializes the logger on console and on file (`logs/kairos-YYYY-MM-DD.log`).
  ## Rotation is daily by file name; calling it again replaces
  ## the previous handlers.
  createDir(LogDir)
  for h in activeHandlers:
    removeHandler(h)
  activeHandlers = @[]
  setLogFilter(logLevel)
  let console = newConsoleLogger(logLevel, verboseFmtStr)
  let file = newFileLogger(getLogFilePath(), fmAppend, logLevel, verboseFmtStr)
  addHandler(console)
  addHandler(file)
  activeHandlers = @[console, file]
