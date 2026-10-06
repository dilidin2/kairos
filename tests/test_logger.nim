import std/[unittest, os, strutils, times, logging, syncio]

import ../src/kairosbot/utils/logger

var
  tmpDir: string
  tmpCounter: int

proc setUp() =
  tmpCounter += 1
  tmpDir = getTempDir() / ("kairos_logger_test_" & $tmpCounter)
  createDir(tmpDir)
  LogDir = tmpDir

proc tearDown() =
  # removes all log handlers (in the test process they are the module's ones)
  for h in getHandlers():
    removeHandler(h)
  if tmpDir != "":
    try:
      removeDir(tmpDir)   # recursive in Nim 2
    except IOError:
      discard
  tmpDir = ""

proc readLog(): string =
  let p = getLogFilePath()
  if fileExists(p):
    result = readFile(p)

suite "Logger":

  test "getLogFilePath uses the kairos-YYYY-MM-DD.log format":
    setUp()
    let expected = tmpDir / ("kairos-" & format(utc(now()), "yyyy-MM-dd") & ".log")
    check getLogFilePath() == expected
    tearDown()

  test "initLogger creates the directory and file and writes logs to it":
    setUp()
    initLogger(lvlInfo)
    check dirExists(tmpDir)
    check fileExists(getLogFilePath())
    info "hello-test-xyz"
    let content = readLog()
    check content.contains("hello-test-xyz")
    check content.contains("[20")   # timestamp in verbose format
    tearDown()

  test "repeated initLogger does not duplicate the handlers":
    setUp()
    initLogger(lvlInfo)
    let n1 = getHandlers().len
    initLogger(lvlInfo)
    check getHandlers().len == n1
    initLogger(lvlInfo)
    check getHandlers().len == n1
    tearDown()

  test "messages below the configured level are not written":
    setUp()
    initLogger(lvlWarn)
    info "non-deve-comparire"
    warn "deve-comparire"
    let content = readLog()
    check not content.contains("non-deve-comparire")
    check content.contains("deve-comparire")
    tearDown()

  test "cleanupOldLogs deletes old files and keeps recent ones":
    setUp()
    # old file (2020), today's file, file with an invalid date, foreign file
    writeFile(tmpDir / "kairos-2020-01-01.log", "vecchio")
    writeFile(getLogFilePath(), "oggi")
    writeFile(tmpDir / "kairos-2020-13-45.log", "data-finta")
    writeFile(tmpDir / "random.log", "estraneo")

    cleanupOldLogs(14)

    check not fileExists(tmpDir / "kairos-2020-01-01.log")
    check fileExists(getLogFilePath())
    check fileExists(tmpDir / "kairos-2020-13-45.log")  # invalid date: untouched
    check fileExists(tmpDir / "random.log")            # not one of our logs

  test "cleanupOldLogs without a directory does not crash":
    setUp()
    removeDir(tmpDir)
    cleanupOldLogs(14)   # it just must not raise
    tmpDir = ""
