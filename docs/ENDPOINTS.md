# LibreChat endpoints (confirmed as we go)

Rules: pace requests (>= a few seconds apart), send a real browser-like User-Agent.
Nothing here is confirmed until it has a "verified" date.

| Endpoint | Method | Purpose | Verified |
|---|---|---|---|
| /api/auth/login | POST | email+password -> token + refresh cookie | **2026-07-18** |
| /api/auth/refresh | POST | new access token from the refresh cookie | wired (Phase 1), live-confirm pending |
| /api/convos | GET | conversation list, cursor-paginated | **2026-07-19** |
| /api/messages/:conversationId | GET | full message history for one conversation | **2026-07-19** |
| /api/agents/chat/agents | POST | start a generation job, returns `{streamId, conversationId, status}` | **2026-07-19** |
| /api/agents/chat/stream/:streamId | GET | Server-Sent Events, ends in a `final` frame | **2026-07-19** |
| /api/agents/chat/abort | POST | abort an in-progress generation job | source-confirmed, not yet used by the app |
| /api/convos/ (DELETE) | DELETE | delete a conversation, body `{arg:{conversationId}}` | **2026-07-19** (used to clean up a test convo) |
| /api/agents | GET | agents list | not yet |

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
## POST /api/agents/chat/agents — verified 2026-07-19 (real send + stream test)

The fork's generation contract is two-phase, NOT a single POST-that-streams. Confirmed by
reading the live fork source (`api/server/routes/agents/{index,chat}.js`,
`api/server/controllers/agents/request.js`, `api/server/middleware/buildEndpointOption.js`)
AND by sending one real message through this account end-to-end.

Request:

```
POST https://kademurdock.com/api/agents/chat/agents
Authorization: Bearer <token>
Content-Type: application/json

{
  "text": "...",
  "messageId": "<client-minted UUID>",
  "parentMessageId": "<last real message's messageId, omit/absent for the first turn>",
  "conversationId": "<existing conversation id>",
  "endpoint": "agents",
  "agent_id": "agent_..."
}
```

Response `200` (arrives IMMEDIATELY — before generation finishes, not after):

```jsonc
{ "streamId": "...", "conversationId": "...", "status": "started" }
```

`streamId === conversationId`, always (confirmed in source: `const streamId = conversationId;`).

**Important — the client-minted `messageId` does NOT survive.** Sent
`3bc46269-7604-40e4-b3fd-54bcd53b8711` in a live test; the persisted user message came back with
`messageId: "78c29a94-8812-4d37-a558-16f5a51fb483"` — a completely different, server-assigned id.
Don't try to reconcile this by hand — just refetch `GET /api/messages/:conversationId` once the
turn is done and take whatever it says as authoritative (see `MessageSendingService.swift`'s type
doc for how the client handles this).

**The "no parent" sentinel is the all-zero UUID**, not `null`: a fresh conversation's first
message came back with `"parentMessageId": "00000000-0000-0000-0000-000000000000"` even though the
client sent `parentMessageId: null`.

`agent_id` is read via `parseCompactConvo` / `compactAgentsSchema`
(`packages/data-provider/src/schemas.ts`) — this is the field that selects which agent answers.
Everything else in the fork's internal `endpointOption` is server-computed from this and ignores
whatever the client sends for it, so the client never needs to build or send an `endpointOption`
object itself.

## GET /api/agents/chat/stream/:streamId — verified 2026-07-19

```
GET https://kademurdock.com/api/agents/chat/stream/<streamId>
Authorization: Bearer <token>
Accept: text/event-stream
```

Server-Sent Events, one JSON object per `data:` line. The ones this app's `MessageSendingService`
actually watches for:

- `{"final": true, ...}` — the turn is done. Also carries `conversation`, `title`,
  `requestMessage`, and `responseMessage` (confirmed by reading the exact object construction in
  `request.js`), but this app does not decode any of that — see below for why.
- `event: error` / `data: {"error": "...", ...}` — a real failure; `.error` (or `.message`) is a
  human-readable string worth showing.
- Everything else (`created`, `sync`, per-token deltas, tool-call/reasoning step events,
  attachment/title/usage bookkeeping) is deliberately ignored for v1 — see "Client notes" below.

**Real operational gotcha, hit live:** opening the GET a few seconds after the POST returned
`{"error":"Stream not found","message":"The generation job does not exist or has expired."}`
(HTTP 404) — the reply was short enough that the job finished and cleaned itself up before the
GET connected. This is not a bug to retry around; it means the turn already completed. The client
treats a 404 here exactly like a `final` frame: stop waiting, go refetch messages.

## POST /api/agents/chat/abort — source-confirmed 2026-07-19, not yet wired into the app

`POST /api/agents/chat/abort` with body `{ "streamId" or "conversationId": "..." }` aborts an
in-progress job and persists whatever partial content it had. Not used yet — noted here for
whenever a "stop generating" button gets built.

## DELETE /api/convos/ — verified 2026-07-19

```
DELETE https://kademurdock.com/api/convos/
Authorization: Bearer <token>
Content-Type: application/json

{ "arg": { "conversationId": "..." } }
```

Response `201`: `{"acknowledged":true,"deletedCount":1,"messages":{"acknowledged":true,"deletedCount":N}}`.
Used live to clean up the test conversation from this session's protocol verification.

## Client notes — Phase 3 additions

- **Why `MessageSendingService` never decodes `responseMessage`:** the live test only confirmed the
  *persisted* shape (via a follow-up `GET /api/messages`), not the raw in-flight SSE `final` frame's
  exact field completeness (e.g. whether `createdAt` is present on the pre-save in-memory object at
  the moment the event is built). Rather than risk a strict `Codable` decode throwing on a field
  that might not always be there, the service treats `final` (and the 404-already-done case) purely
  as a completion *signal* and always finishes by re-fetching messages through the same
  already-verified Phase 2 path. Slightly less efficient, meaningfully more robust.
- **Streaming through the shared client:** `KadeAPIClient` gained `streamBytes(_:)` alongside the
  existing buffered `send(_:)` — same session, same UA, same pacing gate, just hands back
  `URLSession.AsyncBytes` instead of buffered `Data`. Every request in this app — including the SSE
  subscribe — still goes through the one shared client and its one pacing clock; no service opens
  its own `URLSession`.
- **VoiceOver behavior (Phase 3):** no token-by-token streaming is rendered — a constantly-growing
  spoken string is bad VoiceOver UX. The UI shows the sent message immediately (optimistic), a
  single static "`<agent>` is replying…" row while waiting, then moves accessibility focus to the
  real reply once `GET /api/messages` confirms it. A failed send leaves the optimistic message
  visible (it really was sent) and focuses a Retry control instead.
