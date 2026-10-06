import std/[strutils, asyncdispatch]

import ../twitch/chat

const MaxMessageLength* = 480

## Pause between one chunk and the next (ms): bursts of close-together
## messages can trigger the Helix rate limits (429).
var ChunkDelayMs* = 500

proc trimToWordBoundary*(text: string, maxLength: int): string =
  ## Cuts the text at the nearest word break before
  ## maxLength. If there is no space before the limit (a very long word),
  ## it hard-cuts at maxLength.
  if text.len <= maxLength:
    return text
  let idx = text.rfind(' ', 1, maxLength - 1)
  if idx > 0:
    result = text[0 .. idx - 1].strip(leading = false)
  else:
    result = text[0 .. maxLength - 1]

proc splitMessage*(text: string): seq[string] =
  ## Splits a message into chunks of at most MaxMessageLength.
  ## Under the limit the text goes through whole (newlines included); over it,
  ## it is first split by newline (empty lines discarded) and the lines are
  ## packed back into chunks that stay under the limit; a single line that
  ## exceeds the limit is cut at a word break.
  if text.len <= MaxMessageLength:
    if text.strip().len > 0:
      result.add(text)
    return

  var chunk = ""
  for line in text.split('\n'):
    let line = line.strip()
    if line.len == 0:
      continue
    var piece = line
    while piece.len > MaxMessageLength:
      if chunk.len > 0:
        result.add(chunk)
        chunk = ""
      let cut = trimToWordBoundary(piece, MaxMessageLength)
      result.add(cut)
      piece = piece[cut.len .. ^1].strip(trailing = false)
    let candidate =
      if chunk.len == 0: piece else: chunk & "\n" & piece
    if candidate.len <= MaxMessageLength:
      chunk = candidate
    else:
      if chunk.len > 0:
        result.add(chunk)
      chunk = piece
  if chunk.len > 0:
    result.add(chunk)

proc safeSend*(chat: TwitchChat, text: string) {.async.} =
  ## Sends text to chat, splitting it into chunks under MaxMessageLength if
  ## necessary, with a short pause between one chunk and the next.
  let chunks = splitMessage(text)
  for i, chunk in chunks:
    await chat.sendMessage(chunk)
    if i < chunks.len - 1:
      await sleepAsync(ChunkDelayMs)
