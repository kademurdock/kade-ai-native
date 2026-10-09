# Simulator-only source art

These masters are development review inputs. `prepare-puppet-review.py` verifies
their exact hashes and RGBA canvases before staging ignored asset-catalog entries.
Clean release workflows do not stage them.

Harley's `body.png` and `mask.png` are unchanged experimental denim-body and
head-alpha assets from the October 8 exact-atlas study. His face RGB continues
to come from the existing approved native atlas.

Lilly's `lilly-body-support.png` is the unchanged transparent hoodie output from
one built-in ImageGen call on October 9. Her original face and both cats are
drawn from the existing native atlas using authored code outlines. The generated
asset does not supply face RGB. The full prompt and candidate notes are preserved
in the workspace at `expressive-faces/cast-concepts/lilly/native-bust-20261009`.

Exact prompt for the Lilly support image:

Use case: stylized-concept. Asset type: transparent body-only supporting layer for an on-device illustrated character puppet; the original reference face and cats will be composited separately and must NOT be generated here. Input image 1 is the established Lilly portrait and is used ONLY for the rich soft dimensional illustration style, lilac hoodie material and three-quarter shoulder orientation. Produce a 1024 by 1024 square transparent RGBA image containing ONLY Lilly's headless lilac hoodie torso and shoulders with two relaxed bent arms and both hands visible low near her waist. Keep the hoodie back/shoulder three-quarter pose compatible with the reference: viewer-left shoulder slightly nearer, torso gently angled, facing toward viewer-right. Use a broad upright hood opening/neckline centered near x550 y485, with the hood rim filling x360..680 and y455..570. The entire area above y435 must be transparent; do not draw a head, face, neck stump, hair or cats. Shoulders begin near y500, elbows fit between x110 and x915, torso and hands end near y950; keep all limbs inside generous canvas margins. Make the center under the absent head fully painted lilac fabric, with sufficient hidden cloth overlap for compositing the real hair and face on top. Consistent soft pink-lilac fleece, subtle warm illumination and purple shadow, attractive dimensional illustrated folds. No jewelry, text, scenery, floor, shadow on background, neck anatomy, fake checkerboard, extra hands or extra limbs. This is a supporting art plate, not a completed person or new character portrait. Real transparent background.
