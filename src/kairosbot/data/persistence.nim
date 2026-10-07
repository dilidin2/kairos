import std/[json, os, logging, asyncdispatch]

proc ensureDir*(path: string) =
  ## Ensures that the directory of the path exists
  let dir = path.parentDir
  if dir.len > 0:
    createDir(dir)

proc atomicWriteJson*(path: string, data: JsonNode) =
  ## Writes JSON to disk with an atomic write (temp file + rename)
  ensureDir(path)

  let tmpPath = path & ".tmp"
  let jsonString = data.pretty()
  try:
    writeFile(tmpPath, jsonString)
    moveFile(tmpPath, path)
  except IOError, OSError:
    if fileExists(tmpPath):
      removeFile(tmpPath)
    raise

proc loadJson*(path: string): JsonNode =
  ## Loads JSON from disk with a fallback to an empty object if the file is missing/malformed
  if not fileExists(path):
    debug "JSON file not found, returning empty object: ", path
    return newJObject()
  try:
    result = parseFile(path)
  except JsonParsingError, IOError, OSError, ValueError:
    warn "Failed to parse JSON ", path, ": ",
         getCurrentException().msg, " (falling back to empty object)"
    result = newJObject()

proc loadTyped*[T](path: string, default: T): T =
  ## Loads and deserializes JSON into a type T. Falls back to `default`
  ## if the file is missing or does not parse correctly.
  if not fileExists(path):
    debug "JSON file not found, using default: ", path
    return default
  try:
    result = parseFile(path).to(T)
  except CatchableError as e:
    warn "Failed to load typed JSON ", path, ": ", e.msg, " (using default)"
    result = default

proc saveTyped*[T](path: string, data: T) =
  ## Serializes the type T into a JsonNode and saves it atomically to disk
  atomicWriteJson(path, %data)

type
  DebouncedSaver* = ref object
    ## Debounced persistence: `schedule` postpones `save` by `delayMs` (a new
    ## schedule discards the pending save), `flush` invalidates the pending
    ## save and saves immediately (never waits for the delay).
    saveProc: proc () {.closure.}
    delayMs: int
    generation: int

proc newDebouncedSaver*(save: proc () {.closure.}, delayMs: int = 5000): DebouncedSaver =
  ## Creates a saver that runs `save` with a debounce of `delayMs`
  result = DebouncedSaver(saveProc: save, delayMs: delayMs)

proc runDebounced(s: DebouncedSaver, gen: int) {.async.} =
  await sleepAsync(s.delayMs)
  if gen == s.generation:
    s.saveProc()

proc schedule*(s: DebouncedSaver) =
  ## Schedules a debounced save (discards the previous pending save)
  inc s.generation
  asyncCheck s.runDebounced(s.generation)

proc flush*(s: DebouncedSaver) =
  ## Invalidates the pending debounce and saves immediately
  inc s.generation
  s.saveProc()
