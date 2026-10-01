# Native 2.2.2 release

The source baseline is a438a806, verified against the signed 2.2.1 build 320
and its current public App Store record. Earlier notes calling that source
unbuilt were stale. Its Library, Clubhouse, World, family-history and retry
changes are retained.

This update adds chat Take Photo with the system's review before accepting a
picture, accessible permission errors and Cancel, bounded attachment preparation
and upload, actual upload cancellation, explicit Retry with retained context,
stale-result guards and consistent 30 MB validation. Send remains unavailable
while an attachment is being prepared or uploaded. The existing Describe
camera picker shares the reviewed wrapper.

The remaining valid held haptics change scopes locking inside asynchronous
preparation. The signed-IPA receipt helper records the binary's bundle identity,
source commit, byte size and SHA-256 before Apple upload. An older dirty Sound
Booth import-progress change is already superseded by the retained implementation.
Older diagnostic screenshot workflows are superseded by the current tour.

The compile lane retains all existing Foundation/art gates and runs the four
synthetic attachment XCTest cases on an existing simulator. It neither signs
nor publishes. Archive follows only after the exact candidate passes. Both
lanes require the supplied source commit to match; automatic diagnostic
re-archiving has been removed. A failure returns its original status and first
errors without starting a second archive.

All app/extensions use marketing version 2.2.2. Archive reads the live maximum
TestFlight build number and fails if that lookup fails. Existing signing and
distribution audiences remain in use. TestFlight and public review are verified
separately from binary upload; submission alone is not public availability.

Windows free checks do not establish Swift compilation or physical-device
acceptance. Camera, VoiceOver, slow cloud-photo selection, interruption and audio
device behavior still need device acceptance. No private test content is needed.
The separately prepared shared-server stream fix is not part of this native
release and has not been deployed.
