import std/[asyncdispatch, httpclient, json, times, strutils, uri, options, os, logging]
import std/collections/sequtils

import ../config/config
import ../data/persistence
import helix

type
  TokenKind* = enum
    tkBroadcaster
    tkBot

  TokenSet* = ref object
    accessToken*: string
    refreshToken*: string
    expiresAt*: float   # absolute (epoch) timestamp of the expiry
    scope*: seq[string]
    userLogin*: string
    userId*: string

  OAuthError* = object of CatchableError
    ## Error from the Twitch OAuth endpoints (device/token)
    code*: int          # status HTTP
    errorCode*: string  # valore del campo "error" nella risposta

  OAuthPendingError* = object of CatchableError
    ## `authorization_pending`: the user has not confirmed yet
  OAuthSlowDownError* = object of CatchableError
    ## `slow_down`: increase the polling interval

const
  ## Safety margin: the token is considered expired 60s early
  TokenExpiryMarginSec* = 60.0

var
  ## `var` (not `const`) so tests can redirect these
  DataDir* = "data"
  TwitchOAuthDeviceUrl* = "https://id.twitch.tv/oauth2/device"
  TwitchOAuthTokenUrl* = "https://id.twitch.tv/oauth2/token"

# --- Token persistence ---------------------------------------------------------

proc tokenPath*(kind: TokenKind): string =
  ## Returns the token file path for the given kind
  let name =
    if kind == tkBroadcaster: "broadcaster_token.json"
    else: "bot_token.json"
  result = DataDir / name

proc loadToken*(kind: TokenKind): Option[TokenSet] =
  ## Loads the token from the file if it exists and is valid
  let node = loadJson(tokenPath(kind))
  if node.hasKey("access_token") and node["access_token"].kind == JString:
    result = some(TokenSet(
      accessToken: node["access_token"].getStr,
      refreshToken: node["refresh_token"].getStr,
      expiresAt: node["expires_at"].getFloat,
      scope: (if node.hasKey("scope"): node["scope"].to(seq[string]) else: @[]),
      userLogin: node["user_login"].getStr,
      userId: node["user_id"].getStr
    ))
  else:
    result = none(TokenSet)

proc saveToken*(kind: TokenKind, token: TokenSet) =
  ## Saves the token to the file (atomic write)
  let node = %*{
    "access_token": token.accessToken,
    "refresh_token": token.refreshToken,
    "expires_at": token.expiresAt,
    "scope": %token.scope,
    "user_login": token.userLogin,
    "user_id": token.userId
  }
  atomicWriteJson(tokenPath(kind), node)

proc isTokenExpired*(token: TokenSet): bool =
  ## Checks whether the token is expired (with a safety margin)
  result = epochTime() >= token.expiresAt - TokenExpiryMarginSec

proc tokenKindToString*(kind: TokenKind): string =
  ## Converts TokenKind to a string for user messages
  result =
    if kind == tkBroadcaster: "broadcaster"
    else: "bot"

# --- OAuth calls ----------------------------------------------------------------

proc postOAuth*(url: string, params: seq[(string, string)]): Future[JsonNode] {.async.} =
  ## Form-encoded POST to the Twitch OAuth endpoints.
  ## On 2xx returns the JSON; on any other status raises OAuthError
  ## with the "error" field of the response (if present).
  ## `params` is a `seq` (not openArray): in Nim 2 openArrays cannot
  ## be captured by the closure of an async proc.
  let body = encodeQuery(params)

  let client = newAsyncHttpClient()
  defer: client.close()

  var headers = newHttpHeaders()
  headers.add("Content-Type", "application/x-www-form-urlencoded")
  headers.add("Accept", "application/json")

  let resp = await client.request(url, HttpPost, body, headers)
  let respBody = await resp.body

  if is2xx(resp.code):
    result = parseJson(respBody)
  else:
    var errorCode = ""
    if respBody.len > 0:
      try:
        let errNode = parseJson(respBody)
        # Twitch uses "error" in the device flow and "message" in the other
        # endpoints: in Nim 2, ["key"] on a missing key raises
        # KeyError, so it must be guarded with hasKey
        if errNode.hasKey("error"):
          errorCode = errNode["error"].getStr
        if errorCode.len == 0 and errNode.hasKey("message"):
          errorCode = errNode["message"].getStr
      except CatchableError:
        discard
    var e = newException(OAuthError, "OAuth HTTP " & $resp.code & ": " & respBody)
    e.code = int(resp.code)
    e.errorCode = errorCode
    raise e

proc requestDeviceCode*(client_id: string, scopes: seq[string]): Future[JsonNode] {.async.} =
  ## Requests a device code from Twitch (POST /oauth2/device)
  result = await postOAuth(TwitchOAuthDeviceUrl, @[
    ("client_id", client_id),
    ("scopes", scopes.join(" "))
  ])

proc pollToken*(client_id: string, deviceCode: string): Future[JsonNode] {.async.} =
  ## Single token polling attempt (POST /oauth2/token).
  ## - success                 → JsonNode of the token
  ## - authorization_pending   → OAuthPendingError (continue)
  ## - slow_down               → OAuthSlowDownError (the caller increases the interval)
  ## - other error             → OAuthError (stop)
  try:
    result = await postOAuth(TwitchOAuthTokenUrl, @[
      ("client_id", client_id),
      ("device_code", deviceCode),
      ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")
    ])
  except OAuthError as e:
    if e.errorCode == "authorization_pending":
      raise newException(OAuthPendingError, "Waiting for the user to confirm")
    elif e.errorCode == "slow_down":
      raise newException(OAuthSlowDownError, "Twitch asks to slow down the polling")
    else:
      raise

proc parseTokenResponse*(node: JsonNode, old: TokenSet = nil): TokenSet =
  ## Builds a TokenSet from the /oauth2/token response.
  ## `expiresAt` is always an absolute timestamp (now + expires_in).
  ## Missing fields (refresh_token, scope) are inherited from `old`.
  result = TokenSet(
    accessToken: node["access_token"].getStr,
    refreshToken:
      if node.hasKey("refresh_token") and node["refresh_token"].kind == JString:
        node["refresh_token"].getStr
      elif old != nil: old.refreshToken
      else: "",
    expiresAt: epochTime() + node["expires_in"].getFloat,
    scope:
      if node.hasKey("scope") and node["scope"].kind == JString:
        node["scope"].getStr.split(' ').filterIt(it.len > 0)
      elif old != nil: old.scope
      else: @[],
    userLogin: (if old != nil: old.userLogin else: ""),
    userId: (if old != nil: old.userId else: "")
  )

proc refreshToken*(token: TokenSet): Future[TokenSet] {.async.} =
  ## Renews the token with grant_type=refresh_token (public client,
  ## no client secret). The refresh token of the Device Code Flow is
  ## single-use: the response contains the new one, to be re-saved right
  ## away by the caller. Raises OAuthError on failure.
  let resp = await postOAuth(TwitchOAuthTokenUrl, @[
    ("client_id", TwitchClientId),
    ("refresh_token", token.refreshToken),
    ("grant_type", "refresh_token")
  ])
  result = parseTokenResponse(resp, token)

proc resolveUser*(accessToken: string): Future[(string, string)] {.async.} =
  ## Resolves (user_login, user_id) of the token via Helix GET /users
  let u = await getSelfUser(accessToken)
  result = (u.login, u.id)

# --- Complete flows ---------------------------------------------------------------

proc runDeviceCodeFlow*(client_id: string, scopes: seq[string]): Future[TokenSet] {.async.} =
  ## Runs the complete Device Code Flow: device code request,
  ## displaying the instructions, polling until confirmation
  ## (or expiry), resolving the user.
  let dev = await requestDeviceCode(client_id, scopes)
  let deviceCode = dev["device_code"].getStr
  let userCode = dev["user_code"].getStr
  let verifUri = dev["verification_uri"].getStr
  let expiresIn = dev["expires_in"].getInt
  var interval = dev["interval"].getInt

  echo ""
  echo "=== Twitch authentication (Device Code Flow) ==="
  echo "Open the link: " & verifUri
  echo "or go to https://www.twitch.tv/activate and enter the code: " & userCode
  echo "Waiting for confirmation (expires in " & $expiresIn & " seconds)..."
  echo ""

  let deadline = epochTime() + float(expiresIn)
  while true:
    if epochTime() >= deadline:
      raise newException(OAuthError, "Device code expired before confirmation")
    await sleepAsync(interval * 1000)
    try:
      let resp = await pollToken(client_id, deviceCode)
      var t = parseTokenResponse(resp)
      let (login, uid) = await resolveUser(t.accessToken)
      t.userLogin = login
      t.userId = uid
      return t
    except OAuthPendingError:
      discard   # the user has not confirmed yet: continue
    except OAuthSlowDownError:
      interval += 5   # slow down the polling as requested by Twitch

proc authenticate*(kind: TokenKind, scopes: seq[string]): Future[TokenSet] {.async.} =
  ## Complete authentication flow:
  ## 1. if the token file exists and is not expired → return it
  ## 2. if it is expired → try the refresh (and re-save, single-use refresh token)
  ## 3. if it is missing or the refresh fails → Device Code Flow from the start
  let path = tokenPath(kind)
  if fileExists(path):
    let opt = loadToken(kind)
    if opt.isSome:
      let t = opt.get()
      if not isTokenExpired(t):
        return t
      info tokenKindToString(kind) & " token expired, attempting the refresh"
      try:
        let newT = await refreshToken(t)
        saveToken(kind, newT)
        return newT
      except CatchableError as e:
        warn "Refresh failed for " & tokenKindToString(kind) & ": " & e.msg

  # No valid token: Device Code Flow from the start
  let t = await runDeviceCodeFlow(TwitchClientId, scopes)
  saveToken(kind, t)
  return t
