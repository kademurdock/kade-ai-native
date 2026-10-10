# Della call/chat host review

This optional DEBUG simulator preview carries the accepted articulated Della
art into the actual `CallView` and `ConversationDetailView`. It preserves the
original portrait compositor, authored contours, face scale and four source
images from `3b0bf16dcaee5330167e0031c67461b3d2eae9d9`.

The native composer reserves one line at accessibility text sizes, two while
the keyboard or editing is active, and five in ordinary composition. The
accessibility attachment chip displays its filename on one truncated line;
its complete review-before-sending accessibility label and separate 44-point
Remove attachment control remain available.
At accessibility sizes the native editor occupies its own nearly full-width
row, with four separate composer actions below. The visible notification CTA
reads "Turn on" while its spoken label remains "Turn on notifications" and
its full reason and original action remain available. The ordinary horizontal
composer layout and fonts stay intact.

The lab's explicit review toggle enables the host preview only when Della's
exact identity/avatar and all review assets are present. One resolved layout
supplies the portrait side and reserved host height. Roomy screens can show the
taller body; editing, crowded controls, camera and accessibility text retain
square framing. At accessibility sizes, a focused editor or a window shorter
than 700 points removes the decorative portrait and puts the original four
voice/agent controls in the transcript. The native editor and its separate
Send, microphone, attachment and Thinking actions remain pinned. Thinking
retains its mode caption and spoken state without its decorative glyph at
accessibility sizes. These decisions never depend on measured composer height,
speech energy or a frame timer.
The call portrait's visibility region excludes pinned Mute/Hang Up controls.

The separate bounded native review uses the real hosts with invented local
messages, drafts, attachments, captions and notification-card state. Buffered,
upload and byte-stream API requests are rejected before network dispatch.
Camera-state fixtures mount an inactive preview without starting capture.
Every fixture pauses motion. Twenty-eight host cases on two actual simulator
device types are accompanied by twenty-four focused native control-tree tests:
sixteen on the roomy phone and eight on the actual smaller device. Empty-chat
welcome screens use the same constrained-space policy for optional controls.
Receipts require the exact source revision, immutable art, settled appearance,
measured stage/control/keyboard geometry and successful native tests.

Keyboard and accessibility fixtures place the real notification invitation in
the transcript rather than the pinned footer. The transcript must retain at
least 44 points of visible height. Separate scrolled cases require both real
invitation buttons to fit entirely inside that viewport without overlap or
keyboard occlusion. Ordinary packed/off cases retain the footer invitation;
empty-card cases must report no invitation geometry. Pinned composer, controls,
attachment and native button observations remain within the real screen and
above the software keyboard.

Combined largest-text/keyboard cases measure the initial software keyboard and
separately expose either the invitation or the four voice settings. On the
short phone, the canonical scrolled captures dismiss an actually presented
keyboard first. Their native tests disable both automatic dismissal and
automatic scrolling, drag inside the real transcript viewport to dismiss the
keyboard, then prove the requested controls reachable. Hidden portraits report
null stage/frame-match observations and no stale stage rectangle; dismissed
keyboards leave no stale keyboard rectangle. No claim requires both optional
groups to occupy the same viewport at once.

When a strict readiness check fails, a failed receipt can retain only bounded,
finite stage/window/whitelisted CGRect observations in `failedNativeGeometry`.
That rejected phase never becomes a capture or validated readiness record,
and all native success flags stay false. No arbitrary text or account data is
stored in this diagnostic.

This lane compiles unsigned once on the standard `macos-26` runner with Xcode
26.4.1. It validates the generated format-1/format-2 `.xctestrun` and confines
its original runner, test bundle and app to those exact build products. Each
recorded phone UUID explicitly boots and reaches `bootstatus` within 420 seconds.
Sixteen Pro Max and eight SE tests run with that unchanged compiled test file,
without project planning or another build. Their test caps remain 600 and 480
seconds. The always collector requires both complete zero-failure result
bundles and all 24 source-bound markers before the 28 expensive captures run.

The outer job is limited to 55 minutes. A shared 52-minute operation deadline
starts before checkout and cannot reset between setup, compilation, tests and
capture. Each operation uses the remaining shared time; its individual maximum
is not a promise that every maximum will fit together. The final three minutes
reserve 90 seconds for UI collection, 15 for the optional study cleanup, 60 for
evidence emission and 15 for teardown. Launcher action guards also reserve
cleanup time before their workflow step ends. Capture retains its 480-second
per-device and 960-second aggregate limits, 30-second readiness and 75-second
screenshot limits.

Native process output is limited to 8 MiB per log. A timeout saves false launch
status, the last actual test-start method, method durations and bounded sanitized
startup, XCTest activity and failure lines. An interrupted outer launcher can
recover those observations from its bounded runner-local log; partial markers
never establish UI success. Recovery saves only verified PNG/JSON and compact
receipts, with separate job directories for reruns.

It emits bounded PNG/JSON evidence through logs. It does not sign, upload
release builds, use paid runners or store cloud artifacts/caches. The frozen
signed Angel release remains unchanged. Physical
phone battery, frame timing, live voice and VoiceOver acceptance remain pending.

Native results apply only to their exact commit. No native fit or control-tree
success is claimed before the new host receipt passes. Review data is stored on
the F: workspace; recovery retains verified PNG/JSON and compact hash receipts
without another local copy of the raw job log or archive.
