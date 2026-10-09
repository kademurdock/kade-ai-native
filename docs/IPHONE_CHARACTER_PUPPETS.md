# Native iPhone character puppets

The ordinary conversation and call stages use layered busts for Harley, Kiana,
Lilly, Della and Witherspoon, the female librarian. Public and private Lilly have
separate exact ID/avatar registrations while sharing their original artwork.
This does not change agent discovery, account access, voices or conversation data.

Heads use the existing expression, mouth and blink atlases. Bodies are supporting
plates. Lilly's original cats remain static. Arms and hands are not separately
articulated. Kiana's original locs and knit shoulders remain together with
restrained head motion. Her close crop excludes the reused concept entirely;
its mismatched chest, duplicate pendant and hard panel join are never visible.
Kiana has no separate torso motion in this version.
Della's independent extraction supplies alpha only. Witherspoon retains her
original glasses, pinned hair, face and feminine identity.

Motion uses existing playback energy and authored directions. It is approximate
mouth animation, without phoneme timestamps. Rendering is local, with no avatar
service. System/app Reduce Motion, Low Power, inactive scenes and disappearance
stop sampling. Decorative frames remain hidden from VoiceOver. Descriptions are
requested through the existing Describe character action.

Animated characters defaults on, with existing opt-outs preserved. The same
setting is searchable by puppet, avatar, moving face or a character's name.
Stages below160points retain the readable portrait; an absent resource or changed
avatar also falls back. Unknown characters never borrow another person's body.

## Assets and verification

Seven RGBA asset sets are committed under Sources/Assets.xcassets. Source masters
and provenance are in dev/puppet-review-assets. Run
`python3 dev/prepare-puppet-review.py --check` to verify their exact hashes and
catalog entries without rewriting anything. Every release lane performs this gate.

`run-character-tests.sh` covers exact registrations, cross-avatar mismatches,
bounded motion, compact sizes, the mandatory Kiana clip and the librarian's identity.
The simulator audit uses the production resolver without a special preview flag.
It checks all six identities with the real call engine rendered offline, including
interruption, queued reactions, wrong speakers and non-speech audio. It captures
light/dark, still and84/104/132point views, actual CallView layouts and the same chat
stage embedded in ConversationDetailView. Chat fixture transcript/composer text is
explicitly placeholder UI, not a complete conversation-screen test. No microphone,
provider request or sign-in is used. The silent native video is visual evidence;
physical speaker/Bluetooth timing and hardware VoiceOver remain device checks.

`ios-character-audit-verify` creates the no-sign/no-upload review artifacts.
`ios-puppet-device-verify` runs the full existing Foundation gates and simulator
audit, signs an iPhone IPA using the existing family certificate, and saves an
exact-source recovery receipt. It does not upload or notify testers. Both require
KADE_EXPECTED_COMMIT and use bounded, included-minute account preflight checks.

The signed artifact's source, four target versions, bundle identities, provision
profiles and SHA-256 are checked before any distribution. TestFlight is separate
from App Store release and physical-phone acceptance. Historical simulator-only
notes remain in IPHONE_PUPPET_PREVIEW.md; they do not describe the current renderer.
