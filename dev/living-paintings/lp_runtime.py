"""Living paintings runtime: the per-frame math the phone (and later the web)
runs. Pure numpy over the rig's grid vertices; the Swift port must match this
file line for line (lp_golden.json pins it).

Order, like a Live2D deformer tree:
  painted morphs (expression + mouth panels' flows, channel keyforms)
  -> eyes (gaze, lids) and hair -> head turn parallax -> neck roll -> lift
"""
import base64
import json
import math

import numpy as np

CHANNELS = [
    "head.yaw", "head.pitch", "head.roll", "body.breath", "body.shrug",
    "gaze.x", "gaze.y", "eye.blink", "eye.wink", "eye.squint", "eye.wide",
    "brow.raise", "brow.furrow", "brow.sad", "brow.asym",
    "mouth.open", "mouth.wide", "mouth.round", "mouth.smile", "mouth.press",
    "cheek.raise", "cheek.blush", "hair.swing", "extras.flap", "extras.float",
]
YAW_DEGREES = 9.0
PITCH_DEGREES = 6.0
ROLL_DEGREES = 5.0


def unpack(text, scale):
    return np.frombuffer(base64.b64decode(text), dtype='<i2').astype(np.float64) / scale


def smooth01(v):
    v = np.clip(v, 0, 1)
    return v * v * (3 - 2 * v)


def bump(r2):
    """(1 - r^2)^2 inside the unit circle: smooth, zero slope at the edge."""
    t = np.clip(1 - r2, 0, 1)
    return t * t


def soft_ellipse(X, Y, x, y, rx, ry, inner):
    r = np.sqrt(((X - x) / rx) ** 2 + ((Y - y) / ry) ** 2)
    return np.clip((1 - r) / max(1e-6, 1 - inner), 0, 1)


class Rig:
    def __init__(self, path):
        self.data = d = json.load(open(path))
        self.lm = d['landmarks']
        self.gx = np.array(d['gridX'])
        self.gy = np.array(d['gridY'])
        self.cols, self.rows = len(self.gx), len(self.gy)
        X, Y = np.meshgrid(self.gx, self.gy)
        self.X, self.Y = X.reshape(-1), Y.reshape(-1)
        n = self.X.size
        self.flows = {k: unpack(v, d['flowScale']).reshape(n, 2) for k, v in d['flows'].items()}
        self.keyforms = {k: unpack(v, d['flowScale']).reshape(n, 2) for k, v in d['keyforms'].items()}
        lm = self.lm
        mo = lm['mouth']
        # Where a speaking mouth takes over from an expression's own mouth shape.
        self.mouth_weight = smooth01(soft_ellipse(self.X, self.Y, mo['x'], mo['y'] + 2, mo['w'] * 1.9, mo['h'] * 3.2, 0.3))
        f = lm['face']
        self.face_weight = smooth01(soft_ellipse(self.X, self.Y, f['x'], f['y'] + 14, f['rx'] * 1.1, f['ry'] * 1.12, 0.5))
        nk = lm['neck']
        self.head_weight = 1 - smooth01((self.Y - nk['chin']) / (nk['collar'] - nk['chin']))
        h = lm['head']
        r2 = ((self.X - h['x']) / h['rx']) ** 2 + ((self.Y - h['y']) / h['ry']) ** 2
        no = lm['nose']
        self.depth = h['rz'] * np.sqrt(np.clip(1 - r2, 0, 1)) \
            + no['z'] * bump(((self.X - no['x']) ** 2 + (self.Y - no['y']) ** 2) / no['r'] ** 2)
        hr = lm['hair']
        rn = np.sqrt(r2)
        hang = np.clip((self.Y - hr['y'] + 40) / h['ry'], 0, 1.3)
        self.hair_weight = smooth01((rn - hr['inner']) / (hr['outer'] - hr['inner'])) * (1 - self.face_weight) * hang * hr['reach']
        self.triangles = self._triangles()

    def _triangles(self):
        tris = []
        c = self.cols
        for r in range(self.rows - 1):
            for q in range(c - 1):
                a, b, d, e = r * c + q, r * c + q + 1, (r + 1) * c + q, (r + 1) * c + q + 1
                tris.append((a, b, e))
                tris.append((a, e, d))
        return np.array(tris)


def viseme_weights(rig, ch, laughing):
    """Painted mouth panels nearest the engine's mouth shape, top two, scaled by
    how much the mouth is doing. A laugh keeps its own painted open mouth."""
    if laughing:
        return []
    sig = np.array([ch['mouth.open'], ch['mouth.wide'], ch['mouth.round'], ch['mouth.press']])
    amount = min(1.0, max(ch['mouth.open'], ch['mouth.round'], ch['mouth.press'], ch['mouth.wide'] * 0.6) / 0.12)
    if amount <= 0.001:
        return []
    weights = []
    for j, p in enumerate(rig.data['visemes']):
        d2 = float(np.sum((sig - np.array(p)) ** 2))
        weights.append((math.exp(-d2 / 0.06), j))
    weights.sort(reverse=True)
    top = weights[:2]
    total = sum(w for w, _ in top)
    return [(j, amount * w / total) for w, j in top if amount * w / total > 0.01]


def expression_weights(state):
    """(panel key, weight) pairs whose flows shape the face, mirroring the old
    rig's dissolve: the prior face fades out while the new one fades in."""
    out = []
    blend = state.get('blend', 1.0)
    prior, shown = state.get('prior'), state.get('face')
    if prior and prior != shown and blend < 1:
        out.append((prior, 1 - blend))
    if shown:
        out.append((shown, blend if prior != shown else 1.0))
    return out


def vertices(rig, state):
    """Screen positions (panel pixels) of every grid vertex for one frame."""
    ch = {name: 0.0 for name in CHANNELS}
    ch.update(state.get('channels', {}))
    lm = rig.lm
    X, Y = rig.X, rig.Y
    dx = np.zeros_like(X)
    dy = np.zeros_like(Y)
    # 1. painted morphs
    vis = viseme_weights(rig, ch, state.get('face') == 'faces.2')
    speak = min(1.0, sum(w for _, w in vis))
    keep = 1 - rig.mouth_weight * speak
    for key, w in expression_weights(state):
        f = rig.flows[key]
        dx += w * f[:, 0] * keep
        dy += w * f[:, 1] * keep
    for j, w in vis:
        f = rig.flows[f'mouths.{j}']
        dx += w * f[:, 0]
        dy += w * f[:, 1]
    k = rig.keyforms
    raise_ = ch['brow.raise']
    # Keyforms cut from different panels are each fold-free; a combination
    # stays a weighted average of them, never a sum past full strength.
    brows = [('browRaise', raise_ if raise_ > 0 else raise_ * 0.6),
             ('browFurrow', ch['brow.furrow']), ('browSad', ch['brow.sad'])]
    cheeks = [('smileUp', max(0.0, ch['mouth.smile'])), ('smileDown', max(0.0, -ch['mouth.smile'])),
              ('cheekRaise', ch['cheek.raise'])]
    # A closing lid takes over the eye: the iris and a widened lid rest.
    open_ = 1 - min(1.0, max(ch['eye.blink'], ch['eye.wink']))
    for group in (brows, cheeks, [('eyeWide', ch['eye.wide'] * open_)]):
        total = sum(abs(w) for _, w in group)
        norm = 1.0 / total if total > 1 else 1.0
        for key, w in group:
            if abs(w) > 1e-4:
                dx += w * norm * k[key][:, 0]
                dy += w * norm * k[key][:, 1]
    # 2. eyes: irises follow the gaze inside the lids
    for e in lm['eyes']:
        wg = bump(((X - e['x']) / (e['w'] * 1.05)) ** 2 + ((Y - e['y']) / (e['iris'] * 1.5)) ** 2)
        dx += ch['gaze.x'] * e['iris'] * 0.55 * wg * open_
        dy += ch['gaze.y'] * e['iris'] * 0.3 * wg * open_
    # Lids last, as monotonic remaps of each grid column's already-moved
    # points (the column is its rest x), so nothing can fold through a
    # closing eye: first the upper lid comes down, then the lower lid rises.
    py = Y + dy
    for i, e in enumerate(lm['eyes']):
        blink = ch['eye.blink']
        if i == 1:
            blink = max(blink, ch['eye.wink'])
        blink = min(1.0, max(blink, ch['eye.squint'] * 0.25))
        u = (X - e['x']) / e['w']
        f = np.where(np.abs(u) < 1, 1 - u * u, 0.0)
        yc, yu = e['closed'], e['upper']
        lid = yc - (yc - yu) * f
        # 0.96: a closed lid keeps a sliver of height; no zero-area cells.
        d = min(blink, 0.96) * (yc - yu) * f
        top = lid - e['crease']
        span = np.maximum(yc - lid, 0.01)
        ramp = (py >= top) & (py < lid)
        squash = (py >= lid) & (py < yc)
        py = py + np.where(ramp, d * (py - top) / e['crease'], 0.0) + np.where(squash, d * (yc - py) / span, 0.0)
        rise = ch['eye.squint'] * 0.35 * (e['lower'] - e['upper']) * f
        low = e['lower']
        h2 = 9.0
        up = (py > e['y']) & (py <= low)
        below = (py > low) & (py <= low + h2)
        py = py - np.where(up, rise * (py - e['y']) / (low - e['y']), 0.0) - np.where(below, rise * (1 - (py - low) / h2), 0.0)
    dy = py - Y
    dx += ch['hair.swing'] * rig.hair_weight
    # 3. head turn: an ellipsoid head with a nose; features slide, outline holds
    phi = math.radians(ch['head.yaw'] * YAW_DEGREES)
    theta = math.radians(ch['head.pitch'] * PITCH_DEGREES)
    h = lm['head']
    hw = rig.head_weight
    qx = X + dx
    qy = Y + dy
    qx = qx + hw * ((X - h['x']) * (math.cos(phi) - 1) + rig.depth * math.sin(phi))
    qy = qy + hw * ((Y - h['y']) * (math.cos(theta) - 1) + rig.depth * math.sin(theta))
    # 4. roll about the neck; the neck bends instead of the head cutting
    rho = math.radians(ch['head.roll'] * ROLL_DEGREES + state.get('rollDegrees', 0.0)) * hw
    nk = lm['neck']
    cx, cy = qx - nk['x'], qy - nk['y']
    cs, sn = np.cos(rho), np.sin(rho)
    qx = nk['x'] + cx * cs - cy * sn
    qy = nk['y'] + cx * sn + cy * cs
    # 5. the body's breath and nod lift the whole head
    qy = qy + state.get('offsetY', 0.0)
    return np.stack([qx, qy], -1)


def layers(rig, state):
    """Draw list: (sheet key, panel index, per-vertex uv offsets or None, alpha,
    region name or 'head')."""
    ch = {name: 0.0 for name in CHANNELS}
    ch.update(state.get('channels', {}))
    out = [('faces', 0, None, 1.0, 'head')]
    blend = state.get('blend', 1.0)
    prior, shown = state.get('prior'), state.get('face')
    fading = blend < 1 and prior != shown
    if fading and prior:
        out.append((prior.split('.')[0], int(prior.split('.')[1]), rig.flows[prior],
                    (1 - blend) if not shown else 1.0, 'face'))
    if shown:
        out.append((shown.split('.')[0], int(shown.split('.')[1]), rig.flows[shown],
                    blend if fading else 1.0, 'face'))
    vis = viseme_weights(rig, ch, shown == 'faces.2')
    later = sum(w for _, w in vis)
    for j, w in sorted(vis, key=lambda t: -t[1]):
        later -= w
        out.append(('mouths', j, rig.flows[f'mouths.{j}'], min(1.0, w / max(1e-6, 1 - later)), 'mouth'))
    b = ch['eye.blink']
    closed = float(smooth01((b - 0.45) / 0.45))
    if closed > 0.001:
        out.append(('faces', 8, None, closed, 'eyes'))
    return out
