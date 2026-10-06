import std/[tables, algorithm, options, strutils, sequtils]

type
  CommandRole* = enum
    crEveryone
    crMod
    crBroadcaster

  ## Definition (metadata) of a command. The handler proc does NOT live here:
  ## it is registered separately in the CommandRouter (table name -> handler),
  ## so this module stays free of dependencies on the router and plugins
  ## can import only the types.
  Command* = object
    name*: string
    helpText*: string
    cooldown*: float
    maxAttemptsPerDay*: int
    category*: string
    role*: CommandRole
    aliases*: seq[string]

  CommandRegistry* = ref object
    commands*: Table[string, Command]
    aliasToCanonical*: Table[string, string]

proc newCommandRegistry*(): CommandRegistry =
  ## Creates a new empty CommandRegistry
  result = CommandRegistry(
    commands: initTable[string, Command](),
    aliasToCanonical: initTable[string, string]()
  )

proc register*(registry: CommandRegistry, cmd: Command) =
  ## Registers a command (key = lowercase name; same name overwrites)
  let key = cmd.name.toLowerAscii()
  registry.commands[key] = cmd
  for alias in cmd.aliases:
    # toLower (Unicode, not toLowerAscii): aliases can contain
    # non-ASCII characters (e.g. "röst")
    registry.aliasToCanonical[alias.toLower()] = key

proc get*(registry: CommandRegistry, name: string): Option[Command] =
  ## Looks up a command by name or alias (case-insensitive)
  let key = name.toLowerAscii()
  if registry.commands.hasKey(key):
    return some(registry.commands[key])
  if registry.aliasToCanonical.hasKey(key.toLower()):
    let canonical = registry.aliasToCanonical[key.toLower()]
    if registry.commands.hasKey(canonical):
      return some(registry.commands[canonical])
  return none(Command)

proc listAll*(registry: CommandRegistry): seq[Command] =
  ## Returns all commands sorted by name
  for cmd in registry.commands.values:
    result.add(cmd)
  result = result.sortedByIt(it.name.toLowerAscii())

proc listCategories*(registry: CommandRegistry): seq[string] =
  ## All the distinct categories, sorted alphabetically (derived from the
  ## registered commands: new plugins appear here automatically)
  for cmd in registry.commands.values:
    result.add(cmd.category)
  result = result.deduplicate().sorted()

proc listByCategory*(registry: CommandRegistry, category: string): seq[Command] =
  ## Returns the commands of a category (case-insensitive), by name
  let cat = category.toLowerAscii()
  for cmd in registry.commands.values:
    if cmd.category.toLowerAscii() == cat:
      result.add(cmd)
  result = result.sortedByIt(it.name.toLowerAscii())
