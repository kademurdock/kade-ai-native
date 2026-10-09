# Native iPhone character puppet preview

Historical simulator-only study, superseded by [the production path](IPHONE_CHARACTER_PUPPETS.md).

October 9, 2026. Continue the existing character work with native iPhone first.

Harley and public Lilly have native SwiftUI bust compositions for review. Their
faces, expressions, mouth patches and blinks come from their existing approved
atlases. Harley uses an experimental head alpha mask over a separate denim body.
Lilly uses authored outlines for her head and two original cats above a separate
hoodie body. The cats stay still while her head tilts and nods. Close crops retain
about 99.6% of Harley's and 88.6% of Lilly's original portrait-panel scale.
Neither study contains separately moving arms or hands.

The compositor consumes the same presentation and output level as the existing
face. Listening and thinking have their own expression; speaking follows actual
playback energy and authored delivery cues. This is approximate mouth animation,
not phoneme-accurate lip sync. It adds no avatar service or per-conversation
rendering charge. Existing speech-provider charges are unchanged.

## Scope

This is a DEBUG simulator experiment. Ordinary calls and conversations remain on
their existing renderer. Selection requires explicit review opt-in, the exact
registered public agent and exact avatar filename, a stage at least 160 points
wide, and the required review resources. Shared face artwork does not opt private
Lilly into this experiment. Compact 84/104/132-point stages retain the familiar portrait. The
approved articulated-figure registry is unchanged. The mask's RGB is never used
as Harley's face; only its alpha participates.

The source art lives under `dev/puppet-review-assets`, with generation provenance
in its README. Only the review
preparation script stages it into ignored asset catalog entries. A clean release
checkout does not include these experimental images as app resources. Do not
reuse a locally prepared asset directory for a release archive.

Motion respects the existing Reduce Motion, Low Power, foreground and visibility
gates. Animation is decorative and does not add VoiceOver stops. The manual lab
has labelled native controls and a prose description of each state. It never
speaks descriptions automatically or opens a microphone.

## Manual simulator review

On a Mac with the project's existing Xcode toolchain:

1. Run `python3 dev/prepare-puppet-review.py`, then `xcodegen generate`.
2. Run a Debug iPhone simulator with `KADE_A11Y_AUDIT=1` and `KADE_PUPPET_LAB=1`.
3. Choose Harley or Lilly, then use Listening, Thinking, Speaking, Interrupt and Still controls. Compare 84,
   104, 160 and 208 points. The manual lab is explicitly silent synthetic motion,
   not the character's actual voice. System Reduce Motion continues to win.

The automatic no-sign/no-publish `ios-character-audit-verify` workflow uses
`KADE_PUPPET_AUDIT=1` and a required `KADE_EXPECTED_COMMIT`. It prepares the two
hash-pinned RGBA assets, runs Foundation motion/identity/geometry tests, compiles
the native app, and renders the production call engine offline. It captures
Harley and Lilly idle/listening/thinking on light/dark surfaces, still mode, compact
fallbacks, speaking, interruption and queued expression changes. Kiana and Della
retain their existing playback checks. The output is a native simulator video,
screenshots and a machine-readable receipt. Puppet review allows up to 150 seconds
for the expanded four-character playback and two-character pose galleries.
No sign-in, microphone, provider
generation, TestFlight upload, email or App Store submission is part of this lane.

## Acceptance and next art work

Simulator compilation/rendering results are recorded with the exact commit in
the task's verification report, rather than inferred from source checks. Inspect
hair edges, forehead clipping, head/collar seam and changing mouth patches during
timed motion before enabling any pack in normal calls. Physical VoiceOver,
Bluetooth/output timing, oldest-phone memory and battery checks remain separate.

The next expressive step is a single-source torso and separate arms/hands for
Della, followed by Kiana and the rest of the prepared cast. Existing fused
concept pictures cannot provide seam-free shoulder layers. Kiana also needs
separate front/back locs. Keep each character's identity/approved face and
per-character registration; do not apply Harley's body to other characters.

Apple references for the existing architecture: [player timeline](https://developer.apple.com/documentation/avfaudio/avaudioplayernode),
[output presentation latency](https://developer.apple.com/documentation/avfaudio/avaudionode/outputpresentationlatency),
[Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion).
Rendered PCM is a useful offline timing check, not a measurement of physical
speaker or Bluetooth latency.
