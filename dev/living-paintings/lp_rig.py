"""Living paintings: build a rig file from a character's existing painted sheets.

The rig is everything the phone needs besides the pictures themselves:
  * a tensor mesh grid over the 414-pixel neutral panel (denser at eyes/mouth),
  * per-panel "flows": where each neutral feature sits in every other painted
    panel (expression and mouth sheets), sampled at the grid vertices,
  * per-channel keyforms (brow raise, smile, ...) cut from those flows by
    soft region masks,
  * landmarks for the analytic deformers (lids, irises, head ellipsoid, neck).

No new art and no network: optical flow (OpenCV DIS) between the painter's own
panels supplies how the face moves. Run: python dev/living-paintings/lp_rig.py della Sources/LivingPaintingDella.json
"""
import base64
import glob
import json
import sys

import os  # noqa: E402

# Extra packages for this offline tool only (never shipped): pip install
# opencv-python-headless numpy pillow. LP_PYLIB may point at a private folder.
if os.environ.get('LP_PYLIB'):
    sys.path.insert(0, os.environ['LP_PYLIB'])
import cv2  # noqa: E402
import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
ASSETS = os.path.join(ROOT, 'Sources', 'Assets.xcassets') + '/'
PANEL = 414
PITCH = 420

CHARACTERS = {
    'della': {
        'faces': 'CharacterDellaFaces', 'mouths': 'CharacterDellaMouths', 'nuance': 'CharacterDellaNuance',
        'mask': {'asset': 'CharacterDellaBustMask', 'x': 35, 'y': 0, 'side': 350},
        'core': {'x': 219, 'y': 193, 'rx': 73, 'ry': 91},
        # Regions the old rig dissolves inside (Sheet face/mouth/eyes rects x 414).
        'regions': {
            'face': [0.3, 0.2, 0.46, 0.56, 0.72],
            'mouth': [0.38, 0.46, 0.3, 0.19, 0.5],
            'eyes': [0.34, 0.29, 0.38, 0.14, 0.6],
        },
        'landmarks': {
            'face': {'x': 219, 'y': 178, 'rx': 82, 'ry': 104},
            'head': {'x': 214, 'y': 150, 'rx': 168, 'ry': 158, 'rz': 92},
            'nose': {'x': 222, 'y': 184, 'r': 20, 'z': 18},
            'eyes': [
                {'x': 187, 'y': 151, 'w': 17, 'upper': 143.5, 'closed': 155, 'lower': 158.5, 'crease': 10, 'iris': 6.5},
                {'x': 257, 'y': 150, 'w': 17, 'upper': 143, 'closed': 155, 'lower': 158, 'crease': 10, 'iris': 6.5},
            ],
            'brows': [
                {'x': 185, 'y': 126, 'w': 26, 'h': 10, 'inner': 1},
                {'x': 259, 'y': 125, 'w': 26, 'h': 10, 'inner': -1},
            ],
            'mouth': {'x': 223, 'y': 222, 'w': 40, 'h': 16},
            'cheeks': [{'x': 172, 'y': 192, 'r': 26}, {'x': 272, 'y': 192, 'r': 26}],
            'neck': {'x': 219, 'y': 306, 'chin': 262, 'collar': 336},
            'hair': {'x': 214, 'y': 140, 'inner': 0.62, 'outer': 1.0, 'reach': 2.2},
        },
        # Which painted panel each keyform is cut from, and through which region.
        'keyforms': {
            'browRaise': ('faces', 3, 'brows'),
            'browFurrow': ('faces', 5, 'brows'),
            'browSad': ('faces', 7, 'brows'),
            'eyeWide': ('faces', 3, 'eyeLids'),
            'smileUp': ('faces', 1, 'smile'),
            'smileDown': ('faces', 6, 'smile'),
            'cheekRaise': ('faces', 2, 'cheeks'),
        },
        # Mouth sheet signatures: open, wide, round, press (CharacterMotion.viseme notes).
        'visemes': [
            [0, 0, 0, 0], [0.3, 0, 0, 0], [0.6, 0.1, 0, 0], [0.7, 0, 0.7, 0], [0.25, 0, 1, 0],
            [0.35, 0.9, 0, 0], [0, 0, 0, 1], [0.15, 0.55, 0, 0.3], [1, 0.4, 0, 0],
        ],
        # Della's grid was reviewed first; she keeps her own axes.
        'legacyGrid': True,
    },
}

KEYFORMS = CHARACTERS['della']['keyforms']
VISEMES = CHARACTERS['della']['visemes']

# Oct 16 2026: the rest of the painted cast. Every sheet keeps the same panel
# order (CharacterFace, CharacterMotion.viseme). Landmarks are panel pixels,
# measured on gridded crops of each neutral and closed-eye panel; neck pivots
# and mattes come from each CharacterBustArtwork (world -> panel pixels).
# `tilt` is an eye's lash-line slope (her painting's head roll plus the
# eye's own corner tilt); `pinTop` holds the top rows still where a crown
# touches the stage's top edge; `rollChannel` scales the engine's own roll;
# `noBlinkFaces` are panels whose eyes are already painted closed
# (CharacterFacialPolicy.shouldBlink).
CHARACTERS.update({
    'kiana': {
        'faces': 'CharacterKianaFaces', 'mouths': 'CharacterKianaMouths', 'nuance': 'CharacterKianaNuance',
        'mask': None, 'core': None,
        'regions': {
            'face': [0.34, 0.17, 0.5, 0.56, 0.72],
            'mouth': [0.43, 0.46, 0.31, 0.2, 0.5],
            'eyes': [0.36, 0.27, 0.44, 0.15, 0.6],
        },
        'landmarks': {
            # Wide enough that her earrings move with her face instead of
            # doubling while an expression fades in.
            'face': {'x': 243, 'y': 172, 'rx': 95, 'ry': 104},
            'head': {'x': 240, 'y': 152, 'rx': 160, 'ry': 168, 'rz': 90},
            'nose': {'x': 233, 'y': 186, 'r': 18, 'z': 16},
            'eyes': [
                {'x': 193, 'y': 156, 'w': 17, 'upper': 150, 'closed': 159, 'lower': 163, 'crease': 9, 'iris': 6,
                 'tilt': 0.1, 'closedTilt': -0.07},
                {'x': 270, 'y': 146, 'w': 20, 'upper': 140, 'closed': 150, 'lower': 153, 'crease': 9, 'iris': 7,
                 'tilt': -0.3, 'closedTilt': -0.19},
            ],
            'brows': [
                {'x': 190, 'y': 124, 'w': 25, 'h': 8, 'inner': 1},
                {'x': 266, 'y': 113, 'w': 25, 'h': 9, 'inner': -1},
            ],
            'mouth': {'x': 242, 'y': 224, 'w': 36, 'h': 14},
            'cheeks': [{'x': 192, 'y': 196, 'r': 24}, {'x': 286, 'y': 186, 'r': 24}],
            'neck': {'x': 240, 'y': 291, 'chin': 268, 'collar': 330},
            'hair': {'x': 240, 'y': 140, 'inner': 0.62, 'outer': 1.0, 'reach': 3.0},
        },
        'noBlinkFaces': ['faces.2'],
    },
    'harley': {
        'faces': 'CharacterHarleyFaces', 'mouths': 'CharacterHarleyMouths', 'nuance': 'CharacterHarleyNuance',
        'mask': {'asset': 'CharacterHarleyBustMask', 'x': 0, 'y': 0, 'side': 414},
        'core': {'x': 220.1, 'y': 199.3, 'rx': 62.3, 'ry': 73.9},
        'regions': {
            'face': [0.28, 0.24, 0.52, 0.5, 0.72],
            'mouth': [0.41, 0.47, 0.27, 0.22, 0.5],
            'eyes': [0.34, 0.31, 0.42, 0.13, 0.6],
        },
        'landmarks': {
            'face': {'x': 228, 'y': 182, 'rx': 78, 'ry': 105},
            'head': {'x': 226, 'y': 165, 'rx': 135, 'ry': 160, 'rz': 88},
            'nose': {'x': 226, 'y': 190, 'r': 18, 'z': 16},
            'eyes': [
                {'x': 190, 'y': 154, 'w': 17, 'upper': 149, 'closed': 158, 'lower': 159.5, 'crease': 6, 'iris': 6, 'tilt': 0},
                {'x': 263, 'y': 154, 'w': 18, 'upper': 149, 'closed': 158, 'lower': 159.5, 'crease': 6, 'iris': 6, 'tilt': 0},
            ],
            'brows': [
                {'x': 188, 'y': 141, 'w': 26, 'h': 7, 'inner': 1},
                {'x': 262, 'y': 140, 'w': 26, 'h': 7, 'inner': -1},
            ],
            'mouth': {'x': 230, 'y': 224, 'w': 33, 'h': 12},
            'cheeks': [{'x': 180, 'y': 196, 'r': 24}, {'x': 276, 'y': 196, 'r': 24}],
            'neck': {'x': 207, 'y': 334.7, 'chin': 280, 'collar': 330},
            'hair': {'x': 226, 'y': 100, 'inner': 0.62, 'outer': 1.0, 'reach': 1.0},
        },
        'noBlinkFaces': ['faces.2', 'nuance.8'],
    },
    'lilly': {
        'faces': 'CharacterLillyFaces', 'mouths': 'CharacterLillyMouths', 'nuance': 'CharacterLillyNuance',
        'mask': None, 'core': None,
        'regions': {
            'face': [0.38, 0.2, 0.46, 0.5, 0.72],
            'mouth': [0.48, 0.48, 0.28, 0.2, 0.5],
            'eyes': [0.4, 0.3, 0.42, 0.18, 0.9],
        },
        'landmarks': {
            'face': {'x': 255, 'y': 175, 'rx': 76, 'ry': 100},
            'head': {'x': 255, 'y': 150, 'rx': 150, 'ry': 165, 'rz': 85},
            'nose': {'x': 262, 'y': 202, 'r': 16, 'z': 16},
            'eyes': [
                {'x': 219, 'y': 165, 'w': 23, 'upper': 152, 'closed': 176, 'lower': 178, 'crease': 9, 'iris': 12,
                 'tilt': 0.2, 'closedTilt': 0.21, 'lash': 5},
                {'x': 296, 'y': 178, 'w': 17, 'upper': 166, 'closed': 189, 'lower': 192, 'crease': 11, 'iris': 11,
                 'tilt': -0.3, 'closedTilt': 0.14, 'lash': 5},
            ],
            'brows': [
                {'x': 215, 'y': 140, 'w': 28, 'h': 8, 'inner': 1},
                {'x': 300, 'y': 150, 'w': 22, 'h': 8, 'inner': -1},
            ],
            'mouth': {'x': 257, 'y': 230, 'w': 35, 'h': 10},
            'cheeks': [{'x': 205, 'y': 198, 'r': 22}, {'x': 305, 'y': 205, 'r': 20}],
            'neck': {'x': 242.4, 'y': 304.5, 'chin': 272, 'collar': 300},
            'hair': {'x': 255, 'y': 140, 'inner': 0.62, 'outer': 1.0, 'reach': 2.5},
        },
        # Her tired face (nuance.6) already has half-shut cartoon lids.
        'noBlinkFaces': ['faces.2', 'nuance.6'],
        # Her big lids close fully before the painted closed eyes take over,
        # so her iris never shows through them.
        'closedFade': [0.5, 0.45],
    },
    'witherspoon': {
        # Nine basic faces only (no nuance sheet); glasses sit right above the
        # lids, so the lid skin stretch stays 2 px tall, under the rim; her
        # crown touches the stage's top edge, so the top rows hold still and
        # the engine's own roll is off (the body's limited turn still applies).
        'faces': 'CharacterWitherspoonFaces', 'mouths': 'CharacterWitherspoonMouths', 'nuance': None,
        'mask': None, 'core': None,
        'regions': {
            'face': [0.29, 0.23, 0.44, 0.49, 0.72],
            'mouth': [0.38, 0.50, 0.26, 0.19, 0.5],
            'eyes': [0.30, 0.32, 0.41, 0.15, 0.6],
        },
        'landmarks': {
            'face': {'x': 212, 'y': 180, 'rx': 76, 'ry': 100},
            'head': {'x': 212, 'y': 150, 'rx': 160, 'ry': 165, 'rz': 88},
            'nose': {'x': 211, 'y': 198, 'r': 18, 'z': 16},
            'eyes': [
                {'x': 166, 'y': 158, 'w': 19, 'upper': 153, 'closed': 162, 'lower': 165, 'crease': 2, 'iris': 6, 'tilt': 0},
                {'x': 246, 'y': 157, 'w': 19, 'upper': 152, 'closed': 162, 'lower': 164, 'crease': 2, 'iris': 6, 'tilt': 0},
            ],
            'brows': [
                {'x': 165, 'y': 140, 'w': 24, 'h': 7, 'inner': 1},
                {'x': 247, 'y': 139, 'w': 24, 'h': 7, 'inner': -1},
            ],
            'mouth': {'x': 211, 'y': 234, 'w': 30, 'h': 10},
            'cheeks': [{'x': 165, 'y': 205, 'r': 22}, {'x': 258, 'y': 205, 'r': 22}],
            'neck': {'x': 207, 'y': 300.5, 'chin': 272, 'collar': 300},
            'hair': {'x': 212, 'y': 120, 'inner': 0.62, 'outer': 1.0, 'reach': 2.0},
            'pinTop': 45, 'rollChannel': 0,
        },
        'noBlinkFaces': [],
    },
})
for _name, _c in CHARACTERS.items():
    _c.setdefault('keyforms', KEYFORMS)
    _c.setdefault('visemes', VISEMES)
    _c.setdefault('noBlinkFaces', [])


def load_sheet(name):
    f = [p for p in glob.glob(ASSETS + name + '.imageset/*') if not p.endswith('.json')][0]
    return np.asarray(Image.open(f).convert('RGB')).astype(np.float32) / 255


def panel(sheet, i):
    px, py = (i % 3) * PITCH, (i // 3) * PITCH
    return sheet[py:py + PANEL, px:px + PANEL]


def legacy_axes():
    """Della's reviewed grid: lids and irises (y 128-166), lips (198-252), the
    face's width (x 150-300)."""
    ys = list(np.arange(0, 120, 12)) + list(np.arange(120, 134, 4)) + list(np.arange(134, 166, 2)) \
        + list(np.arange(166, 196, 6)) + list(np.arange(196, 256, 3)) + list(np.arange(256, 340, 8)) \
        + list(np.arange(340, 414, 14)) + [414]
    xs = list(np.arange(0, 150, 15)) + list(np.arange(150, 300, 4)) + list(np.arange(300, 414, 15)) + [414]
    return [float(v) for v in xs], [float(v) for v in ys]


def axis(bands, coarse, lo=0.0, hi=float(PANEL)):
    """One grid axis: each (start, end, step) band evenly divided, the gaps
    between bands at about `coarse` pixels."""
    points = []
    cursor = lo
    for a, b, step in sorted(bands):
        a, b = max(a, cursor), min(b, hi)
        if b <= a:
            continue
        if a > cursor:
            n = max(1, int(np.ceil((a - cursor) / coarse)))
            points += list(np.linspace(cursor, a, n + 1)[:-1])
        n = max(1, int(np.ceil((b - a) / step)))
        points += list(np.linspace(a, b, n + 1)[:-1])
        cursor = b
    n = max(1, int(np.ceil((hi - cursor) / coarse)))
    points += list(np.linspace(cursor, hi, n + 1))
    # No sliver rows or columns where two bands meet: a cell thinner than
    # 1.5 px folds at the slightest stretch.
    kept = []
    for p in sorted(points):
        if not kept or p - kept[-1] >= 1.5:
            kept.append(p)
    kept[-1] = hi
    return [round(float(p), 3) for p in kept]


def finest(bands):
    """Overlapping (start, end, step) bands as one sorted, non-overlapping
    list, each stretch taking the finest step that covers it."""
    cuts = sorted({p for a, b, _ in bands for p in (a, b)})
    out = []
    for a, b in zip(cuts, cuts[1:]):
        steps = [s for x, y, s in bands if x <= a and b <= y]
        if steps:
            if out and out[-1][2] == min(steps) and abs(out[-1][1] - a) < 1e-9:
                out[-1] = (out[-1][0], b, min(steps))
            else:
                out.append((a, b, min(steps)))
    return out


def grid_axes(c):
    """Dense where this face's small things move: 2 px across the lids and
    irises (tilt included), 3 px across the lips, 4 px across the face."""
    if c.get('legacyGrid'):
        return legacy_axes()
    lm = c['landmarks']
    eyes, mo, brows = lm['eyes'], lm['mouth'], lm['brows']
    eye_top = min(e['upper'] - e['crease'] - abs(e.get('tilt', 0)) * e['w'] - 4 for e in eyes)
    eye_bottom = max(e['lower'] + abs(e.get('tilt', 0)) * e['w'] + 10 for e in eyes)
    brow_top = min(b['y'] - b['h'] - 10 for b in brows)
    mouth_top, mouth_bottom = mo['y'] - mo['h'] - 12, mo['y'] + mo['h'] + 16
    ys = axis([(brow_top, eye_top, 4), (eye_top, eye_bottom, 2), (eye_bottom, mouth_top, 6),
               (mouth_top, mouth_bottom, 3), (mouth_bottom, lm['neck']['collar'] + 10, 8)], 13)
    left = min(min(e['x'] - e['w'] - 18 for e in eyes), mo['x'] - mo['w'] - 16)
    right = max(max(e['x'] + e['w'] + 18 for e in eyes), mo['x'] + mo['w'] + 16)
    # 2 px columns across each eye: a closing lid shears its cells, and wide
    # cells turn a lash line into a sawtooth.
    xs = axis(finest([(left, right, 4)] + [(e['x'] - e['w'] - 6, e['x'] + e['w'] + 6, 2) for e in eyes]), 15)
    return xs, ys


def soft_ellipse(X, Y, x, y, rx, ry, inner=0.0):
    r = np.sqrt(((X - x) / rx) ** 2 + ((Y - y) / ry) ** 2)
    return np.clip((1 - r) / max(1e-6, 1 - inner), 0, 1)


def smooth01(v):
    v = np.clip(v, 0, 1)
    return v * v * (3 - 2 * v)


def region_mask(lm, name, X, Y):
    if name == 'brows':
        # Brows and forehead only: the lashes and the eye opening stay put, so
        # a lifting brow stretches the lid skin instead of smearing the lashes.
        m = sum(smooth01(soft_ellipse(X, Y, b['x'], b['y'] + 2, b['w'] * 1.5, b['h'] * 2.6, 0.35)) for b in lm['brows'])
        for e in lm['eyes']:
            m = m * (1 - smooth01(soft_ellipse(X, Y, e['x'], e['y'], e['w'] * 1.25,
                                               (e['lower'] - e['upper']) / 2 + 4, 0.4)))
    elif name == 'eyes':
        m = sum(smooth01(soft_ellipse(X, Y, e['x'], e['y'], e['w'] * 1.7, 15, 0.4)) for e in lm['eyes'])
    elif name == 'cheeks':
        # Cheeks without the eye opening: some laughing panels close the eyes,
        # which a cheek lift must not drag along.
        m = sum(smooth01(soft_ellipse(X, Y, c['x'], c['y'] - 10, c['r'] * 1.4, c['r'] * 1.8, 0.3)) for c in lm['cheeks'])
        for e in lm['eyes']:
            m = m * (1 - smooth01(soft_ellipse(X, Y, e['x'], e['y'], e['w'] * 1.25,
                                               (e['lower'] - e['upper']) / 2 + 4, 0.4)))
    elif name == 'smile':
        mo = lm['mouth']
        m = smooth01(soft_ellipse(X, Y, mo['x'], mo['y'] + 2, mo['w'] * 1.9, mo['h'] * 3.2, 0.3))
    elif name == 'mouthPanels':
        # A mouth shape moves lips, jaw and cheeks but stops at the nostrils
        # (the review saw talking flatten her nose).
        mo, no = lm['mouth'], lm['nose']
        m = smooth01(soft_ellipse(X, Y, mo['x'], mo['y'] + 2, mo['w'] * 1.9, mo['h'] * 3.2, 0.3)) \
            * smooth01((Y - (no['y'] + 10)) / 12)
    elif name == 'eyeLids':
        # Lids and the skin around them, never the irises themselves: a
        # widening eye shows more white instead of a bigger iris.
        m = sum(smooth01(soft_ellipse(X, Y, e['x'], e['y'], e['w'] * 1.7, 15, 0.4))
                * (1 - smooth01(soft_ellipse(X, Y, e['x'], e['y'], e['iris'] * 1.6, e['iris'] * 1.6, 0.55)))
                for e in lm['eyes'])
    elif name == 'mouthCore':
        mo = lm['mouth']
        m = smooth01(soft_ellipse(X, Y, mo['x'], mo['y'] + 3, mo['w'] * 1.35, mo['h'] * 1.7, 0.45))
    elif name == 'faceFlow':
        f = lm['face']
        m = smooth01(soft_ellipse(X, Y, f['x'], f['y'] + 14, f['rx'] * 1.02, f['ry'] * 1.06, 0.55))
    else:
        raise ValueError(name)
    return np.clip(m, 0, 1)


# DIS from the 'medium' preset (2; the FINE name is missing from some
# builds), refined down to full resolution with small dense patches: about a
# third less registration error on the brows than the preset alone.
_dis = cv2.DISOpticalFlow_create(2)
_dis.setFinestScale(0)
_dis.setPatchSize(6)
_dis.setPatchStride(2)
_dis.setGradientDescentIterations(40)
_dis.setVariationalRefinementIterations(15)


def gray(im):
    return cv2.cvtColor((np.clip(im, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY)


def face_flow(neutral, other, lm):
    """Where each neutral pixel's feature sits in `other`, limited to the face
    and made smooth inside the mouth, where lips part and flow cannot follow."""
    f = _dis.calc(gray(neutral), gray(other), None)
    Y, X = np.mgrid[0:PANEL, 0:PANEL].astype(np.float32)
    fine = cv2.GaussianBlur(f, (0, 0), 1.0)
    coarse = cv2.GaussianBlur(f, (0, 0), 9.0)
    core = region_mask(lm, 'mouthCore', X, Y)[..., None]
    g = fine * (1 - core) + coarse * core
    return g * region_mask(lm, 'faceFlow', X, Y)[..., None]


def at_grid(field, xs, ys):
    """Sample a (414, 414, 2) field at the tensor grid's vertices."""
    gx, gy = np.meshgrid(np.array(xs, np.float32), np.array(ys, np.float32))
    gx = np.clip(gx, 0, PANEL - 1)
    gy = np.clip(gy, 0, PANEL - 1)
    out = np.stack([cv2.remap(field[..., i].astype(np.float32), gx, gy, cv2.INTER_LINEAR) for i in range(2)], -1)
    return out


def repair_folds(g, xs, ys, quality=0.3, rounds=1500):
    """Relax a grid displacement field until no mesh cell shrinks below
    `quality` of its rest area or turns inside out. Painted panels are not
    perfectly registered and raw flow can fold; a fold would tear the face."""
    g = g.copy()
    X, Y = np.meshgrid(np.array(xs), np.array(ys))
    R, C = X.shape
    for _ in range(rounds):
        px, py = X + g[..., 0], Y + g[..., 1]
        bad = np.zeros((R, C), bool)
        for (a, b, c) in [((0, 0), (0, 1), (1, 1)), ((0, 0), (1, 1), (1, 0))]:
            def P(arr, o):
                return arr[o[0]:R - 1 + o[0], o[1]:C - 1 + o[1]]
            area = (P(px, b) - P(px, a)) * (P(py, c) - P(py, a)) - (P(px, c) - P(px, a)) * (P(py, b) - P(py, a))
            rest = (P(X, b) - P(X, a)) * (P(Y, c) - P(Y, a)) - (P(X, c) - P(X, a)) * (P(Y, b) - P(Y, a))
            low = area / rest < quality
            for o in (a, b, c):
                bad[o[0]:R - 1 + o[0], o[1]:C - 1 + o[1]] |= low
        if not bad.any():
            return g
        pad = np.pad(g, ((1, 1), (1, 1), (0, 0)), mode='edge')
        mean = (pad[:-2, 1:-1] + pad[2:, 1:-1] + pad[1:-1, :-2] + pad[1:-1, 2:]) / 4
        g[bad] = 0.35 * g[bad] + 0.65 * mean[bad] * 0.97
        if _ > 300:
            # Still folding next to a big motion: shrink it there, which
            # always ends (no motion cannot fold).
            g[bad] *= 0.9
    return g


def pack(arr, scale=20):
    """Vectors as little-endian int16 at 1/20 px, base64."""
    q = np.clip(np.round(arr.reshape(-1) * scale), -32767, 32767).astype('<i2')
    return base64.b64encode(q.tobytes()).decode('ascii')


def build(name):
    c = CHARACTERS[name]
    lm = c['landmarks']
    faces, mouths = load_sheet(c['faces']), load_sheet(c['mouths'])
    nuance = load_sheet(c['nuance']) if c['nuance'] else None
    N = panel(faces, 0)
    xs, ys = grid_axes(c)
    Y, X = np.mgrid[0:PANEL, 0:PANEL].astype(np.float32)
    flows = {}
    report = {}
    sheets = [('faces', faces, 9), ('nuance', nuance, 9), ('mouths', mouths, 9)]
    for sheet_name, sheet, count in [s for s in sheets if s[1] is not None]:
        for i in range(count):
            if sheet_name == 'faces' and i == 0:
                continue
            K = panel(sheet, i)
            f = face_flow(N, K, lm)
            if sheet_name == 'mouths':
                f = f * region_mask(lm, 'mouthPanels', X, Y)[..., None]
            flows[f'{sheet_name}.{i}'] = f
            g = at_grid(f, xs, ys)
            report[f'{sheet_name}.{i}'] = round(float(np.abs(g).max()), 2)
    keyforms = {}
    for key, (sheet_name, i, region) in c['keyforms'].items():
        f = flows[f'{sheet_name}.{i}'] * region_mask(lm, region, X, Y)[..., None]
        # A surprised panel's lids open far; on its own, as a channel, 60% of
        # that reads as widening without stretching the lid skin.
        keyforms[key] = f * (0.6 if key == 'eyeWide' else 1.0)
    rig = {
        'id': name, 'version': 1, 'panel': PANEL,
        'sheets': {'faces': c['faces'], 'mouths': c['mouths'], 'nuance': c['nuance'], 'pitch': PITCH},
        'mask': c['mask'], 'core': c['core'], 'regions': c['regions'],
        'landmarks': lm, 'visemes': c['visemes'], 'noBlinkFaces': c['noBlinkFaces'],
        'closedFade': c.get('closedFade', [0.45, 0.45]),
        'gridX': xs, 'gridY': ys,
        'flowScale': 20,
        'flows': {k: pack(repair_folds(at_grid(v, xs, ys), xs, ys)) for k, v in flows.items()},
        'keyforms': {k: pack(repair_folds(at_grid(v, xs, ys), xs, ys)) for k, v in keyforms.items()},
    }
    return rig, flows, keyforms, report


if __name__ == '__main__':
    rig, flows, keyforms, report = build(sys.argv[1])
    with open(sys.argv[2], 'w', encoding='utf-8', newline='') as out:
        json.dump(rig, out, separators=(',', ':'))
    print('grid', len(rig['gridX']), 'x', len(rig['gridY']), 'max flow', report)
