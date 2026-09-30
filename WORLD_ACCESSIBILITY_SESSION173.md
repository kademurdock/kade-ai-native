# World speech, ambience and exploration — Part173 follow-up

Kade reported interrupted/partial iPhone VoiceOver button replies, little room
ambience, and too much emphasis on activities instead of exploring a shared 3D
world. Her saved room was read without movement: pawn_hocks, Tanglefoot.

Prepared changes:

- Announcements opt into Apple's queue, rather than its interrupting default.
  Stream messages arriving during a command are preserved after the complete
  command reply. Automatic focus/disabled-state changes no longer compete with
  that reply while VoiceOver runs. Latest reply and the full log remain readable.
- Start the current background before prewarming 87 event sounds; restore on
  screen return and resumable audio interruptions. Failed or stopped players can
  retry with the same room key, and downloads have a 15-second timeout.
- Decode/use room sensory ambience (including night woods and homes), avoid
  double-playing the same recording, and keep newer-room downloads authoritative.
- A fresh default audio session uses playback mixed with other audio; established
  call/Clubhouse categories are preserved. All world players stop on leaving.
- Announce exit destinations and show nearby people before the activity list.
- Includes the earlier held Washhouse picture/model changes in this same branch.

Verification: 31 Foundation checks include a >9,000-character Unicode reply,
live events flushed during a command, error ordering and clearing stale speech.
WorldService/WorldView pass Linux Swift parsing. The existing speech pipeline
passes 161 checks both before and after. These are NOT an iOS typecheck/archive,
physical VoiceOver acceptance, audio-session routing or human listening tests.

Device acceptance: at Hock's Pawn press Look, browse, and a person action; let
each finish while live listening is enabled. Check typed-command focus, character
creation, and long replies. Leave/reopen the World; background/resume; try a
Bluetooth route change and a phone/Clubhouse interruption. Visit woods at night
and an owned home. Verify sound switches and navigation still work. Keep user
gestures able to interrupt VoiceOver; do not force high-priority speech.

No new iPhone build is included in this source receipt. Main remains build282
until a separately authorized build actually succeeds. Public build281's pending
App Store review is separate and must not be replaced automatically.

Apple reference: https://developer.apple.com/documentation/foundation/nsattributedstring/key/accessibilityspeechqueueannouncement

Product priority: connected exploration, shared presence, accessible spatial
orientation and conversation before more chores or minigames. The current 3D
scene remains decorative. This patch does not claim continuous 3D locomotion,
autonomous synth players, new player access, or a completed identity Veil.
