# Witherspoon native bust registration

Registration authored 2026-10-09. Witherspoon remains the established older **woman** librarian (she/her), with her original face, wire glasses and loosely pinned gray-brown hair. This is native source geometry awaiting the combined native visual pass.

## Source identity and channels

- Agent: `agent_o7TKU3lK0Euo0MKgpNpvZ`.
- Exact avatar filename: `agent-agent_o7TKU3lK0Euo0MKgpNpvZ-avatar-1790252530815.png`.
- RGB face and glasses come only from `CharacterWitherspoonFaces`; speaking uses the existing `CharacterWitherspoonMouths`. Both are the unchanged 1254-square sheets with 414-square panels at pitch 420. Existing basic-expression fallback remains appropriate; no invented nuance sheet is added.
- `witherspoon-body-support.png` is copied byte-identically from `cast-concepts/witherspoon/native-bust-20261009/witherspoon-body-support.png` in the parent `expressive-faces` repository. It contains a forest-green cardigan, cream blouse, open-book pin, hands and book as one plate. The generated head, glasses, hair and exposed neck were removed in the existing candidate.
- Existing generation provenance and exact prompt remain in that folder's `candidate-manifest.json` and `imagegen-prompt.txt`. No new image generation was performed for this registration.

| Copied file | Pixels | SHA-256 |
| --- | --- | --- |
| `witherspoon-body-support.png` | 1024 × 1536 | `b8cab50d34fd94fef153b711f24ab4bf24a9cc42c535fa43816fd5113843d8df` |

## Native contract

`CharacterWitherspoonBustGeometry.artwork` supplies Foundation data; `headPath` is available under `canImport(SwiftUI) && !CHARACTER_MODEL_TESTS`. The path is authored in the original 414-square neutral panel. It includes the pinned hair, entire face/glasses and neck with a small original blouse overlap at the lower V. Fine flyaways are conservatively trimmed to avoid the library background. No generated face RGB or new alpha extraction is needed.

| Element | World coordinates |
| --- | --- |
| Close viewport | x 202, y 90, side 620 |
| Original neutral panel | x 202, y 90, side 620 |
| Body destination | x 0, y -75, width 1024, height 1536 |
| Head pivot | 512,540 |
| Body pivot | 512,1025 |
| Motion bounds | head ±1° / ±0.6 world px; body held steady |

Use asset `CharacterWitherspoonBustBody`, with no mask image. The shared renderer must apply the exact ID/avatar gate, body-resource availability check, stage requirement and minimum 160-point size. Her original panel already crops the crown at its top edge; the close native viewport preserves that intentional crop. The book and hands are outside this close crop and stay one unarticulated plate. Glasses remain part of the head transform.

## Static evidence and remaining review

The body hash matches the inspected candidate. Existing alpha inspection found zero alpha in the exposed-neck samples at x 512/y 100,300,480,580,650; the top 400 rows have maximum alpha 1. Far background more than 20 pixels from alpha 128 has maximum alpha 1, so there is no material painted background despite hidden RGB shown by some image viewers.

The original proposal put the body at y 0. A read-only alpha scan found its center collar V first reaches alpha 200 at y 747, while the mapped original neck ends at y 710. Initial y -55 registration still left 28 uncovered pixels in the central neck window x 420–604/y 505–709. Moving the body to y -75 gives 38 world pixels of center overlap. With the authored path approximated by 20 samples per curve, that window has **zero** uncovered pixels at head rotations -1°, 0°, +1°, each with vertical offsets -0.6 and +0.6; body alpha threshold 200. This bounded grid probe verifies central coverage only. It does not verify all hair edges, the visual collar shape or SwiftUI antialiasing.

Accessible visual description: an older woman with wire glasses and loosely pinned gray-brown hair, wearing a forest-green cardigan over a cream blouse with a small gold open-book pin. Her original expression and mouth images speak together while her head moves slightly; the body remains steady.

Individual source images were inspected directly. Combined native composition, light/dark edges, neck appearance during speech, physical iPhone, VoiceOver and audio timing remain for the native test workflow. No browser launch was attempted for this registration. The supporting art is an existing candidate; these measurements are not artist approval or a completed native visual review.
