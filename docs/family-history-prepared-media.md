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
