# Della articulated body study

This optional simulator study gives Della two complete plum sleeves and open
hands while preserving her original face, mouth and expression atlas. It is
not registered in a production portrait, conversation or call.

The built-in imagegen tool created `della-body-gesture-master-v1.png` from the
approved headless cardigan plate and an existing waist-up style reference.
The image remains unchanged: 1254 × 1254 RGBA, SHA-256
`285b6e1f176b79ba08cfc7a4252a3d8864901eabbdcbc1e58f304299164206d2`.
The prompt set is saved in `prompts.json`. Independent arm extractions were
rejected because they moved and resized the anatomy. Authored clipping paths
select each complete sleeve and connected hand from the aligned master.
The central torso uses the existing approved body plate. Small static lower
cardigan patches from the same untouched gesture master sit beneath it to
support the old plate's transparent under-cuff clefts; their authored paths
exclude skin, hands, collar and neck. The original plate's full lower garment
shape is retained. Natural outer space below a bent sleeve remains. The head
consumes the existing extraction's alpha with original atlas RGB.

The preview uses a 414 × 620 world viewport. The original 414-square face panel
keeps its placement and scale, so showing hands does not make her face smaller.
Both wrists move with their sleeves. Shoulder accents are limited to 3° and
use the portrait's existing performance clock and animation budget. Idle,
thinking, silence and disabled motion park the arms; a listening acknowledgement
is smaller and sparse. No extra timer, audio service or publisher is created.

## Unsigned simulator review

On a Mac with Xcode and XcodeGen:

1. Run `python3 dev/prepare-della-articulated-review.py --prepare`.
2. Generate and build the Debug simulator project with the ordinary project
   tools. No signing, publishing or upload is needed.
3. Open the existing puppet lab, choose Della at 160 or 208 points, and enable
   the articulated body study. Compare delivery states, interruption, the still
   toggle and light/dark appearance.
4. Run `bash run-character-tests.sh` for model checks.
5. Run `python3 dev/prepare-della-articulated-review.py --clean` when finished.
   The helper verifies the exact study files before removing them. Always clean
   the study catalog before a Release archive.

The master lives outside `Sources`; normal builds do not include it. The
temporary catalog is ignored by Git and availability-gated in the Debug-only
renderer. Missing art, changed identity, compact sizes and an unset study
toggle retain the accepted portrait.
The ordinary source-art preflight rejects a staged study catalog, so signed
build lanes stop until it has been cleaned. For the optional simulator study,
run ordinary source-art checks before staging its resource.

## Verification status

Local static source-art and offline composition checks are recorded alongside
the workspace review artifacts. They do not establish Swift compilation,
native SwiftUI layout, audio synchronization, accessibility behavior or battery
usage. The earlier body-language PR's successful native audit applies to its
own exact commit, not this additional study. Only five included CI minutes
remain in Codemagic this cycle. The isolated
`.github/workflows/della-articulated-review.yml` uses a standard Mac runner only
when this exact source branch belongs to the public repository. It verifies
models, compiles an unsigned Debug simulator app, and captures 28 controlled
poses. Bounded PNG and receipt evidence is returned through job logs; it uses
neither artifact uploads nor caches. No paid or signed build is needed for this
review. Native compilation and model checks passed at the earlier candidate;
its partial capture exposed a screenshot acknowledgement timing mismatch.
The runner now records per-phase timings, bounds each screenshot to 30 seconds,
and allows 480 seconds for the whole capture. The fixture allows 60 seconds for
each validated screenshot acknowledgement. The job remains capped at 25 minutes.
Its own exact-source receipt determines complete verification status.

Before production registration, review shoulder seams throughout the motion
range, fit at 160/208 points, the original face and atlas patch alignment, and
call/chat control space on native iPhone. A taller production stage requires
explicit layout integration and its own native verification.
