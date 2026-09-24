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
  `uploadedBytes` (the request id is kept per file name, size and date). The
  upload belongs to the app, not the screen (`DescribedVideoUploads`): a
  describer screen that replaced the one that started it (the Create tab
  tapped again, the upload's own card) still shows the bar and Stop under the
  status line, cannot start a second upload, and opens the video when it ends.
- **Away from the screen** (another tab, another screen): nothing is spoken,
  sounded or polled there. What would have been said is said when the screen
  shows again, which also refreshes the video and restarts polling.
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

Round-2 server features, each shown only when the server says so:

- **Keep 7 more days** on a finished copy when `keepable` (`POST jobs/:id/keep`,
  free; says the new end date, and when it cannot be kept longer).
- **Over-quote stop**: a run stopped with `overQuote` (it passed the approval,
  `approvedUSD`) says what was spent and what was quoted, and replaces Continue
  with "Allow up to $Z more and continue". Z is the resume estimate's
  `allowUpToUSD` (or `approvedUSD`, else the price × 1.5 + 10 cents), never past
  the limit for one run. It asks first, naming Z, what is kept and today's
  allowance, then sends `POST resume {…voice fields, allowUpToUSD: Z}`.
- **You already have this video**: when `library-imports` answers
  `existing: true`, that video is opened and its state is said.
- **Check again** when `recheckable` (`POST jobs/:id/recheck`, free).
- **Library folder**: the job's `libraryPath` (the Audio mirror of the
  original's shelf) is the default folder, else the config's.
- Rehearsal copies made on the website are labelled "rehearsal, test tone";
  the rehearsal button itself is website only.

Rules the second pass fixed or settled:

- Nothing carries from one video to the next: a new video starts with empty
  notes, both paid passes off, the whole video, her remembered voice and speeds,
  and the server's suggested folder. The paid passes are never remembered.
- Every server field is optional and read leniently (a missing field, a number
  sent as text, a count where a list was); only a video's id is required.
- A 401 is refreshed once (one refresh shared by every caller, none again for a
  minute after one fails); polling stops on 401 or 403 instead of retrying.
- Nothing is said over the player or the transcript sheet: the latest line is
  held and said when the sheet closes. The player takes a non-mixing session so
  the headphone and lock-screen buttons work, and restores the app's session.
- When an action takes its own button away, VoiceOver lands on the video's
  heading (or the Library section, or Choose a video) after the confirmation.

Not on the phone yet (use the website): making a new version with different
narration (revoice), fresh descriptions (reanalyze), the script editor, and the
free rehearsal.

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
   on from where it stopped. VoiceOver lands on Choose a video after Stop.
8. Open a video, turn on Take a closer look and type a note, then Choose another
   video and pick a new one: notes are empty, both passes are off, and "New
   video: notes are empty and the extra passes are off" is said with the price.
9. Library: "Make a described copy" on a video already described: "You already
   have this video…" and it opens.
10. While a video describes, play an earlier version: no progress is spoken
   over it; the latest line is said when the player closes.
11. Start a long upload, then tap the Create tab again: the new screen says a
   video is uploading, shows the bar and Stop, and its choose buttons are
   dimmed. Go to the Talk tab: no upload percent or "Video checked" is spoken
   there. Come back: the uploaded video is open and its news is said.
12. With one video describing and another just finished, tap the "ready" push:
   the finished one opens (a lock-screen card still opens the one describing).
