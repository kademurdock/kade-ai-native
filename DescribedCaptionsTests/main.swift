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

if failures == 0 {
    print("\nAll described-caption checks passed.")
    exit(0)
} else {
    print("\n\(failures) described-caption check(s) failed.")
    exit(1)
}
