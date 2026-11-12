# Inworld timing tracks on the iPhone (Nov 11 2026)

The website went live with real Inworld mouth shapes on Nov 11 2026 (proxy
3522191, bridge f2b3e4b, fork c31def456). This is the iPhone half.

## What it does

- **Asks only while a face shows.** Read-aloud and auto-read send
  `timing: true` (multipart field) when a portrait of that speaker is on
  screen (`KadeFaceTimingDemand`, fed by `CharacterPortraitView` appear and
  disappear). A call's hello sends `faces: true` when the call has a character.
  Both stop when Settings turns voice portraits off, or when UserDefaults
  `kadeFaceTimings` is `false` (the website's localStorage switch).
- **WAV safety first.** A WAV with a track has a `kdtm` chunk between `fmt `
  and `data`. `KadeTimingTrack.read` walks the chunks to `data` (never a fixed
  44 bytes), and `KadeTimingTrack.strippingTrack` cuts the chunk out before
  AVAudioPlayer, AVAudioFile or the live-face page sees the bytes, so they get
  exactly the plain WAV they always got. `StreamingWavParser.parseHeader`
  already walked chunks; the tests pin that it starts the PCM after a track.
- **The mouth.** `KadeTimingTrack.panel(atMs:strength:)` is a line-for-line
  port of the website's `trackPanelAt`: the 15 OpenXR shapes (or Inworld's 11
  phone classes) onto the nine mouth panels, the shape that fills most of a
  50 ms window, a lip closure that never vanishes between frames, drawn 40 ms
  ahead of the sound. Outside the track's coverage, or with no track (Fish
  voices, the streamed lane, old clips), every rig keeps its loudness method.
- **Every rig.** The track rides on `CharacterPresentation.timingTrack` (with
  `elapsed` as the clip's playhead), so `CharacterMotion.pose` gives the sheet
  rig and Angel the real viseme, and `PuppetMotion.Input.viseme` (the
  website's `TRACK_SHAPES`) gives puppets and the living paintings the real
  shape instead of the random pick per syllable.
- **Little sounds.** A `[laugh]` or `[sigh]` in the track's words shows on the
  face when it is heard (`CharacterPresentation.timed`).

## Where the clock comes from

- Buffered read-aloud: `AVAudioPlayer.currentTime`; the track must fit the
  player's duration within 250 ms.
- Streamed read-aloud: the streamed lane never carries a track; a response the
  proxy buffered instead can, and `StreamingClipPlayer` reads it from the header
  only when the data chunk declares a real size that fits.
- Calls: each WAV clip's track goes onto `CharacterPlaybackTimeline` with the
  clip, and the presentation uses `time - clip.start`.
- A live video face plays its own clips and moves its own lips: no track.

## Interrupt-fix hook

`CharacterPlaybackTimeline.heardPosition(at:)` says which clip was audible,
how far in, its length, and the whole words heard when the clip had a track.
`StreamingCallService.flushPlayback` reads it before clearing and hands it to
`reportPlaybackPosition`, which sends nothing until the bridge's message is
defined (`sendsPlaybackPosition` is false; the field names there are a
placeholder).

## Tests

`run-timing-track-tests.sh` (macOS; also run by claude-native-check.yml):
the website's timing-track tests case for case, golden mouth picks from the
website's own module (`TimingTrackTests/timing-golden.json`, regenerate with
`node dev/timing-track/golden.mjs <folder holding timing-track.mjs and
avatar-expression.mjs>`), the WAV readers and the strip, the presentation and
call timeline, the puppet engine's tracked mouth, and when the app asks.

Not done here: a sighted look on a real phone (closures on p, b and m; the
mouth lingering open at phrase ends), and Android.
