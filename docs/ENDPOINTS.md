# LibreChat endpoints (confirmed as we go)

Rules: pace requests (>= a few seconds apart), send a real browser-like User-Agent.
Nothing here is confirmed until it has a "verified" date.

| Endpoint | Method | Purpose | Verified |
|---|---|---|---|
| /api/auth/login | POST | email+password -> token + refresh cookie | **2026-07-18** |
| /api/auth/refresh | POST | new access token from the refresh cookie | wired (Phase 1), live-confirm pending |
| /api/convos | GET | conversation list, cursor-paginated | **2026-07-19** |
| /api/messages/:conversationId | GET | full message history for one conversation | **2026-07-19** |
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

## GET /api/convos — verified 2026-07-19

Request: `GET /api/convos` (first page) or `GET /api/convos?cursor=<nextCursor>`
(subsequent pages — confirmed live, page 2 returned genuinely older conversations).
Requires `Authorization: Bearer <token>`.

Response `200`:

```jsonc
{
  "conversations": [
    {
      "_id": "...", "conversationId": "e36b7124-...",  // use conversationId, not _id
      "user": "...", "agent_id": "agent_...", "chatProjectId": null,
      "endpoint": "agents",
      "title": "Voice chat with Kiana — Jul 18, 2026, 7:13 PM",
      "createdAt": "2026-07-19T00:13:29.473Z",
      "updatedAt": "2026-07-19T00:13:42.064Z"
    }
    // ... 25 per page in testing
  ],
  "nextCursor": "eyJwcmltYXJ5Ijoi..."   // opaque; pass back as ?cursor= for the next page
}
```

`title` was populated on all 25 conversations sampled (some generic like "New
Chat", but never empty) — the client still falls back to "Untitled
conversation" defensively since that's a live API guarantee, not a schema one.

## GET /api/messages/:conversationId — verified 2026-07-19

Requires `Authorization: Bearer <token>`. Returns a flat JSON array, NOT
wrapped in an object. Verified against a real 8-message thread: array order
matched both `createdAt` ascending AND the `parentMessageId` chain, so the
client renders array order directly with no client-side sort — known
simplification: a conversation with branching/regenerated replies would need
`parentMessageId`-based tree reconstruction to show the exact active branch;
this reads as the straight chronological line instead.

```jsonc
[
  {
    "messageId": "...", "conversationId": "...",
    "parentMessageId": "...", "createdAt": "...",
    "isCreatedByUser": true, "sender": "User",
    "text": "the actual message text"          // user messages: text is populated directly
  },
  {
    "messageId": "...", "conversationId": "...",
    "parentMessageId": "...", "createdAt": "...",
    "isCreatedByUser": false, "sender": "Forge", // sender = the agent's display name
    "text": "",                                  // often EMPTY on assistant messages —
    "content": [                                 // the real content lives here instead
      { "type": "text", "think": "..." },        // NOTE: think blocks key is "think", not "text"
      { "type": "tool_call", "tool_call": {...} },
      { "type": "text", "text": "the actual reply text" }
    ],
    "metadata": { "usage": { "cost": 1.9, ... } }
  }
]
```

Client rule (`KadeMessage.displayText` in `ConversationsService.swift`): join
`content` blocks where `type == "text"` using their `text` field; fall back to
the top-level `text` field; if an assistant message has neither (pure tool
activity), show "(No text in this reply — it looks like tool activity only.)"
rather than a silent empty bubble — a blind VoiceOver user has no other way to
tell "genuinely nothing" apart from "this loaded wrong."

## Client notes

- Access token + cached user are stored in the **Keychain**
  (`Sources/Keychain.swift`, service `com.kademurdock.kadeai.native`).
- The refresh cookie lives in `HTTPCookieStorage.shared` (persists across launches).
- **All requests — auth AND data — go through one shared `KadeAPIClient`**
  (`Sources/KadeAPIClient.swift`): one `URLSession`, one iPhone-Safari UA, one
  pacing clock (>= 1.5s between any two requests). This was a deliberate fix
  during Phase 2: AuthService originally paced its own requests independently,
  and a second independently-paced service could have fired a request within
  the same instant AuthService did (e.g. launch-time refresh racing a
  conversation-list fetch) — individually paced, but not paced against each
  other. One shared clock closes that gap.
- Query strings go through `URLComponents` (`KadeAPIClient.request(queryItems:)`),
  never hand-concatenated onto the path — `URL.appendingPathComponent` percent-
  encodes `?`/`=`/`&`, so a literal `"api/convos?cursor=xyz"` path string would
  silently become a broken URL instead of a real query string.
