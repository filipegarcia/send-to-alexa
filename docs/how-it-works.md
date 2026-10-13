# How it works

Every request AlexaKit makes, in order. Hosts use the account's Amazon domain (`amazon.com`, `amazon.de`, ...).
Source of truth: `AlexaKit/Sources/AlexaKit/AmazonLogin.swift` and `AlexaClient.swift`.

## 1. Sign-in (once)

### 1a. Sign-in page

`AmazonLoginRequest` makes:

- `deviceSerial`: 16 random bytes as 32 upper-case hex chars.
- `clientId`: `hex(deviceSerial + "#A2IVLV5VM2W81")`. `A2IVLV5VM2W81` is the Alexa iOS app's device type.
- A PKCE `codeVerifier` (32 random bytes, base64url) and `codeChallenge = base64url(SHA256(verifier))`.
- The `frc` and `map-md` cookies the Alexa app sends with sign-in.

Then it opens:

```
https://www.amazon.com/ap/signin
  ?openid.return_to=https://www.amazon.com/ap/maplanding
  &openid.assoc_handle=amzn_dp_project_dee_ios        (_jp etc. for other identity domains)
  &openid.oa2.client_id=device:<clientId>
  &openid.oa2.response_type=code
  &openid.oa2.scope=device_auth_access
  &openid.oa2.code_challenge_method=S256
  &openid.oa2.code_challenge=<challenge>
  ... (standard OpenID 2.0 params)
```

Everyone signs in through `amazon.com` except Japan (`amazon.co.jp`), as the Alexa app does. The account's
real marketplace is detected afterwards.

When sign-in finishes, Amazon redirects to `/ap/maplanding?...&openid.oa2.authorization_code=<code>`.
The app's web view intercepts that navigation. The CLI asks you to paste the URL.

### 1b. Register a virtual device

```
POST https://api.amazon.com/auth/register
{
  "auth_data": { "client_id", "authorization_code", "code_verifier", "code_algorithm": "SHA-256", "client_domain": "DeviceLegacy" },
  "registration_data": { "device_type": "A2IVLV5VM2W81", "device_serial", "app_name": "Send to Alexa", ... },
  "requested_token_type": ["bearer", "mac_dms", "website_cookies"],
  "requested_extensions": ["device_info", "customer_info"],
  ...
}
→ response.success.tokens.bearer.refresh_token   ("Atnr|...")  ← the only long-lived secret
```

The device shows up in your Amazon account as "*‹First name›'s Send to Alexa*".

### 1c. Detect the marketplace

The refresh token is exchanged for cookies (see 2a), then:

```
GET https://alexa.amazon.com/api/users/me  → { "marketPlaceDomainName": "www.amazon.de", "marketPlaceLocale": "de-DE" }
```

If that fails, the country picked in the app (or `--region` in the CLI) is used.

## 2. Web session (on demand, cached 12 h)

### 2a. Refresh token → cookies

```
POST https://www.<marketplace>/ap/exchangetoken/cookies
  requested_token_type=auth_cookies&source_token_type=refresh_token&source_token=<refresh token>&domain=.<marketplace>&...
→ response.tokens.cookies[".<marketplace>"] = [{Name, Value}, ...]
```

### 2b. CSRF

Alexa's web API needs a `csrf` header that matches the `csrf` cookie. The cookie is set by
`GET https://alexa.<marketplace>/api/language` (with a few fallback pages).

All Alexa API calls send `Cookie`, `csrf`, `Referer: https://alexa.<marketplace>/spa/index.html` and
`Origin: https://alexa.<marketplace>`. A 401, a 403 or an HTML response means the session expired. The client
re-runs step 2 once and retries.

## 3. Devices

```
GET https://alexa.<marketplace>/api/devices-v2/device?cached=true
→ { "devices": [ { accountName, serialNumber, deviceType, deviceFamily, deviceOwnerCustomerId, online, capabilities } ] }
```

Music targets are devices with `AUDIO_PLAYER` / `AMAZON_MUSIC` capabilities, Fire TVs, and speaker groups
(`deviceFamily == "WHA"`). Alexa app instances (`VOX`) are excluded.

## 4. Play

### 4a. Validate

```
POST https://alexa.<marketplace>/api/behaviors/operation/validate
{ "type": "Alexa.Music.PlaySearchPhrase",
  "operationPayload": "{\"deviceType\":…,\"deviceSerialNumber\":…,\"customerId\":…,\"locale\":\"de-DE\",
                        \"musicProviderId\":\"APPLE_MUSIC\",\"searchPhrase\":\"Better Together by Jack Johnson\"}" }
→ { "result": "VALID", "operationPayload": { …, "sanitizedSearchPhrase": "better together by jack johnson" } }
```

### 4b. Run a one-off routine

```
POST https://alexa.<marketplace>/api/behaviors/preview
{ "behaviorId": "PREVIEW", "status": "ENABLED",
  "sequenceJson": "{\"@type\":\"com.amazon.alexa.behaviors.model.Sequence\",
                    \"startNode\":{\"@type\":\"com.amazon.alexa.behaviors.model.OpaquePayloadOperationNode\",
                                   \"type\":\"Alexa.Music.PlaySearchPhrase\",
                                   \"operationPayload\":{ …validated payload… }}}" }
```

`speak` works the same way with an `Alexa.Speak` node (`textToSpeak`).

## 5. Apple Music link → search phrase

`MusicLink.parse` understands `music.apple.com/{storefront}/{album|song|artist|playlist|station|music-video}/{slug}/{id}`.
The `?i=` track parameter turns an album link into a song. The resolver then tries, in order:

1. **iTunes Lookup API** (`https://itunes.apple.com/lookup?id=…&country=…`) for songs, albums and artists. This is public and needs no key.
2. **Page title** of the public web page for playlists and stations, e.g. `Today’s Hits - Playlist - Apple Music`.
3. **URL slug** as a last resort.

Titles are cleaned of things that confuse voice search, such as `(feat. …)`, `(Remastered 2011)` and `- Single`.
They're then phrased the way you'd say them: "Song by Artist", "the album X by Y", "the X playlist".

## Sign out

```
POST https://api.amazon.com/auth/token        (refresh token → access token)
POST https://api.amazon.com/auth/deregister   Authorization: Bearer … { "deregister_all_existing_accounts": false }
```

Only this virtual device is removed. Local Keychain or file data is then deleted.

## Keeping it working

If Amazon starts rejecting requests, first try bumping the app identity strings in `AlexaAppIdentity`
(`HTTP.swift`) to match the current alexa-cookie2 / alexa-remote-control releases.
