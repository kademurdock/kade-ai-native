# LibreChat endpoints (confirmed as we go)

Rules: pace requests (>= a few seconds apart), send a real browser-like User-Agent.
Nothing here is confirmed until it has a "verified" date.

| Endpoint | Method | Purpose | Verified |
|---|---|---|---|
| /api/auth/login | POST | email+password -> token + refresh cookie | not yet |
| /api/auth/refresh | POST | refresh token | not yet |
| /api/convos | GET | conversation list | not yet |
| /api/agents | GET | agents list | not yet |
| (SSE send) | POST | send message, stream reply | not yet |
