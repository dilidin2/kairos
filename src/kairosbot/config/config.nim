import std/[json, tables, os]
import ../data/persistence

const TwitchClientId* = "tjnzi3fcugetb3ma04raaqqwu2st8o"

type
  LlmServerConfig* = object
    ## OpenAI-compatible client (llama.cpp, Ollama, OpenAI, Groq, ...).
    baseUrl*: string    ## Full URL with /v1, e.g. "http://localhost:8080/v1"
    model*: string      ## model name, e.g. "gpt-4o", "qwen", "local"
    apiKey*: string     ## API key (empty for local servers)
    temperature*: float
    maxTokens*: int
    isValid*: bool

  QuestSystemConfig* = object
    enabled*: bool
    periodicQuestCall*: int    ## minutes between one assignment and the next
    llmActive*: bool           ## if false, simple quests only (fallback)

  PeerBusConfig* = object
    ## Inter-bot HTTP bus: local API (info/state/events) + peer registry
    host*: string
    port*: int
    kind*: string
    peers*: Table[string, string]

  BotConfig* = object
    botName*: string
    channel*: string
    commandPrefix*: string
    cooldownDefault*: float
    botLanguage*: string
    llmServer*: LlmServerConfig
    questSystem*: QuestSystemConfig
    peerBus*: PeerBusConfig
    messages*: Table[string, string]
    ## Translatable user-facing chat texts from messages.json

proc parseLlmServerConfig*(node: JsonNode): LlmServerConfig =
  ## Parses an LlmServerConfig from a JSON node.
  ## OpenAI-compatible format: base_url, model, api_key, temperature,
  ## max_tokens. Backwards compatible with the legacy host+port format
  ## (builds base_url = http://host:port/v1).
  var baseUrl: string = ""
  if node.hasKey("base_url"):
    baseUrl = getStr(node["base_url"])
  else:
    var host: string = ""
    var port: int = 0
    if node.hasKey("host"): host = getStr(node["host"])
    if node.hasKey("port"): port = getInt(node["port"])
    if host.len > 0 and port > 0:
      baseUrl = "http://" & host & ":" & $port & "/v1"
    else:
      echo "llm_server: base_url (or host+port) not set!"

  var model: string = "local"
  if node.hasKey("model"): model = getStr(node["model"])

  var apiKey: string = ""
  if node.hasKey("api_key"): apiKey = getStr(node["api_key"])

  var temperature: float = 0.6
  if node.hasKey("temperature"): temperature = getFloat(node["temperature"])

  var maxTokens: int = 1000
  if node.hasKey("max_tokens"): maxTokens = getInt(node["max_tokens"])

  result = LlmServerConfig(
    baseUrl: baseUrl, model: model, apiKey: apiKey,
    temperature: temperature, maxTokens: maxTokens,
    isValid: baseUrl.len > 0)



proc parseQuestSystemConfig*(node: JsonNode): QuestSystemConfig =
  ## Parses a QuestSystemConfig from a JSON node
  var enabled: bool = false
  var periodicQuestCall: int = 10
  var llmActive: bool = true

  if node.hasKey("enabled"): enabled = getBool(node["enabled"])
  if node.hasKey("periodic_quest_call"): periodicQuestCall = getInt(node["periodic_quest_call"])
  if node.hasKey("llm_active"): llmActive = getBool(node["llm_active"])

  result = QuestSystemConfig(enabled: enabled, periodicQuestCall: periodicQuestCall, llmActive: llmActive)


proc parsePeerBusConfig*(node: JsonNode): PeerBusConfig =
  ## Parses a PeerBusConfig from a JSON node (optional sub-fields with defaults)
  result = PeerBusConfig(
    host: "127.0.0.1",
    port: 8310,
    kind: "games",
    peers: initTable[string, string]()
  )

  if node.hasKey("host"): result.host = node["host"].getStr
  if node.hasKey("port"): result.port = node["port"].getInt
  if node.hasKey("kind"): result.kind = node["kind"].getStr
  if node.hasKey("peers") and node["peers"].kind == JObject:
    for k, v in node["peers"].pairs:
      result.peers[k] = v.getStr


proc loadMessages(dir: string): Table[string, string] =
  ## Loads messages.json (flat key -> template pairs) from the config
  ## directory; empty table if missing or malformed (the callers fall
  ## back to the English defaults)
  result = initTable[string, string]()
  let path = dir / "messages.json"
  if not fileExists(path):
    return
  let node = loadJson(path)
  if node.kind != JObject:
    return
  for key, value in node.pairs:
    if value.kind == JString:
      result[key] = value.getStr

proc loadConfig*(path: string = "config/bot_config.json"): BotConfig =
  ## Loads and validates the configuration from bot_config.json
  ## (only the truly global: each plugin carries its own commands)
  let json = loadJson(path)

  const needed = ["bot_name", "channel", "command_prefix", "cooldown_default", "llm_server", "quest_system", "peerbus"]

  for key in needed:
    if not json.hasKey(key):
      quit("Error in the json config!: " & key)

  let llmConfig = parseLlmServerConfig(json["llm_server"])

  var questConfig = parseQuestSystemConfig(json["quest_system"])

  questConfig.enabled = questConfig.enabled and llmConfig.isValid

  var botLanguage: string = "en"
  if json.hasKey("bot_language"): botLanguage = getStr(json["bot_language"])

  result = BotConfig(
    botName: getStr(json["bot_name"]),
    channel: getStr(json["channel"]),
    commandPrefix: getStr(json["command_prefix"]),
    cooldownDefault: getFloat(json["cooldown_default"]),
    botLanguage: botLanguage,
    llmServer: llmConfig,
    questSystem: questConfig,
    peerBus: parsePeerBusConfig(json["peerbus"]),
    messages: loadMessages(path.parentDir))
