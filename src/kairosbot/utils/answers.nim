import std/strutils

## Matching of user answers against an expected answer with variants
## (shared by the timed trivia games: quiz and quotes)

proc normAnswer*(s: string): string =
  ## Normalizes an answer: lowercase, trim, multiple spaces collapsed
  result = s.toLowerAscii().strip()
  while "  " in result:
    result = result.replace("  ", " ")

proc answerMatches*(answer: string, variants: seq[string], resp: string): bool =
  ## The (normalized) response matches the correct answer or a variant
  let n = normAnswer(resp)
  if n == normAnswer(answer):
    return true
  for v in variants:
    if n == normAnswer(v):
      return true
