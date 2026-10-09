# Della native bust registration

Registration authored 2026-10-09 for the original public Della portrait. This is source geometry for native review; an iPhone/simulator visual pass is still required.

## Source identity and channels

- Agent: `agent_BSOLa3eNEZyjs-7abCjMt`.
- Exact avatar filename: `agent-agent_BSOLa3eNEZyjs-7abCjMt-avatar-1788941611099.png`.
- Face RGB remains `CharacterDellaFaces`, with the existing `CharacterDellaMouths` and `CharacterDellaNuance` patch compositor. Their original 1254-square sheets use 414-square panels at pitch 420. No face or mouth asset is replaced.
- `della-body-plate.png` is a byte-identical copy of `cast-concepts/della/native-bust-20261009/della-body-plate-review.png` in the parent `expressive-faces` repository, originally `cast-concepts/della/production-experiment/torso-only-imagegen-edit.png`.
- `della-head-alpha.png` is a byte-identical copy of the existing `della-head-matte-candidate.png` in that candidate folder. It is an RGBA extraction result, but the native compositor must consume **alpha only**. The generated face RGB must never be displayed.
- Existing extraction prompt/provenance: `cast-concepts/della/native-bust-20261009/generation-prompt.txt` and `manifest.json` in the parent `expressive-faces` repository. No new image generation was performed for this registration.

| Copied file | Pixels | SHA-256 |
| --- | --- | --- |
| `della-body-plate.png` | 1254 × 1254 | `e0709e31501d6b3e2b59a18c7cff93e1012b411e489b9ba9f956e8b72281018e` |
| `della-head-alpha.png` | 1254 × 1254 | `036d2ce6292fec1cb0226fe69f584789d46eadf4625e925e293ed717fecc1b1a` |

## Native contract

`CharacterDellaBustGeometry.artwork` supplies Foundation model data; `headPath` is available under `canImport(SwiftUI) && !CHARACTER_MODEL_TESTS`.

| Element | World coordinates |
| --- | --- |
| Close viewport and original neutral panel | x 0, y 0, side 414 |
| Body destination | x -132, y -1, width/height 677.16 |
| Alpha image destination | x 35, y 0, side 350 |
| Opaque original-face core | center 219,193; radii 73,91 |
| Head pivot | 219,306 |
| Body pivot | 207,454 |
| Motion bounds | head ±1.55° / ±0.65 world px; body ±0.16° / 0 px |

The alpha destination is deliberately different from the original panel destination. Mapping it to the full 414-square panel would expose the old teal backdrop and misregister the neck. `headPath` is the full original 414-square panel because the matte already does the extraction. The generated alpha and opaque face ellipse are multiplied by that panel clip. Body sleeves remain one plate; there are no articulated arms or hands. Existing expression, mouth and blink patches remain within the same transformed head.

Use asset names `CharacterDellaBustBody` and `CharacterDellaBustMask`. The shared renderer must apply its exact ID/avatar gate, both-resource availability check, stage requirement and minimum 160-point size. Compact portraits retain their existing rendering.

## Static evidence and remaining review

Asset hashes match the inspected candidates. The selected alpha registration had 8 obvious teal pixels among 69,432 pixels with alpha at least 230 (0.012%) in the prior read-only image analysis; this is a narrow color heuristic, not edge approval. A read-only integer-grid probe inverse-transformed head and body into the unchanged alpha images. At the browser candidate's body y 0, one central collar pixel fell to approximately alpha 197 at some extreme poses. Raising the body one world pixel to y -1 removes that small thin point. The central collar window x 180–259/y 290–389 now has no pixels where both body and head alpha are below 200 in 12 combinations: head -1.55°, 0°, +1.55°; head offset ±0.65; body ±0.16°. This is bounded central coverage, not a full rendered seam or antialiasing test. Original face/mouth/nuance bytes are unchanged.

Accessible visual description: an older Black woman with short silver curls, gold hoop earrings, a plum cardigan and a cream blouse. Her familiar face provides the expressions; the head makes small steady movements above a separate cardigan plate.

The earlier browser composition launch was rejected by automatic approval review with the generic reason “blocked by policy”; it was not retried. Browser composition QA remains unverified. Native composition, light/dark edges, animated neck overlap, physical iPhone, VoiceOver and audio timing require the separately authorized native test workflow. Do not treat the static measurements as a visual acceptance of the finished puppet.
