# Native release candidate

The candidate combines the family-history branch with the completed September
29 native fixes. The prior source heads remain intact. It also folds the older
prepared World announcement queue and Washhouse state into the current renderer
and audio/cache code.

The candidate includes rapid text-book skips, interruption-aware Library
playback, truthful destructive-action results, request-ID-preserving chat Retry,
clear copied-link responses and system Paste controls, World audio recovery,
shared Clubhouse Library playback, prepared family sources/descriptions/restored
copies, research cautions, and server-authorized separate-archive selection.
A phone-call observer prevents World reactivation from resuming loops during a
system call. The Clubhouse picker is presented from its Choose button.

The only dirty older worktree discovered during the branch audit contains a
Sound Booth link-import progress flag. The current candidate already has the
same separation between file and link imports, so that older patch was preserved
in place and not reapplied. The older narrator-preference issue is also already
resolved by the current server-backed preference code. The long-chat CPU report
and device audio timing reports still require runtime evidence; they have not
been represented as fixed by this integration.

## Local checks

Windows has no Swift compiler or Xcode. The available checks passed: the art
check covers 59 pictures and their descriptions; YAML/project configuration,
99 JSON files and 68 raw Swift JSON fixtures parse; Bash parses all 16 workflow
steps and the run-test scripts; the nine Foundation/art gates occur in both
compile and release lanes; the lanes use Xcode 26.4; all four marketing versions
are 2.2.1; the source diff has no whitespace errors. A read-only scan of 357
tracked text files found no archive tree IDs, full tree names or DNA-denylist
names after one old comment was made generic. These checks do not establish
Swift compilation, VoiceOver behavior, audio playback or physical-device results.

## Release gates

The root task must finish API/export/native review before any paid Mac run.
Then run `ios-compile-check` on the exact candidate commit. Its nine gates cover
speech, push, character motion, voice selection, World models, family-history
models, Clubhouse models, described captions and art descriptions. The simulator
compile captures the first errors and returns the actual compiler status.

Only after that gate succeeds, run `ios-native-testflight` on the same commit.
Keep the established signing integration/certificate. The build-number step must
read the live TestFlight maximum successfully; an API failure stops rather than
falling back to build 100. The archive lane uploads to Apple, with automatic
TestFlight submission disabled. Distribution and public review are separate
steps, verified by their resulting App Store Connect states.

The read-only App Store Connect check found public version 2.2.0, build 316,
READY_FOR_SALE, and beta version 2.2.1, build 319, VALID/BETA_APPROVED. No pending
store version was listed. Version 2.2.1 can therefore be retained, with the next
build number chosen live. Recheck if another release occurs meanwhile.
TestFlight What to Test stays exactly: `Everything can always use testing.`
Keep external automatic notifications off. New public release notes should
include the accumulated changes; preserve the existing App Review contact,
demo-account and data-use information when adding feature notes.

Private research bundles, photos, account grants and archive configurations stay
on the platform. This candidate creates neither family account matches nor a
relationship between separate trees. Only synthetic family fixtures are part
of the source. Do not add family research or credential files to this repository.

Physical acceptance still covers VoiceOver source/excerpt reading, the selected
original/restored description and Save/Share result, archive switch/sign-out
cache isolation, book skip/interruption behavior, two-device Clubhouse playback,
World return during a phone call, headphones removal and queued announcements.
No paid CI, upload, tester distribution or public review submission was initiated
while preparing this candidate.

References for reviewed system APIs: Apple documents
[CXCallObserver](https://developer.apple.com/documentation/callkit/cxcallobserver)
and [queued speech announcements](https://developer.apple.com/documentation/swiftui/view/speechannouncementsqueued(_:)).
