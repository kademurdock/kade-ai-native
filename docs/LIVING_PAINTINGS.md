# Living paintings

October 16, 2026. Design note for the painted main cast (Kiana, Della, Lilly and
Skylee's Lilly, Harley, Mrs. Witherspoon, Angel).

## In plain words

The painted characters used to move by swapping pictures: a whole painted
expression, a painted mouth or painted closed eyes faded in over a face that
otherwise stood still, while the head turned as one stiff piece. Kade's sister
noticed exactly that: the eyes blink and nothing else on the face moves.

A living painting keeps the same paintings and nothing else is drawn by a
computer. The painting is laid on an invisible rubber sheet of about four
thousand points. Moving the points bends the picture: the eyelid skin slides
down over the eye, the eyes look left and right inside the lids, the cheeks
rise into a smile, the jaw drops as she talks, the face turns a little as if
it were round, the neck bends when she tilts her head, and her curls sway.
When she changes expression or mouth shape, the sheet bends toward that
painted expression while its pixels fade in, so every painted face is reached
by moving, not by dissolving.

The body is decoration. The whole portrait stays hidden from VoiceOver and the
character is described in words, as before. Reduce Motion, Low Power Mode,
thermal pressure and the portrait's frame budget stop it exactly like the old
portrait.

## Where the motion comes from: the painter's own panels

Every rigged character already has 27 painted panels that line up with each
other: nine expressions, nine nuance expressions and nine mouth shapes, all
of the same face. Instead of cutting the painting into parts and painting the
hidden pieces underneath (the usual Live2D way, which needs new art), an
offline tool measures how every point of the neutral face moves to reach each
of the other panels (optical flow, OpenCV's DIS method, run on the developer's
computer). Those measurements are the rig's "keyforms":

- an expression panel's flow says where the brows, lids, cheeks and lips go
  for that expression;
- a mouth panel's flow says where the lips, chin and cheeks go for that mouth
  shape (smoothed inside the lips, where a mouth opening cannot be traced);
- regions of those flows become single channels: the brows of the surprised
  panel are "brow raise", the brows of the angry panel "brow furrow", the
  cheeks of the laughing panel "cheek raise", and so on.

The tool also relaxes any flow that would fold the sheet over itself
(painted panels are not perfectly registered), and the runtime checks for
folds in tests across thousands of random poses.

Flow settings matter: DIS refined to full resolution with small dense
patches measured about a third less registration error on the brows than the
library's preset, which removed a grey smear a reviewer saw on an inner brow
half-way into surprise. Mouth-panel flows stop at the nostrils (talking used
to flatten the nose), and the eye-widening keyform moves the lids around the
irises instead of enlarging them.

## The parts, and how each one is made

| Part | How it is made | New art needed? |
| --- | --- | --- |
| Head, face | the neutral panel itself, cut by the existing head matte | no |
| Upper lids | analytic lid remap per grid column: the skin between crease and lid slides down, the eye opening above the closed lash line folds into it; the lid lines are read where the current expression has already moved them, so a squinting face blinks from its squint; the painted closed-eye panel fades in as the lid arrives | no |
| Lower lids, squint | the same remap from below; cheeks push up with it | no |
| Irises, eye whites | the area inside the eye opening slides with the gaze, pinned at the lids (about 3.5 px each way on a 414 px panel) | no; a separate iris layer would allow larger glances |
| Brows | keyforms from the surprised, angry and worried panels | no |
| Upper and lower lip, mouth corners | smile keyforms and the mouth panels' flows | no |
| Mouth interior, teeth | the painted mouth panels themselves, faded in as the lips part | no for these nine shapes |
| Cheeks | keyforms from the laughing and smiling panels | no |
| Front hair, back hair | one hair region, swaying outside the face oval with the head's motion | no for short hair; long hair (Kiana's locs, Lilly) would look better with a separate back-hair layer |
| Neck | the matte's neck bends: a head roll fades out between chin and collar | no |
| Body | unchanged: each character's existing body plates and arms | no |

So the first version needs **no new art at all**. Optional extra layers that
would allow bigger movement, each one generated picture (about $0.14 each with
Gemini image generation, only with Kade's yes):

- a back-hair plate per long-haired character (Kiana, Lilly): 2 pictures;
- eye whites without irises plus loose irises, for wide glances: 1 picture per
  character, 6 in all;
- a hidden-side face edge for turns past about 10 degrees: not planned.

## The grid

One tensor grid per character over the 414-pixel neutral panel, built from
that face's own landmarks: rows 2 px apart across the lids (tilt included),
3 px across the lips, 4 to 8 px around them and about 13 px elsewhere;
columns 2 px apart across each eye, 4 px across the rest of the face and
15 px outside it. No row or column is ever closer than 1.5 px to the next.
Della's reviewed grid is 57 by 73 (4,161 points); the others are 80 to 84
columns by 70 to 83 rows (5,600 to 7,000 points), still far inside 16-bit
triangle indices.

## Channels to deformers

The channels are the shared motion engine's (PuppetMotion, web motion.mjs).
For painted characters the engine runs with `artFace`: an expression no
longer pushes the facial channels, because the painted panel already shows
the expression; head, gaze, body and every moving layer (breathing, glances,
blinks, speech, emphasis brow lifts, micro-expressions) stay.

| Channel | Deformer |
| --- | --- |
| mouth.open, mouth.wide, mouth.round, mouth.press | the two painted mouth panels nearest the shape (signatures open/wide/round/press per panel), weighted by closeness; the grid morphs toward their flows while their pixels fade in over the lips; a speaking mouth takes the lips over from the expression's own |
| mouth.smile | smile keyform (positive) or the sad panel's mouth keyform (negative) |
| eye.blink, eye.wink | upper lid remap; painted closed eyes fade in from 0.45 to 0.9 |
| eye.squint | lower lid rises and the upper lid lowers a quarter |
| eye.wide | surprised panel's eye keyform |
| gaze.x, gaze.y | iris slide inside each eye opening, resting as the lid closes |
| brow.raise, brow.furrow, brow.sad | keyforms from the surprised, angry and worried panels, averaged when several act at once |
| cheek.raise | laughing panel's cheek keyform |
| head.yaw, head.pitch | parallax: each point moves by its depth on an ellipsoid head with a nose bump (up to 9 and 6 degrees), so the features slide and the outline holds |
| head.roll | rotation about the neck pivot, fading to nothing between chin and collar (plus the body's own head angle) |
| body.breath | the existing body plates' lift, applied to the whole head too |
| hair.swing | the hair region outside the face, more toward the tips |

Draw order per frame, every layer on the same moving grid with its own
texture coordinates: neutral panel (cut by the head matte), the fading
expression panels, the speaking mouth panels, the painted closed eyes.

## On the phone

- The switch: "Living painted faces" in Settings, Feedback & Sounds
  (`LivingPaintingSetting`, stored as `kadeLivingPaintings`). On by default
  (Kade, Oct 16 2026: most people never open Settings); it greys out while
  Animated characters is off. Turning it off brings back the picture-swapping
  faces. Reduce Motion (system or in-app), Low Power Mode, heat and a
  backgrounded app hold the painting still, through the portrait's own gate.
- `LivingPaintingRig.swift`: the rig file and the per-frame grid. Pure
  arithmetic, pinned to the Python reference (`dev/living-paintings/lp_runtime.py`)
  by `LivingPaintingTests` within 0.002 px.
- `LivingPaintingRenderer.swift`: Metal. The shader is compiled from source on
  first use, so building the app needs no extra Metal toolchain. Pictures load
  once per character and are shared by every view; only the grid's positions
  change per frame (33 KB).
- `LivingPaintingView.swift`: the SwiftUI view (an `MTKView` that draws only
  when the portrait's own clock hands it a new frame), the cast list and the
  painted-face motion clock.
- `LivingPaintingGalleryView.swift`: the DEBUG comparison gallery (19 pages,
  every character; CI shoots them through `dev/puppet-gallery.sh`).
- `LivingPainting<Name>.json`: the rig, built by
  `python dev/living-paintings/lp_rig.py della Sources/LivingPaintingDella.json`
  (needs `pip install opencv-python-headless numpy pillow` on the developer's
  computer only).

Cost: one frame's grid took 0.044 ms on the CI Mac (optimized build,
LivingPaintingTests, Oct 16 2026). The slowest phone the app supports (iPhone
XS/XR, A12, iOS 17) is roughly three to four times slower per core, so about
0.15 to 0.2 ms, under 1% of one core at 30 frames a second; this is an
estimate, not yet measured on a phone. The GPU
draws at most six layers of 8,064 textured triangles over about 600 by 600
pixels, which is far below the old SwiftUI masks and blurs. Frame rates and
pauses follow the existing portrait budget (8 to 30 frames a second, none in
Low Power Mode, at serious thermal pressure or with Reduce Motion). The
pictures add about 25 MB of GPU memory while a living painting is on screen,
released on memory warnings.

## Web

The rig file is plain JSON and the runtime is a few hundred lines of
arithmetic, so the web port is the same grid drawn with WebGL: one
`drawElements` per layer with per-layer texture coordinates and the same
fragment masks, driven by `motion.mjs`. Canvas 2D textured triangles were
considered and rejected (seams between triangles, too slow at this density).

## The cast (October 16, 2026)

Every painted main character is a living painting: Della, Kiana, Harley,
Lilly (Skylee's Lilly wears the same paintings) and Mrs. Witherspoon. Angel is
drawn by code and already moves that way. Each rig comes only from that
character's own panels, and each head is cut exactly as its sliced portrait
was: a matte picture and face oval (Della, Harley) and the bust's own outline
(Lilly's tall stage keeps its extended neck-and-hood cut), composed once into
one matte that cuts every layer. Heads sit in their panel's own square of the
stage. On the square stage the painting also turns and bends the neck; on the
tall stage the body already turns the head as one piece, so the painting
warps only the face there.

| Character | What was special |
| --- | --- |
| Della | the first, reviewed grid; matte picture and face oval |
| Kiana | her painting is rolled, so each lid and lash line has its own slope; locs sway more and stop at the collar, so her sweater stays still; her face region is wide enough that her heart earrings move with her face |
| Harley | narrow eyes (about 10 px of lid travel) under heavy brows, so the stretched lid skin stays 6 px tall; matte picture and face oval; his laughing and delighted panels are painted with closed eyes, so they never blink |
| Lilly | big cartoon lids: 2 px mesh columns across the eyes, a taller lash line that slides down whole, closed lash lines with their own slopes, and the painted closed eyes fading in later, so her iris never shows through them; her tired face is painted half-shut and does not blink; her cats stay still beside her |
| Mrs. Witherspoon | nine basic faces only (no nuance sheet); her glasses' rim sits just above her lids, so the stretched lid skin is 2 px tall and the frames never bend; her crown touches the stage's top edge, so the top rows hold still and only her body's own limited turn tilts her head |

How well the motion matches each painting: the measured flow removes 25 to
40% of the difference between the neutral face and each other panel
(registration error over the face falls to 0.60 to 0.75 of the unmoved
difference; mouth panels least, since lips part where flow cannot follow).
Across 200 random realistic poses per character, the mesh folds over itself
in a few, almost all while a lid is nearly shut and under the painted closed
eyes; the folded area averages about 1 square panel pixel (worst 6 for Della,
15 for Lilly, under 1.2 for the others).

## Next: plan and cost

Nothing below needs paid art. Every step runs on the developer's computer
and the free GitHub macOS runners; a TestFlight build waits for Kade's word.

| Step | What it takes | Time | Money |
| --- | --- | --- | --- |
| Web | a WebGL copy of the runtime and renderer driven by `motion.mjs` (with the painted-face option mirrored), tested against the same golden file; the rig files served beside the characters' web pictures | 4 to 6 hours | none |
| Real phone check | the next TestFlight build, with a frame-time readout, to measure the oldest phone in use | one build | none |

Optional extra pictures, only with Kade's yes (about $0.14 each with Gemini
image generation): a back-hair plate for Kiana and one for Lilly, so long
hair can swing without the head's outline (2 pictures, about $0.28); loose
irises for wider glances (one per painted character, 5 pictures, about
$0.70). All seven together: about $1.

## Limits

- Turns stay small (about 9 degrees): nothing exists of the far side of a
  painted face.
- Glances are a few pixels; a separate iris layer would allow more.
- Flow cannot trace lips parting, so mouth interiors fade in as before, but
  now over a moving jaw and lips instead of a still face.
- Panels whose painted head sits differently (a tilted pose) morph by their
  flow; a panel that moves the whole head far (Della's skeptical panel, about
  21 px) moves the grid that far too.
