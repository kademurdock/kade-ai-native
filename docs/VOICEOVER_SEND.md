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
Successful FINAL now preserves the user's VoiceOver cursor in both Hear
replies modes, including a voice that never starts. Arrival earcon/haptic and
manual reading remain. Deliberate Stop, errors and recording review retain
their existing focus and announcement paths.

Streaming also exposed a second focus bug: FINAL rearmed the first-clip wait
even if character playback had already started. If the last clip was playing
at FINAL, draining it could focus the reply as though speech had failed.
`ReplySpeechFocus` retains actual playback history through FINAL. Completion
only records a first-clip wait; it never supplies a focus instruction. Queue
drain cleanup checks actual queued, scheduled, pumping and playing work.
No new failure announcement relies on a global isSpeaking-false edge; the
existing actual playback-error cue remains. Foundation checks cover playback
before/after FINAL, pending pumps, sentence gaps, zero-audio FINAL, both Hear
modes, new sends, canceled waits and exact current-reply identity. Both build
workflows run that gate before compiling the app.

MessageSendingService passes through its already validated FINAL reply ID.
Autoplay and streamed-turn adoption require that exact assistant ID and chat.
If a short stream has already ended, one eight-second-bounded read of its exact
owner-scoped task receipt can provide a completed matching chat/reply ID.
Missing, failed, stopped, inaccessible or mismatched receipts cannot cause
an old assistant response to be replayed. Current live speech still plays;
stored replies without a verified identity remain manually readable. There
is no new generation, model call or automatic retry.

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
