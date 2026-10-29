# Lux image access: held native repair

Prepared October 10, 2026. No deployment, paid inference, native build, report-status change, or notification was performed.

## Evidence and cause

The private feedback board contained one matching open Lux report, created October 9 at 21:39:38 UTC, with surface `chat`. Its associated reply at 21:35:48 has two Flux calls: an initial failure followed by a successful image result, plus one persisted `image/png` file record in `attachments` with `context: image_generation`. There is no uploaded `files` array on that reply. No reporter identity, prompt, image URL, or conversation text is included here or in tests.

The corresponding chat request used the exact iPhone/Safari user-agent hardcoded by `KadeAPIClient`. This is consistent with the native app; user-agent alone cannot distinguish it conclusively from Safari. The report and message metadata do not identify an installed app version.

The native defect is deterministic in source: `KadeMessage.CodingKeys` omitted `attachments`, and the transcript used only `message.files`. Codable therefore discarded generated images when the completed reply reloaded and whenever the conversation reopened. Existing thumbnails had no open/save action and were hidden from VoiceOver beneath a combined message row. This affects native iPhone chats with generated image attachments, across agents, not only Lux.

The backend persisted the image metadata. A HEAD request to the raw stored B2 URL returned 403; it was not retried. That is not proof of a missing object or a failed authenticated download, because this is a raw storage URL and not the authorized file route. Actual image-byte retrieval as the owning account remains a release check.

## Changes

- Decode generated image attachments while ignoring memory receipts, unrelated artifacts, and malformed entries. Merge with existing uploaded files using stable file IDs to avoid duplicates.
- Expose image presence and Open images in the VoiceOver Actions rotor, visual message menu, thumbnail tap, and simple transcript.
- Add a viewer with previous/next navigation, loading/error states, explicit retry, Done, and Save or share image.
- Fetch image bytes through the existing same-origin authenticated `/api/files/download/:userId/:file_id` route. It retains the backend's file-owner, agent-resource and tenant checks. Stored/signed URLs receive no bearer token. IDs are validated; local filenames are random and do not use untrusted server filenames.
- Clean up local temporary image files and reject cancelled requests, empty responses, oversized/non-image data, and denied access.
- Use the existing final authoritative message reload. Memory receipts, speech, and stream handling are unchanged. Images appear after reply completion; this patch does not add mid-generation previews.

## Source and scope

Native base: `2f63d8ef8e62e2d0c5495d0a739c13b4c3994bce`, isolated branch `codex/lux-image-access-20261010`.

Backend inspected: `d85ddede122501ebe505cde467623b3bfb06fd1f`. Railway reported deployment `e217764c-480d-479d-b792-8682b35b00b4` SUCCESS for this SHA. At report time the predecessor was `94aeeb443a028dd2543a8ef164a86e401002ddc7`.

Proxy head and deployed SHA: `658b5ba83cb057e437dc321c2c9bcf5ddd0760a7`; Railway deployment `3b9eae0e-dcc3-4b4f-9ac7-7784bb3fa702` was SUCCESS. The installed/released iPhone build was not independently verified in this task.

No backend, proxy, Android, authentication, memory, persona, or production settings changed. Existing owners' checkouts are untouched. Web already consumes generated attachments in its content renderer; web and Android were not end-to-end tested for this report.

## Validation and release proposal

Swift syntax parsing passed for all four changed/new production Swift files and the test file. `git diff --check` and Python runner compilation passed.

The existing backend `api/server/middleware/accessResources/fileAccess.spec.js` suite passed all 18 tests on the inspected backend snapshot using the installed local workspace dependencies and MongoMemoryServer. It covers owner access, anonymous/missing-file errors, cross-user and cross-tenant denial, and the existing agent-resource permission rules. This validates the unchanged authorization route middleware, not the new Swift viewer.

`python3 dev/run-message-attachment-tests.py` contains 24 synthetic assertions against the production Foundation message models: generated-only history, legacy/null/empty replies, heterogeneous/malformed artifacts, multiple images, upload deduplication, preserved text, expired URL independence, route traversal rejection, non-image rejection, accessibility label, and Codable round-trip. It exits with an explicit BLOCKED result here because `swiftc` is not installed; no Swift assertion has been executed. The command is now part of the existing Codemagic pre-build gate for a future approved release.

Before approval to release: run that Foundation suite on an available Swift host, then obtain an explicit budget/build approval for iOS compilation and simulator/device validation. Coordinate with the active puppet release owner before choosing/rebasing onto the final native release commit. Confirm the actual reporter's surface/version from a reliable source if available.

Device acceptance: use an existing image in an authorized test account (no new paid generation); complete and reopen a reply, find Open images with VoiceOver, load the image, save to Photos/Files, cancel/dismiss and return focus, test multiple images and simple transcript, and verify denied/missing images fail clearly. Verify that another account cannot retrieve the file. Check web/Android separately if the reporter was using one of those surfaces.

Only after the authorized build and owner-session image retrieval pass should the patch ship. Keep the feedback report open until the reported surface is verified working. Draft help text for that release: "Pictures made in chat are included in the reply. On iPhone, use Open images in the message's Actions menu, then Save or share image. You can also open images from older conversations."
