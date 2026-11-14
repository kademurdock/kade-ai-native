# Follow along: App Review notes (draft for the lead)

Written November 14, 2026, by the iPhone builder. This is item 14 of the design (TELLAVISION_SYNC_DESIGN_2026-11-13.md, Part 5.4). It is a draft. The lead decides what goes to App Store Connect, and when.

Kade decided on November 14 that Follow along is on for everyone at launch: KADE_DESCRIPTION_FOLLOW=on. So Apple's review account sees the button, and the notes below say how to try it.

Two places in the notes are left for the lead. Fill them in after the demo film is on the review account. Each is in square brackets, in capital letters:

- The test film's name, as it shows under Your videos.
- A public link to the test film, so the reviewer can play it on a second device.

## The notes

Follow along with my TV (new in this version)

Kade-AI makes described videos for blind and low-vision people: a narrator describes what happens on screen. Follow along is for when the film plays on a TV instead of the phone. The phone listens to the film through its microphone, finds the right moment, and speaks the descriptions between the lines of dialogue, in the phone's own voice (the VoiceOver voice when VoiceOver is on).

How to try it with the review account:
1. Open the Create tab, then Described video.
2. Open the video named "[TEST FILM NAME: the lead fills this in]" under Your videos.
3. Play the test film on a second device, a Mac or another phone, with its sound on. The film is at [PUBLIC LINK TO THE TEST FILM: the lead fills this in]. Its sound matches the track on the account.
4. On the iPhone, press "Follow along with my TV", read the sentence about the microphone, and press "Start listening". Allow the microphone if asked.
5. Within about 15 seconds the phone says "Found your place", then speaks descriptions in the gaps. Pause the film, and within about 10 seconds it says the film seems to be paused. Press "Stop" to end. The phone says "Follow along is off. The microphone is off."

Microphone (5.1.1 and 2.5.14):
- The purpose string names Follow along: "Kade-AI uses your microphone when you talk to your characters or record, and when you turn on Follow along, to hear the film playing near you and keep its descriptions in step. Film sound is checked on your phone and is never saved or sent."
- The microphone opens only after the person presses Start listening, right under a sentence that says what it is for. While it listens, the iPhone shows its orange microphone dot, the screen says what it last heard, the Lock Screen shows "Following along", and a Stop button is always on the screen. It stops by itself when the film ends, or after 10 minutes without hearing the film.
- The sound is studied on the phone, a few seconds at a time, to match it against a small fingerprint of the film's soundtrack. Only the last 16 seconds are held in memory. Nothing is recorded to a file, uploaded or logged.

Background audio (2.5.4):
- The app already declares the audio background mode. Follow along uses it for what it is meant for: it plays speech (the descriptions) and records sound the whole time the film plays, so it keeps working with the screen locked. It never runs in the background on its own; it starts only when the person presses Start listening in the app.

No downloaded code (2.5.2):
- The matching runs in JavaScriptCore from a script that ships inside the app bundle (syncprint.js). The app downloads only data: the description lines (JSON) and the fingerprint (a binary file of numbers).

## Things to check before sending

- The server has KADE_DESCRIPTION_FOLLOW=on, and the review account's described-video config answers followAlong true.
- The test film and its track are on the review account, and the follow word for that job is "ready".
- Both placeholders are filled in: the film's name, and its public link. Nothing in square brackets is left in what goes to Apple.
- The build carries the same Sources/syncprint.js as the server: syncprint 1.1.1, sha256 7a1191ea3ce1eb39d4cdfe14bf7853b62ef8540c942cba4dbfa52a7bf0c384a6. Run python -I dev/follow-along/compare-syncprint.py PATH/TO/LibreChat-fork. It must say "The same".
- The microphone purpose string in the built Info.plist is the new one.
