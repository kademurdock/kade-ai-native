# Clubhouse library playback — source prepared, no build

Prepared September 28, 2026. Kade explicitly requested iPhone coding but **no Codemagic build yet**. This branch is held locally; do not trigger a build or release merely to finish this work.

`ClubhouseLibraryService` streams shared Library audio/video directly with AVPlayer. The existing Clubhouse token response now supplies a separate media proof. Server state controls the room's host, revision, play/pause, seeks, and late arrivals. The UI has shared-media search, host controls, takeover after an absent host, local media volume, optional picture, and Rejoin playback. It keeps the current call audio session. Interruptions and a disconnected audio device pause locally until Rejoin.

The web/server counterpart is the September 28 public-home/Clubhouse release. Existing installed apps tolerate the extra optional token field. Public web publishing and dashboard family flags already work through their web pages; the new native playback controls require a future app build.

September 29 review fixes (still unbuilt): video keeps playing when the phone locks (`.continuesIfPossible`, as in DescribedVideoPlayer); VoiceOver now hears local pauses, load failures, a lost connection (once, when media stops), sharing stopped, search results and a chosen recording's parts; Back/Ahead 30 use the room's timeline, not the local player; her own play/seek/load clears a local pause; a forced refresh waits for an in-flight poll instead of being dropped; a failed load gets one fresh link, then stops until Rejoin; the round-trip estimate leaves out the API client's pacing wait (`KadeAPIClient.pacingWaitRemaining`).

`run-clubhouse-tests.sh` tests decoding, permissions-denied state, shared timeline bounds, skip targets and the spoken search/parts lines with Foundation. Added to the existing Codemagic test gate for the next authorized build. These Swift tests and a full iOS compile have not been run on this Windows workstation.

Before a later release, run the existing CI gates and the new gate, then verify two real devices: simultaneous playback, late join, pause/seek, host leaving/takeover, revoked library access, VoiceOver, background/foreground, headphones disconnection, Bluetooth, and AirPlay while the microphone remains in a call. Hiding video keeps the file's sound; it is not an audio-only transcode. This is not an Apple SharePlay implementation. Room recordings do not include the direct Library player.

The TestFlight What to Test line must remain exactly: `Everything can always use testing.`
