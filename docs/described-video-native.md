# Make a described video on the iPhone (Sep 24 2026)

The native twin of kademurdock.com/described-video. Choose a video, choose the
narration, hear the price, and get back a copy of the video with a narrator
describing what happens on screen in the pauses, keeping the actors, music and
sound.

## Where it lives

- `Sources/DescribedVideoService.swift`: the HTTP client for
  `/api/kade/described-video/*` (V4 API), the wire models, the chunked upload,
  lock-screen cards, and `DescribedVideoAccess` (the gate).
- `Sources/DescribedVideoView.swift`: the screen, the voice sheet, the player
  sheet, the transcript sheet, and the Photos movie importer.
- Doors in: the Create tab tile "Described video" (spoken "Make a described
  video"), Search everything ("described video", "narration", "movie"...), Help's
  Where is list, "Make a described copy" on a Library video (opens with that
  book and track), the lock-screen card (`kadeai://jobs?kind=described-video`),
  and a push with `kadeRoute` = `described-video`.

## The gate (App Review)

The server answers 403 "Described video is currently a private owner trial."
for everyone but admins, including the App Review demo account. The app asks
`GET config` once per sign-in (6 s after sign-in, again on a foreground only if
the first ask failed on the network). Until that succeeds for this account,
nothing shows: no Create tile, no search entry, no Library button, no Help
section, no What's New entry. A 403 or 404 hides it silently. Sign-out forgets
the answer.

## What it does

- **Choose a video**: Files (movie types plus mkv, webm, avi, wmv, ts and other
  containers), Photos (videos, handed over as stored, no transcoding), a
  YouTube link, or a Library video. The phone checks size (2 GB) and length
  (the server's `maxSourceMinutes`) before uploading anything.
- **Upload**: 8 MB chunks (the server's `chunkBytes`) read from disk one at a
  time, three tries each with a short wait, a progress bar, a lock-screen card,
  and "Stop the upload". Picking the same file again resumes from the server's
  `uploadedBytes` (the request id is kept per file name, size and date).
- **Narration**: voice (a searchable sheet grouped by the catalogue's
  categories; each voice's description is its hint), Play a sample, usual and
  fastest speed, detail, pause mode, volume, closer look, first look, notes,
  and Describe only part of it (From/To, h:mm:ss, checked on the phone).
- **Cost**: every price is the server's (`POST /jobs/:id/estimate`), asked for
  about a second after the last change and spoken. Spend buttons carry the
  price ("Try the first 3 minutes, about $0.12", "Create described copy, about
  $1.40") and cannot be pressed without one. Each asks once more, naming the
  price and what is set aside.
- **Progress**: stage, percent, time left, queue position, cost so far; Cancel,
  Continue (the voice fields may change), Go back to version N, Rename, Delete.
  Polls every 5 s while the screen is open, 15 s while the app is in the
  background. A new state is spoken at once; stage and percent at most every
  30 s. The lock-screen card follows the run.
- **Result**: play the video or the audio (AVKit, Done button and the escape
  gesture; the Library's book pauses first), versions, the described
  transcript one line per swipe, Save or share (video, audio, transcript
  through the share sheet), Keep it in your Library (folder, share toggle off
  by default when the original is private or someone else's), Describe the
  rest after a preview, Try again on parts that could not be described.

Not on the phone yet (use the website): making a new version with different
narration (revoice), fresh descriptions (reanalyze), and the script editor.

## What to test on a phone (with VoiceOver on)

1. Signed in as the admin: the Create tab shows "Make a described video"; sign
   in as the demo account: no tile, no search result for "described", no Help
   section, no button on Library videos.
2. Library: open a video, "Make a described copy", then "Check this Library
   video". The screen lands on the video's heading; the check finishes with
   "Video checked…" and VoiceOver moves to Narrator voice.
3. Narrator voice: search "warm", pick one, Play a sample. Change the detail:
   the prices on the two spend buttons disappear, then come back and are said.
4. Try the first 3 minutes: the alert names the price. Lock the phone: the
   Lock Screen card shows "Describing" with a bar. The push opens the screen.
5. Play the described video; Done closes it. Read the described transcript.
   Save or share the audio to Files.
6. Describe only part of it with a bad time ("5:00" to "4:00"): the problem is
   shown and said, and no price is asked for.
7. Files: pick a long video, Stop the upload halfway, pick it again: it carries
   on from where it stopped.
