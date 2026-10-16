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
            'eyeWide': ('faces', 3, 'eyes'),
            'smileUp': ('faces', 1, 'smile'),
            'smileDown': ('faces', 6, 'smile'),
            'cheekRaise': ('faces', 2, 'cheeks'),
        },
        # Mouth sheet signatures: open, wide, round, press (CharacterMotion.viseme notes).
        'visemes': [
            [0, 0, 0, 0], [0.3, 0, 0, 0], [0.6, 0.1, 0, 0], [0.7, 0, 0.7, 0], [0.25, 0, 1, 0],
            [0.35, 0.9, 0, 0], [0, 0, 0, 1], [0.15, 0.55, 0, 0.3], [1, 0.4, 0, 0],
        ],
    },
}


def load_sheet(name):
    f = [p for p in glob.glob(ASSETS + name + '.imageset/*') if not p.endswith('.json')][0]
    return np.asarray(Image.open(f).convert('RGB')).astype(np.float32) / 255


def panel(sheet, i):
    px, py = (i % 3) * PITCH, (i // 3) * PITCH
    return sheet[py:py + PANEL, px:px + PANEL]


def grid_axes():
    """Denser where small things move: lids and irises (y 128-166), lips (198-252),
    the face's width (x 150-300). Same axes for every 414 panel character."""
    ys = list(np.arange(0, 120, 12)) + list(np.arange(120, 134, 4)) + list(np.arange(134, 166, 2)) \
        + list(np.arange(166, 196, 6)) + list(np.arange(196, 256, 3)) + list(np.arange(256, 340, 8)) \
        + list(np.arange(340, 414, 14)) + [414]
    xs = list(np.arange(0, 150, 15)) + list(np.arange(150, 300, 4)) + list(np.arange(300, 414, 15)) + [414]
    return [float(v) for v in xs], [float(v) for v in ys]


def soft_ellipse(X, Y, x, y, rx, ry, inner=0.0):
    r = np.sqrt(((X - x) / rx) ** 2 + ((Y - y) / ry) ** 2)
    return np.clip((1 - r) / max(1e-6, 1 - inner), 0, 1)


def smooth01(v):
    v = np.clip(v, 0, 1)
    return v * v * (3 - 2 * v)


def region_mask(lm, name, X, Y):
    if name == 'brows':
        m = sum(smooth01(soft_ellipse(X, Y, b['x'], b['y'] + 2, b['w'] * 1.5, b['h'] * 2.6, 0.35)) for b in lm['brows'])
    elif name == 'eyes':
        m = sum(smooth01(soft_ellipse(X, Y, e['x'], e['y'], e['w'] * 1.7, 15, 0.4)) for e in lm['eyes'])
    elif name == 'cheeks':
        m = sum(smooth01(soft_ellipse(X, Y, c['x'], c['y'] - 10, c['r'] * 1.4, c['r'] * 1.8, 0.3)) for c in lm['cheeks'])
    elif name == 'smile':
        mo = lm['mouth']
        m = smooth01(soft_ellipse(X, Y, mo['x'], mo['y'] + 2, mo['w'] * 1.9, mo['h'] * 3.2, 0.3))
    elif name == 'mouthCore':
        mo = lm['mouth']
        m = smooth01(soft_ellipse(X, Y, mo['x'], mo['y'] + 3, mo['w'] * 1.35, mo['h'] * 1.7, 0.45))
    elif name == 'faceFlow':
        f = lm['face']
        m = smooth01(soft_ellipse(X, Y, f['x'], f['y'] + 14, f['rx'] * 1.02, f['ry'] * 1.06, 0.55))
    else:
        raise ValueError(name)
    return np.clip(m, 0, 1)


# Preset 2 is DIS 'medium' (the FINE name is missing from some builds).
_dis = cv2.DISOpticalFlow_create(2)


def gray(im):
    return cv2.cvtColor((np.clip(im, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2GRAY)


def face_flow(neutral, other, lm):
    """Where each neutral pixel's feature sits in `other`, limited to the face
    and made smooth inside the mouth, where lips part and flow cannot follow."""
    f = _dis.calc(gray(neutral), gray(other), None)
    Y, X = np.mgrid[0:PANEL, 0:PANEL].astype(np.float32)
    fine = cv2.GaussianBlur(f, (0, 0), 2.0)
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


def repair_folds(g, xs, ys, quality=0.3, rounds=200):
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
    return g


def pack(arr, scale=20):
    """Vectors as little-endian int16 at 1/20 px, base64."""
    q = np.clip(np.round(arr.reshape(-1) * scale), -32767, 32767).astype('<i2')
    return base64.b64encode(q.tobytes()).decode('ascii')


def build(name):
    c = CHARACTERS[name]
    lm = c['landmarks']
    faces, mouths, nuance = load_sheet(c['faces']), load_sheet(c['mouths']), load_sheet(c['nuance'])
    N = panel(faces, 0)
    xs, ys = grid_axes()
    Y, X = np.mgrid[0:PANEL, 0:PANEL].astype(np.float32)
    flows = {}
    report = {}
    for sheet_name, sheet, count in [('faces', faces, 9), ('nuance', nuance, 9), ('mouths', mouths, 9)]:
        for i in range(count):
            if sheet_name == 'faces' and i == 0:
                continue
            K = panel(sheet, i)
            f = face_flow(N, K, lm)
            if sheet_name == 'mouths':
                f = f * region_mask(lm, 'smile', X, Y)[..., None]
            flows[f'{sheet_name}.{i}'] = f
            g = at_grid(f, xs, ys)
            report[f'{sheet_name}.{i}'] = round(float(np.abs(g).max()), 2)
    keyforms = {}
    for key, (sheet_name, i, region) in c['keyforms'].items():
        f = flows[f'{sheet_name}.{i}'] * region_mask(lm, region, X, Y)[..., None]
        keyforms[key] = f
    rig = {
        'id': name, 'version': 1, 'panel': PANEL,
        'sheets': {'faces': c['faces'], 'mouths': c['mouths'], 'nuance': c['nuance'], 'pitch': PITCH},
        'mask': c['mask'], 'core': c['core'], 'regions': c['regions'],
        'landmarks': lm, 'visemes': c['visemes'],
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
