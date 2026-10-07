import std/[random, strutils]

## Small shared helpers

proc randElem*[T](list: openArray[T]): T =
  ## A random element of a non-empty list
  result = list[rand(list.len - 1)]

proc normUser*(user: string): string =
  ## Normalizes a username (lowercase)
  result = user.toLowerAscii()
