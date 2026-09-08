# Signed upload recovery

The release workflow writes `signed-release.json` immediately after signing, before screenshots or App Store publishing. Download it together with the IPA when publishing times out. The receipt reads bundle identity from the IPA and records byte size, SHA-256 and the source commit.

Before any upload retry, compare the downloaded IPA against that receipt, then inspect Apple's existing buildUploads and buildUploadFiles for the exact bundle version, short version and IOS platform. Preserve completed supporting assets. Reuse an AWAITING_UPLOAD record and its missing ASSET reservation only when the artifact identity matches. Follow Apple's returned upload operations and checksum contract; after an uncertain commit, re-read the record before acting. COMPLETE or PROCESSING means check processing instead of creating another upload or build.

This helper does not request a build, authenticate to Apple, upload, publish or retry automatically. A portable authenticated upload-resume command for Forge is still outstanding. The successful build-279 recovery and private reusable upload helper are recorded in NATIVE_POLISH_2026-09-08_PART155.md in the project memory folder.

Validate locally: `python scripts/test_release_receipt.py`.
