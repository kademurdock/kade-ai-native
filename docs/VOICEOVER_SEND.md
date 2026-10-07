# VoiceOver's send target

The Send button's disabled expression became true as soon as the composer
cleared, before `sendState` entered sending. It became true again when the
reply completed with an empty draft. Both transitions invalidated the button
that the send path used as its accessibility focus anchor. The recording
button already avoids this by keeping one accessible button and guarding its
action.

Send now follows that pattern. The same Send/Stop button stays accessible;
unavailable sends are dimmed and explain the blocking condition only when
activated. Empty drafts, attachments still loading, recording and transcription
remain blocked. A ready attachment without text remains sendable. Stop still
works while sending. Repeated assignments to an already focused Send button
are skipped.

Both composer layouts bind keyboard editing separately from accessibility
focus. Sending explicitly ends keyboard editing before the field is disabled;
reply completion never sets editing back to true. The existing separate
composer-clear, optimistic-row and sending-state transactions remain intact.
Autoplay still avoids moving VoiceOver to the completed reply. Read-aloud-off,
speech failure, deliberate Stop, errors, manual message reading and recording
review retain their existing focus and announcement paths.

Streaming also exposed a second focus bug: FINAL rearmed the first-clip wait
even if character playback had already started. If the last clip was playing
at FINAL, draining it could focus the reply as though speech had failed.
`ReplySpeechFocus` retains actual playback history through FINAL and only
permits a fallback when no clip ever played. Completion's immediate VoiceOver
decision remains separate from its pending first-clip wait. Eighteen Foundation
checks cover playback before/after FINAL, sentence gaps, a failed first clip,
Hear replies off, no assistant reply, new sends and canceled waits. Both build
workflows run that gate before compiling the app.

No VoiceOver speech or audio-session setting is changed. Ordinary user-driven
VoiceOver, playback mixing and system ducking remain under their existing
controls. Source inspection supports the focus-lifecycle fault; physical
VoiceOver speech timing requires device acceptance.

The local Windows host has no Swift compiler or Xcode. Existing audio source
contracts, signed-receipt tests and whitespace checks are available locally;
the exact-source release workflow runs Foundation suites and compiles the
SwiftUI app. A skipped simulator audit is not device coverage. Check a typed
send and a transcribed send with Hear replies both on and off, move the cursor
during generation, stop a reply, and confirm that the cursor remains where
the user put it during character playback.
