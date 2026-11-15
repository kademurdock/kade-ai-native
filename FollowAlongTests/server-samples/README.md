# The server's own answers, for the Follow along tests

Saved on November 14, 2026, for the contract check between the website and the phone.

## What these are

- Real answers from the website's own Follow along code, saved byte for byte. None was written by hand.
- They come from github.com/kademurdock/LibreChat, branch claude/tellavision-sync-20261114, commit 2b42b45f6. That commit merges kade (2d20870e6) into the branch. Its Follow along code is the same as in 0cb6c2e87, the commit that added finishedAt to the ready answer.
- The fingerprint library is syncprint 1.1.1. Its sha256 is 7a1191ea3ce1eb39d4cdfe14bf7853b62ef8540c942cba4dbfa52a7bf0c384a6, the same file as Sources/syncprint.js.

## The gone answers, remade November 14, late

- track-409-gone-get.json and track-409-gone-post.json were made again from the live website code, commit 563157bd1 on branch claude/deploy-20261114 of github.com/kademurdock/LibreChat (the deploy that turned Follow along on for everyone). Its fingerprint library is the same syncprint 1.1.1 file.
- Their reason now reads: "The original video is no longer stored, so Follow along can't be made for this copy. Bringing the video in again makes a new described copy that can follow along."
- Each is 202 bytes, SHA-256 786a5afb660aa1159ab8d4b2c61d3efb8cbb5bef341fabdcf4d891dd49d38470. Only these two files were copied in. In the same run the other answers differed only in their dates, so they were kept.
- FollowWords.gone in the app says the same sentence, and the contract test checks they match.

## How they were made

The website lane's sample script ran the website's real code in one process: the routes, the free check, the describe engine and its sound passes, the fingerprint worker, the track planner and the check lane. The script is kept with that lane's notes, not in this repository.

The film was 60 seconds of Big Buck Bunny with five test lines of speech mixed in. Only the paid steps were stand-ins. The look answered with a real describer's description track for this clip. Dialogue timing answered with the clip's own words. The narrator was a short tone. Storage and the database were local and in memory. There was no network call and no paid call.

The settings: an ordinary account, KADE_DESCRIPTION_FOLLOW=on, the credit at both ends (the production default), speed 1.5, fastest speed 2.25.

Two videos were described from the same clip:

- Job dce6029e937e9b4f0d712ab49635b630 was described with the switch on. Its fingerprint was made at describe time. Its answers are the ready ones.
- Job 63973116c9f28b7261ae865e8accc54c was described with the switch off, so it had no fingerprint. Then the switch went on. It was possible. After a POST it was making. Then its original was removed, and it was gone.

## One change by hand

In the two 200 answers, printUrl is a placeholder. The real one is a signed storage link that lasts six hours. The owner id, 65a1f00dcafe4b1d2e3f4a5b, is made up. No file holds a key.

## The files

Every path is under /api/kade/described-video.

- track.json: the track the server saved for the first job's copy, byte for byte. It is the same object as "track" in the 200 answers.
- plan.sypr: the fingerprint the server made for that job, 5,206 bytes. Its sha256 is the one track.json names.
- track-200-ready-get.json and track-200-ready-post.json: GET and POST /jobs/:id/track, ready. They differ only in expiresAt.
- track-202-making-get.json and track-202-making-post.json: being made.
- track-409-possible-get.json: not asked for yet.
- track-409-gone-get.json and track-409-gone-post.json: cannot be made; the original is gone.
- track-404-not-available-get.json: the switch keeps this person out.
- config.json and config-off.json: GET /config with the switch on, and with it unset.
- job-ready.json, job-possible.json, job-making.json and job-gone.json: GET /jobs/:id with each follow word.
- samples.json: the server lane's index: each file's status, method and path, the job ids, and the checksums of track.json and plan.sypr.
- film-sound-29s-to-37s.s16le: not from the server. Eight seconds of the same clip's sound, from second 29 to 37, at 8 kHz, mono, 16-bit little-endian, decoded on its own with ffmpeg 6.1.1. No test speech is in those seconds. The tests use it to find the film in the server's fingerprint.

Big Buck Bunny is (c) copyright 2008, Blender Foundation, www.bigbuckbunny.org, under the Creative Commons Attribution 3.0 licence.

## Keep the bytes

.gitattributes marks this folder -text, so git never changes a byte. The tests check the checksums of track.json and plan.sypr.

To refresh the samples, run the sample script again in the website lane and copy the files here. The job ids, the times and the checksums change on every run, so update the test's expected values too.
