import std/[asyncdispatch, strutils, json, httpclient, logging]

import ../config/config

## OpenAI-compatible client for the local LLM server (llama.cpp or
## a paid API endpoint). Same pattern as helix.nim:
## AsyncHttpClient, never exceptions towards the outside.

type
  LlmMessage* = object
    role*: string
    content*: string

  LlmClient* = ref object
    baseUrl*: string
    model*: string
    apiKey*: string
    temperature*: float
    maxTokens*: int

proc newLlmClient*(cfg: LlmServerConfig): LlmClient =
  ## Creates the OpenAI-compatible client from the config.
  ## It does not hold its own AsyncHttpClient: every chatCompletion creates
  ## a fresh one (see below) to avoid the shared connection pool.
  result = LlmClient(
    baseUrl: cfg.baseUrl,
    model: cfg.model,
    apiKey: cfg.apiKey,
    temperature: cfg.temperature,
    maxTokens: cfg.maxTokens
  )

proc chatCompletion*(c: LlmClient, messages: seq[LlmMessage]): Future[string] {.async.} =
  ## Chat-completions call. Returns the response content,
  ## "" on any failure (never exceptions).
  ##
  ## Each attempt creates a FRESH AsyncHttpClient: sharing a client
  ## (and its connection pool) between concurrent calls caused
  ## "Connection was closed before full request has been made" (e.g. the call
  ## to open a quest overlapping with another one's precheck).
  var body = newJObject()
  body["model"] = %*c.model
  body["temperature"] = %*c.temperature
  body["max_tokens"] = %*c.maxTokens
  var arr = newJArray()
  for m in messages:
    arr.add(%*m)
  body["messages"] = arr

  # Connection: close + Authorization only if there is a key (local servers: absent).
  var headerSeq: seq[tuple[key, val: string]] = @[]
  headerSeq.add(("Content-Type", "application/json"))
  headerSeq.add(("Connection", "close"))
  if c.apiKey.len > 0:
    headerSeq.add(("Authorization", "Bearer " & c.apiKey))
  let headers = newHttpHeaders(headerSeq)

  let url = c.baseUrl & "/chat/completions"
  const maxAttempts = 2
  for attempt in 0 ..< maxAttempts:
    debug "LLM: POST ", url, " — model=", c.model,
          " msgs=", $messages.len, " (attempt ", $attempt, ")"
    let client = newAsyncHttpClient()
    try:
      let resp = await client.request(url, HttpPost, $body, headers)
      let respBody = await resp.body
      debug "LLM: HTTP response ", $resp.code, " (", $respBody.len, " bytes)"
      if is2xx(resp.code):
        let node = parseJson(respBody)
        let content = node["choices"][0]["message"]["content"].getStr
        if content.len == 0:
          warn "LLM: 2xx response with empty content: ",
               respBody.substr(0, min(respBody.len, 300))
        else:
          debug "LLM: content extracted (", $content.len, " chars): ", content
        result = content
        return
      else:
        warn "LLM: HTTP ", $resp.code, " — ",
             respBody.substr(0, min(respBody.len, 200))
        break  # HTTP response received (even an error): no point retrying
    except CatchableError as e:
      warn "LLM: error (attempt ", $attempt, "): ", e.msg
      # connection error → the next attempt uses a fresh client
    finally:
      client.close()
  result = ""
