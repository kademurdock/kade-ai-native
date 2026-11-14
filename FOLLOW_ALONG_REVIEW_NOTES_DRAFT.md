# Follow along: App Review notes (draft for the lead)

Written November 14, 2026, by the iPhone builder. This is item 14 of the design (TELLAVISION_SYNC_DESIGN_2026-11-13.md, Part 5.4). It is a draft. The lead decides what goes to App Store Connect, and when.

## A decision to make first: the demo seat

Kade decided the button exists only where the server says followAlong is true and the phone switch is on. The server switch starts admin-only. So in the first build, Apple's demo seat does not see the button.

Guideline 2.5.19 says apps must not hide features from review. A server-gated feature that Apple cannot see is the risk our notes already warn about (removal, and account termination in the worst case).

Two honest ways through:

1. Recommended, when the server side is live: set KADE_DESCRIPTION_FOLLOW so the demo seat is included (or "on" for everyone), put a short test film and its track on the demo seat, and use notes A below.
2. If the feature stays admin-only for that build: say so in the notes, plainly (notes B below). Do not leave it unmentioned.

## Notes A: the feature is on for the review account

Follow along with my TV (new in this version)

Kade-AI makes described videos for blind and low-vision people: a narrator describes what happens on screen. Follow along is for when the film plays on a TV instead of the phone. The phone listens to the film through its microphone, finds the right moment, and speaks the descriptions between the lines of dialogue, in the phone's own voice (the VoiceOver voice when VoiceOver is on).

How to try it with the review account:
1. Open the Create tab, then Described video.
2. Open the video named "[test film name]" under Your videos.
3. Play the test film on a second device, a Mac or another phone, with its sound on. The file is at [link to the test film] (its sound matches the track on the account).
4. On the iPhone, press "Follow along with my TV", read the sentence about the microphone, and press "Start listening". Allow the microphone if asked.
5. Within about 15 seconds the phone says "Found your place", then speaks descriptions in the gaps. Pause the film and it says the film seems to be paused. Press "Stop" to end. The phone says "Follow along is off. The microphone is off."

Microphone (5.1.1 and 2.5.14):
- The purpose string names Follow along: "Kade-AI uses your microphone when you talk to your characters or record, and when you turn on Follow along, to hear the film playing near you and keep its descriptions in step. Film sound is checked on your phone and is never saved or sent."
- The microphone opens only after the person presses Start listening, right under a sentence that says what it is for. While it listens, the iPhone shows its orange microphone dot, the screen says what it last heard, the Lock Screen shows "Following along", and a Stop button is always on the screen. It stops by itself when the film ends, or after 10 minutes without hearing the film.
- The sound is studied on the phone, a few seconds at a time, to match it against a small fingerprint of the film's soundtrack. Only the last 16 seconds are held in memory. Nothing is recorded to a file, uploaded or logged.

Background audio (2.5.4):
- The app already declares the audio background mode. Follow along uses it for what it is meant for: it plays speech (the descriptions) and records sound the whole time the film plays, so it keeps working with the screen locked. It never runs in the background on its own; it starts only when the person presses Start listening in the app.

No downloaded code (2.5.2):
- The matching runs in JavaScriptCore from a script that ships inside the app bundle (syncprint.js). The app downloads only data: the description lines (JSON) and the fingerprint (a binary file of numbers).

## Notes B: the feature is off for the review account

Follow along with my TV is in this build but switched off on our server for every account except the developer's own, while it is tested with real TVs. The review account does not see it. When we switch it on for users, we will say so in that version's review notes and put a test film on the review account. It uses the microphone only after the person presses Start listening; the purpose string already describes it.

## Things to check before sending

- The test film and its track exist on the demo seat, and the follow word for that job is "ready".
- The demo seat's described-video config answers followAlong true.
- The build carries the same Sources/syncprint.js as the server. Each project's own test checks only its own copy, so run python -I dev/follow-along/compare-syncprint.py PATH/TO/LibreChat-fork. It must say the two copies are the same. On November 14 they differed: copy one syncprint commit into both first (dev/follow-along/vendor-syncprint.py does both at once).
- The microphone purpose string in the built Info.plist is the new one.
