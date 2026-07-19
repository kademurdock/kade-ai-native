# LibreChat endpoints (confirmed as we go)

Rules: pace requests (>= a few seconds apart), send a real browser-like User-Agent.
Nothing here is confirmed until it has a "verified" date.

| Endpoint | Method | Purpose | Verified |
|---|---|---|---|
| /api/auth/login | POST | email+password -> token + refresh cookie | **2026-07-18** |
| /api/auth/refresh | POST | new access token from the refresh cookie | wired (Phase 1), live-confirm pending |
| /api/convos | GET | conversation list | not yet |
| /api/agents | GET | agents list | not yet |
| (SSE send) | POST | send message, stream reply | not yet |

## POST /api/auth/login — verified 2026-07-18

Request:

```
POST https://kademurdock.com/api/auth/login
Content-Type: application/json
User-Agent: <real iPhone Safari UA>   # bare "Mozilla/5.0" trips NON_BROWSER on some routes
Accept: application/json
Origin: https://kademurdock.com

{ "email": "...", "password": "..." }
```

Response `200`:

```jsonc
{
  "token": "<access JWT>",            // short-lived; send as Bearer on API calls
  "user": {
    "_id": "...", "id": "...",        // same value, both present
    "name": "...", "username": "...",
    "email": "...", "role": "...",
    "emailVerified": true, "provider": "...",
    "avatar": null, "twoFactorEnabled": false,
    "termsAccepted": true,
    "personalization": { "memories": true, "_id": "..." },
    "createdAt": "...", "updatedAt": "..."
  }
}
```

Refresh delivered as httpOnly cookies (NOT in the body), so the native client
never handles them by hand — `URLSession` persists them:

```
set-cookie: refreshToken=<jwt>;    Path=/; HttpOnly; Secure; SameSite=Strict; Expires=+~80d
set-cookie: token_provider=<jwt>;  Path=/; HttpOnly; Secure; SameSite=Strict; Expires=+~80d
```

Bad credentials return a non-200 (treated as 401/403/422 -> "email or password
didn't work"). 429 -> rate-limited message. Anything else -> generic server error.

## POST /api/auth/refresh — wired, live-confirm pending

Sends no body; relies on the stored `refreshToken` cookie. Expected to return the
same `{ token, user }` shape as login. The app calls it once at launch (silent,
fail-soft: network error keeps the cached session; only a real 401 signs out).
Mark "verified" once observed live on a relaunch.

## Client notes

- Access token + cached user are stored in the **Keychain**
  (`Sources/Keychain.swift`, service `com.kademurdock.kadeai.native`).
- The refresh cookie lives in `HTTPCookieStorage.shared` (persists across launches).
- All auth requests go through one paced choke point (>= 1.5s apart) with the
  iPhone-Safari UA set on the `URLSession` — anti-abuse safe.
