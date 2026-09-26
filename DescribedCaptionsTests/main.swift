// DESCRIBED CAPTIONS TESTS (Part 291, Sep 25 2026).
//
// The captions the phone draws itself while VoiceOver is on (so VoiceOver does
// not read the system captions over the film). Pure logic, no SwiftUI, no
// AVFoundation: builds with the open-source Swift toolchain.
//
//   ./run-caption-tests.sh
//
// The first fixture is the start of the real captions.vtt from Kade's first
// described video (job a395d684..., a Looney Tunes short), byte for byte.

import Foundation

var failures = 0

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("ok    \(name)")
    } else {
        failures += 1
        print("FAIL  \(name) \(detail())")
    }
}

func checkEqual<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    check(name, got == want, "got \(got), want \(want)")
}

let real = """
WEBVTT

1
00:00:00.000 --> 00:00:02.670
Speaker 1: It's April
1, the day of the fool.

2
00:00:02.720 --> 00:00:03.230
Woo hoo.

3
00:00:03.280 --> 00:00:04.280
Woo hoo.

4
00:00:05.200 --> 00:00:06.800
It's really funny, daddy.

"""

let cues = DescribedCaptions.parse(real)
checkEqual("four cues from the real file", cues.count, 4)
checkEqual("two lines become one", cues.first?.text ?? "", "Speaker 1: It's April 1, the day of the fool.")
checkEqual("end time read", cues.first?.end ?? 0, 2.67)
checkEqual("start time read", cues.last?.start ?? 0, 5.2)

checkEqual("shown at its start", DescribedCaptions.caption(at: 0, in: cues), "Speaker 1: It's April 1, the day of the fool.")
checkEqual("shown just before its end", DescribedCaptions.caption(at: 2.669, in: cues), "Speaker 1: It's April 1, the day of the fool.")
checkEqual("gone at its end", DescribedCaptions.caption(at: 2.67, in: cues), "")
checkEqual("the next one", DescribedCaptions.caption(at: 2.9, in: cues), "Woo hoo.")
checkEqual("nothing in a gap", DescribedCaptions.caption(at: 4.8, in: cues), "")
checkEqual("nothing after the last", DescribedCaptions.caption(at: 120, in: cues), "")
checkEqual("nothing for a bad clock", DescribedCaptions.caption(at: .nan, in: cues), "")

let windows = "WEBVTT\r\n\r\n1\r\n00:00:05.000 --> 00:00:08.000\r\nMeeks &amp; Sons &lt;est. 1952&gt;.\r\n\r\n2\r\n00:52.000 --> 00:55.000 align:start\r\nFrank waves\r\nfrom the porch.\r\n"
let escaped = DescribedCaptions.parse(windows)
checkEqual("CRLF file read", escaped.count, 2)
checkEqual("escapes undone", escaped.first?.text ?? "", "Meeks & Sons <est. 1952>.")
checkEqual("hours optional", escaped.last?.start ?? 0, 52)
checkEqual("cue settings ignored", escaped.last?.end ?? 0, 55)

checkEqual("empty file", DescribedCaptions.parse("WEBVTT\n\n").count, 0)
checkEqual("backwards cue skipped", DescribedCaptions.parse("WEBVTT\n\n00:00:05.000 --> 00:00:04.000\nNo.\n").count, 0)
checkEqual("wordless cue skipped", DescribedCaptions.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n   \n").count, 0)
checkEqual("seconds, hours", DescribedCaptions.seconds("01:02:03.500") ?? -1, 3723.5)
check("seconds, junk", DescribedCaptions.seconds("1:2:3:4") == nil && DescribedCaptions.seconds("abc") == nil && DescribedCaptions.seconds("") == nil)

// Part 295 (Sep 26 2026): which captions the system shows. The Road Runner
// short had no dialogue (empty captions.vtt) and VoiceOver still read text
// over the film.
func plan(voiceOver: Bool = true, readAloud: Bool = false, external: Bool = false, dialogue: Bool?) -> DescribedCaptionPlan {
    DescribedCaptionPlan.choose(voiceOver: voiceOver, readAloud: readAloud, external: external, hasDialogue: dialogue)
}

checkEqual("Road Runner: quiet, nothing drawn", plan(dialogue: false), .quiet(draws: false))
checkEqual("quiet before the captions file has downloaded", plan(dialogue: nil), .quiet(draws: false))
checkEqual("quiet with dialogue: the app draws it", plan(dialogue: true), .quiet(draws: true))
checkEqual("Read captions: the player's pick", plan(readAloud: true, dialogue: true), .reads)
checkEqual("Read captions, no dialogue: still the player's pick", plan(readAloud: true, dialogue: false), .reads)
checkEqual("Read captions, file unread: never the system's pick", plan(readAloud: true, dialogue: nil), .reads)
checkEqual("AirPlay: the TV shows the Captions track", plan(external: true, dialogue: true), .captions)
checkEqual("AirPlay, file unread: the system's choice", plan(readAloud: true, external: true, dialogue: nil), .automatic)
checkEqual("no VoiceOver: the Captions track", plan(voiceOver: false, dialogue: true), .captions)
checkEqual("no VoiceOver, no dialogue: nothing shown", plan(voiceOver: false, dialogue: false), .off)
checkEqual("no VoiceOver, file unread: the system's choice", plan(voiceOver: false, dialogue: nil), .automatic)

check("quiet: AVPlayer may not pick", !plan(dialogue: false).systemMayPick && !plan(dialogue: true).systemMayPick)
check("Read captions: AVPlayer may not pick, even before the file is read",
      !plan(readAloud: true, dialogue: nil).systemMayPick && !plan(readAloud: true, dialogue: true).systemMayPick)
check("AirPlay or no VoiceOver: AVPlayer may pick again",
      plan(external: true, dialogue: nil).systemMayPick && plan(voiceOver: false, dialogue: true).systemMayPick)

// Which track is Captions. media.ts titles; the phone may or may not pass them on.
let roadRunner = [["English", "Audio descriptions (text)"]]
let both = [["English", "Captions"], ["English", "Audio descriptions (text)"]]
checkEqual("Road Runner: no Captions track, file unread", DescribedCaptionPlan.captionsTrack(names: roadRunner, hasDialogue: nil), nil)
checkEqual("Road Runner: no Captions track, file read", DescribedCaptionPlan.captionsTrack(names: roadRunner, hasDialogue: false), nil)
checkEqual("a descriptions track is never Captions", DescribedCaptionPlan.captionsTrack(names: roadRunner, hasDialogue: true), nil)
checkEqual("both tracks by name", DescribedCaptionPlan.captionsTrack(names: both, hasDialogue: nil), 0)
checkEqual("the name wins over the place", DescribedCaptionPlan.captionsTrack(names: [both[1], both[0]], hasDialogue: true), 1)
checkEqual("two nameless tracks: the first", DescribedCaptionPlan.captionsTrack(names: [["English"], ["English"]], hasDialogue: nil), 0)
checkEqual("one nameless track, file unread: cannot tell", DescribedCaptionPlan.captionsTrack(names: [["English"]], hasDialogue: nil), nil)
checkEqual("one nameless track, no dialogue: not Captions", DescribedCaptionPlan.captionsTrack(names: [["English"]], hasDialogue: false), nil)
checkEqual("one nameless track, dialogue: Captions", DescribedCaptionPlan.captionsTrack(names: [["English"]], hasDialogue: true), 0)
checkEqual("a name that only mentions captions is not enough", DescribedCaptionPlan.captionsTrack(names: [["English CC (captions)"]], hasDialogue: nil), nil)
checkEqual("no text tracks", DescribedCaptionPlan.captionsTrack(names: [], hasDialogue: true), nil)

// The guard: while held, whatever else comes on is put back.
check("quiet: a track that came back on goes off", plan(dialogue: false).mustRestore(showing: 0, captions: nil))
check("quiet: nothing showing, nothing done", !plan(dialogue: false).mustRestore(showing: nil, captions: nil))
check("Read captions, Road Runner: the descriptions track goes off",
      plan(readAloud: true, dialogue: nil).mustRestore(showing: 0, captions: nil)
      && plan(readAloud: true, dialogue: false).mustRestore(showing: 0, captions: nil))
check("Read captions, Road Runner: nothing showing, nothing done", !plan(readAloud: true, dialogue: false).mustRestore(showing: nil, captions: nil))
check("Read captions: the descriptions track gives way to Captions", plan(readAloud: true, dialogue: true).mustRestore(showing: 1, captions: 0))
check("Read captions: Captions showing, nothing done", !plan(readAloud: true, dialogue: true).mustRestore(showing: 0, captions: 0))
check("Read captions: Captions switched off comes back", plan(readAloud: true, dialogue: true).mustRestore(showing: nil, captions: 0))
checkEqual("Read captions shows the Captions track", plan(readAloud: true, dialogue: true).track(captions: 0), 0)
checkEqual("quiet shows no track", plan(dialogue: true).track(captions: 0), nil)
check("a sighted viewer's or the TV's pick is never undone",
      !plan(voiceOver: false, dialogue: true).mustRestore(showing: 1, captions: 0)
      && !plan(external: true, dialogue: true).mustRestore(showing: 1, captions: 0)
      && !plan(voiceOver: false, dialogue: nil).mustRestore(showing: 0, captions: nil))

if failures == 0 {
    print("\nAll described-caption checks passed.")
    exit(0)
} else {
    print("\n\(failures) described-caption check(s) failed.")
    exit(1)
}
