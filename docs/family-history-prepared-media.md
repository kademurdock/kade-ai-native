# Prepared family-history media

The native viewer reads saved descriptions, text and optional restored image
variants from the existing private family-history API. It does not generate a
description or image while someone views it. Access still comes from `/me` and
the server's per-route checks; this change creates no account matches or guest
grants.

`GET /media/:id/info` may include:

```json
{
  "source": {
    "kind": "record",
    "title": "An invented census",
    "citation": "Invented County, census, page 3.",
    "url": "https://example.com/source/3"
  }
}
```

All four source fields are optional. Older `{kind,title}` labels remain valid,
and `sourceUrl` is accepted as an alias for `url`. The Source disclosure shows
the saved title and citation with selectable text. The optional website action
accepts only HTTP or HTTPS URLs with a host. Opening that provider is separate
from reading the local source image and citation.

The person strip retains its established restored-first preference and its
Original/Restored switch. The displayed copy uses its own `/info` image
metadata for both the initial and switched selection. A switched reference does
not inherit the other copy's description, transcription, automatic-reading
flags or dimensions while its own metadata loads. AI restoration labels remain
visible, and the original remains selectable.

The archive version is persisted alongside the account's cached pictures.
Version changes invalidate payload memory, image memory, signed links and disk
caches, including the old cached home. In-flight responses from the prior
archive are discarded. Existing caches migrate their version from `home.json`
when no version marker exists. Sign-out and access revocation retain the
existing full-cache removal behavior.

## Checks

`run-family-tests.sh` covers source decoding compatibility, safe website links
and clearing copy-specific metadata, in addition to the existing family rules.
The native CI workflows already run this script before their iOS builds.

This change was prepared on Windows without Swift, WSL or Xcode. The Swift test
binary and SwiftUI app were not built locally; `git diff --check` passed.
Before shipping, run the existing Swift and iOS build gates, then check on a
device that VoiceOver can open/read Source, original/restored descriptions
follow the selected copy, saving/sharing follows that selection, and an archive
refresh retrieves updated images.

## Evidence and separate archives

Records now retain `evidenceWarning`, `sourceExcerpt`,
`sourceExcerptCoverage`, `sourceCitation`, `sourceUrl`, and optional
`newspaperSource`. The latter preserves coverage, the indexed person's role,
the principal article subject, an `identityReview` object, the explicit
`linkedTreeIdentityVerified` flag, and source limitations. Record summaries
speak the evidence warning without repeating a warning already in the server's
sentence. The expanded transcription shows saved article text with its scope,
selectable citations, and an optional source website link. Media information
shows the same review data; a name in a newspaper index does not become identity
proof. These fields are optional for older payloads.
The viewer labels attached people as "People linked to this record". A
record-specific indexed role stays on its record card; a shared page viewer
does not apply one alias's role to everyone attached to the same image.

`GET /archives` returns only authorized `{id,title}` entries and an optional
`defaultArchive`. With two or more entries, Home and the locked view show a
Family archive menu. The server supplies every choice; the app creates no
account grants, person matches, or links between separate trees. If an older
server returns 404 for this additive endpoint, the app keeps its existing
default archive behavior.

All extra-archive requests include `?archive=<id>`, including `/me`, media
signing, notes, and audio. The default omits the query. Access memos, image
memory, disk folders, and family preferences are scoped by account and archive.
Switching archives discards in-flight responses, clears payloads, signed image
links and picture caches, and stops story audio. A person or gallery route from
the previous archive's back stack offers the selected archive's home instead
of reusing its IDs in another tree. The selected archive is session-only and
must pass its own `/me` check before content is drawn.

The Foundation fixtures cover article-vs-indexed-person context, unverified
identity, excerpt scope, optional legacy fields, catalog slug validation,
unlisted defaults, query scoping, and separation of same-ID cache keys.
Swift and Xcode remain unavailable on this Windows host, so these additional
Swift tests and SwiftUI compilation require the existing CI/iOS build gates.
