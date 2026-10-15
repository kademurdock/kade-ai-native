Kade reported a Fish voice at 1.2 speed on the iPhone speaker, with Faster voice
(streaming) enabled: the reply stayed silent while the Actions rotor offered
Pause; a manual pause/resume started it. The exact hardware/session cause has
not been established. Provider synthesis latency and speed quality are separate.

Both players previously announced playback when their play command was accepted.
They now wait for a progressing playhead (or a completed streamed buffer). A
stalled start gets one half-second recovery of the same queued audio, followed
by a second half-second bound. Failure cannot remain labelled as playing.
Buffered completion callbacks must belong to the current player; streamed buffer
callbacks carry the current playback generation so an old clip cannot finish a
new one. Stop/cancel still owns the queue and resumes parked continuations.

A streamed player failure can replay the existing completed HTTP response through
the buffered player. Replay retains at most 8 MiB per prefetched response; an
oversized, failed or incomplete response cannot be replayed. Completed WAV lengths
are repaired without changing PCM. This local failure path makes no additional
synthesis request. A byte-less fetch failure retains the existing retry policy.

The speech suite covers stalled/advancing/short-clip clocks, cancellation,
one-recovery limits, bounded response retention and exact WAV sample preservation.
Four actual Swift mutants must fail their behavior checks. Existing motion,
VoiceOver/Reduce Motion policy, artwork, signing material and speed calculation
are preserved. Native compile and simulator receipts must match the new source.
These checks do not establish physical audibility, VoiceOver behavior on a phone,
battery use, or Fish's proprietary speed processing. Kade's phone remains the
audible validation of this reproduction.
