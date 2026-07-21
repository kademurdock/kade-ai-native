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
| /api/agents | GET | agents/characters list, cursor-paginated | **2026-07-19** |
| /api/agents/:id/duplicate | POST | server-side clone (agent + actions minus secrets), answers `201 {agent, actions}` — decode the `agent` wrapper, not a bare agent | source-confirmed 2026-07-21, wired in AgentManagerView |
| /api/agents/:agent_id/avatar/ | POST | multipart, field name `file` (read off the web client's AgentPanel upload — nothing server-side documents it); server resizes | source-confirmed 2026-07-21, wired in AgentEditorView |

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

**Starting a brand-new conversation (confirmed 2026-07-19, session 11, read directly from
`api/server/controllers/agents/request.js`):** OMIT `conversationId` from the request body
entirely (not an empty string, not a client-generated UUID) — the server's own check is
`const isNewConvo = !reqConversationId || reqConversationId === 'new';` (a literal string `"new"`
also works, matching the web client's own placeholder convention, but omitting the key is simplest
from Swift). When `isNewConvo`, the server mints `crypto.randomUUID()` server-side and returns it
as `conversationId` in the immediate response — that's the ONLY place the client learns the real
id; there is no other endpoint to look it up beforehand. `agent_id` is NOT optional in practice for
a new conversation the way it can be for a follow-up turn on an existing one (an existing
conversation's server-side record already knows who's answering; a brand-new one has no such
record yet) — always send a real `agent_id` on the first turn.

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


## GET /api/agents — verified 2026-07-19 (Phase 4)

Request: `GET /api/agents?limit=1000` (also accepts `cursor`, `category`, `search`, `promoted`).
Requires `Authorization: Bearer <token>`. Returned data is scoped by ACL to what the signed-in
user can VIEW (owned + shared + publicly-marketplace agents) — same access model as the web
client's agent picker, nothing native-specific.

Response `200`:

```jsonc
{
  "object": "list",
  "data": [
    {
      "id": "agent_6llV0eMu4fmIaj8f2x1Sb",   // use this, not _id, as agent_id on sends
      "_id": "6a3db74e36a602442fc0756a",
      "name": "Kiana",
      "description": "This is the default agent if you don't feel like creating one yourself. ...",
      "author": "6a3cba4d0b0afa92194e42f7",
      "category": "general",
      "support_contact": { "name": "", "email": "" },
      "is_promoted": false,
      "updatedAt": "2026-07-18T16:03:42.989Z",
      "avatar": { "filepath": "https://...(signed S3 URL)...", "source": "s3" }
      // "isPublic": true  -- present on publicly-shared agents only
    }
    // ... 221 total on this account at verification time
  ],
  "first_id": "agent_...",
  "last_id": "agent_...",
  "has_more": false,
  "after": null   // NOTE: the response's next-cursor field is called `after`, but it's sent
                  // back as the `cursor` QUERY PARAM on the next request — the names don't match
}
```

`limit` is capped server-side at 1000 (`Math.min(..., 1000)`) regardless of what's requested
higher. 221 agents fit in one page at that cap; `AgentsService.swift` fetches once per sign-in
with `limit=1000` and does not currently paginate further if an account ever exceeds that (see
its own doc comment for the known-simplification note).

`category` values seen live (221 agents, one account): `companions` (50), `roleplay` (36),
`creative` (19), `expert` (18), `kids`/`lifestyle` (7 each), `education` (5), `Art`/`comedy`/
`entertainment`/`food` (4 each), plus ~40 more with 1-3 agents each (`personal`, `general`,
`tech`, `coding`, `finance`, `accessibility`, ...). No client-side grouping by category in Phase
4's v1 — flat alphabetical list + `.searchable` text filter (name + description) was enough to
navigate 221 rows by VoiceOver in testing; category grouping is a candidate follow-up if the
picker ever feels too flat.

## Agent switching is per-request, not per-conversation — verified live 2026-07-19 (Phase 4)

The fork does **not** lock a conversation to whichever agent started it. `buildEndpointOption` /
`parseCompactConvo` build the generation's `agent_id` fresh from EACH `POST
/api/agents/chat/agents` request body — the conversation document's own stored `agent_id` field
is not consulted to pick who answers.

Proved this live rather than trusting it from source alone: started a fresh test conversation
with agent A ("Kiana"), got a reply from Kiana; sent a SECOND message in the **same
conversationId**, same `parentMessageId` chain, but with `agent_id` set to agent B ("Big Tom")
instead — the reply came back with `"sender": "Big Tom"` and `"model": "agent_J3YsYW9yQ-13aXDyQrFwI"`,
addressing the user directly, while the first turn's persisted message stayed attributed to
Kiana. Test conversation deleted afterward via `DELETE /api/convos/`.

**Implication for the client:** "switching agents" needs no dedicated endpoint and doesn't touch
the conversation record at all — it's purely which `agent_id` `ConversationDetailView` hands to
`MessageSendingService.send` for the NEXT turn. `AgentPickerView` + `ConversationDetailView`'s
`selectedAgentId` (`@State`, seeded from `conversation.agentId` on open, not re-synced from the
server afterward) implement exactly that. A conversation can freely have turns from different
agents interleaved in its history — the app doesn't attempt to detect or badge that in the
message list for v1 (each `MessageRow` already shows its own `speakerLabel` per message, which is
enough to keep it readable).

## Edit and Regenerate (Phase 8, message actions) — verified live 2026-07-19

Added a per-message actions menu (`ConversationDetailView`'s `MessageRow`) with Copy, Read Aloud,
Edit and Resend (last user message only), and Regenerate (last assistant message only). Before
building this, ran a live probe against a disposable test conversation to find the SAFE way to
implement Edit/Regenerate, because `api/server/controllers/agents/request.js` really does destructure
extra fields off `req.body` that look purpose-built for this: `isRegenerate`, `editedContent`,
`overrideParentMessageId`, `responseMessageId` (aliased from `responseMessageId` in the body).

**Do NOT use `isRegenerate`/`overrideParentMessageId`/`responseMessageId` from this client without
much deeper source investigation than a session has time for.** A live test sent:

```jsonc
{
  "text": "<same prompt text again>",
  "messageId": "<fresh uuid>",
  "parentMessageId": "<U1, the original user message's id>",
  "overrideParentMessageId": "<A1, the assistant reply being regenerated>",
  "responseMessageId": "<A1>",
  "isRegenerate": true,
  "conversationId": "<cid>",
  "endpoint": "agents",
  "agent_id": "agent_6llV0eMu4fmIaj8f2x1Sb"
}
```

The POST returned a normal `200 {streamId, conversationId, status:"started"}` and the job completed
with no error event — but `GET /api/messages/:conversationId` afterward showed message A1 had been
**rewritten in place**: `isCreatedByUser` flipped `false` → `true`, `sender` flipped `"Kiana"` →
`"User"`, `text` became the prompt text, and its original `content` (the "PONG" reply) was gone.
No new third message ever appeared. Whatever this fork's regenerate path actually expects from a
caller, this wasn't it, and the result silently corrupts the target message rather than erroring —
worth knowing before anyone's tempted to reach for these fields again.

**The safe, verified-clean alternative** (what `MessageRow`'s Edit/Regenerate actually use): resend
through the exact same plain request shape `MessageSendingService.send` already used before this
feature existed (`text`, `messageId`, `parentMessageId`, `conversationId`, `endpoint`, `agent_id` --
no `isRegenerate`/`overrideParentMessageId`/`responseMessageId` at all), just passing an EARLIER
message's own `parentMessageId` instead of `messages.last?.messageId`. Tested live immediately after
the corruption above, same conversation: sent `{text: "<edited prompt>", parentMessageId: P0 (=
U1's own parent, the all-zero sentinel)}` — came back completely clean, a brand-new user message
(fresh id, correct `isCreatedByUser`/`sender`/`text`) followed by a brand-new assistant reply
(correct `content`, correct `sender`, `parentMessageId` pointing at the new user message). Nothing
else in the conversation was touched. This is a real branch (a sibling to the original), not an
in-place edit -- since `fetchMessages` doesn't reconstruct the parentMessageId tree (see that
function's own "known simplification" doc comment above), both the old and new turns render in the
flat chronological list. `ConversationDetailView` restricts Edit/Regenerate to only the single most
recent turn specifically so the appended branch always lands immediately next to what it replaces,
which is the one case where that flat rendering still reads cleanly.

**Bonus finding from the same probe:** an assistant message's raw JSON includes a `"model"` field
holding its `agent_id` (e.g. `"model": "agent_6llV0eMu4fmIaj8f2x1Sb"`), `null` on user messages.
Not documented above because `KadeMessage` didn't decode it before this session -- now does, as
`agentId` (see `ConversationsService.swift`), so a per-message "Read Aloud" always speaks a past
reply in the voice that agent actually used.

Test conversation deleted afterward via `DELETE /api/convos/` (`deletedCount` messages: 4).

## Agent editor body fields (POST /api/agents, PATCH /api/agents/:id) — 2026-07-21

`conversation_starters` is a plain string array on the same create/update body the
Phase 1 editor already sends (name/description/instructions/category/provider/model,
plus `tts.voiceId`). The editor ALWAYS sends it — an empty array deliberately clears
starters server-side, so deleting the last one in the UI really deletes it. Cap of 4
matches the web builder's own limit. Read back from `GET /api/agents/:id/expanded`
as the same `conversation_starters` key (the app's decoder uses exact key names — no
snake-case conversion — so the Swift property is spelled `conversation_starters` on
purpose).
