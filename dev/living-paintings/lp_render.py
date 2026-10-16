"""Offline renderer for living paintings: rasterizes the warped grid like the
GPU does (textured triangles, per-vertex texture coordinates, per-pixel region
masks) and composites over the body plate. For tuning and review only."""
import glob
import sys

import os  # noqa: E402

if os.environ.get('LP_PYLIB'):
    sys.path.insert(0, os.environ['LP_PYLIB'])
import cv2  # noqa: E402
import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402

import lp_runtime as rt  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
ASSETS = os.path.join(ROOT, 'Sources', 'Assets.xcassets') + '/'
_cache = {}


def asset(name, rgba=False):
    key = (name, rgba)
    if key not in _cache:
        f = [p for p in glob.glob(ASSETS + name + '.imageset/*') if not p.endswith('.json')][0]
        _cache[key] = np.asarray(Image.open(f).convert('RGBA' if rgba else 'RGB')).astype(np.float32) / 255
    return _cache[key]


def render(rig, state, scale=2.0, body=True, out_size=None):
    size = out_size or int(round(414 * scale))
    V = rt.vertices(rig, state) * scale
    S = np.stack([rig.X, rig.Y], -1)
    tris = rig.triangles
    tri_id = -np.ones((size, size), np.int32)
    w0 = np.zeros((size, size), np.float32)
    w1 = np.zeros((size, size), np.float32)
    w2 = np.zeros((size, size), np.float32)
    P = V[tris]  # (T, 3, 2)
    mins = np.floor(P.min(1)).astype(int)
    maxs = np.ceil(P.max(1)).astype(int)
    for t in range(len(tris)):
        x0, y0 = max(0, mins[t, 0]), max(0, mins[t, 1])
        x1, y1 = min(size - 1, maxs[t, 0]), min(size - 1, maxs[t, 1])
        if x1 < x0 or y1 < y0:
            continue
        (ax, ay), (bx, by), (cx, cy) = P[t]
        den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(den) < 1e-9:
            continue
        ys, xs = np.mgrid[y0:y1 + 1, x0:x1 + 1].astype(np.float32)
        px, py = xs + 0.5, ys + 0.5
        l0 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / den
        l1 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / den
        l2 = 1 - l0 - l1
        inside = (l0 >= -1e-5) & (l1 >= -1e-5) & (l2 >= -1e-5)
        if not inside.any():
            continue
        sl = (slice(y0, y1 + 1), slice(x0, x1 + 1))
        tri_id[sl] = np.where(inside, t, tri_id[sl])
        w0[sl] = np.where(inside, l0, w0[sl])
        w1[sl] = np.where(inside, l1, w1[sl])
        w2[sl] = np.where(inside, l2, w2[sl])
    covered = tri_id >= 0
    tid = np.where(covered, tri_id, 0)
    ia, ib, ic = tris[tid, 0], tris[tid, 1], tris[tid, 2]

    def interp(attr):
        return attr[ia] * w0[..., None] + attr[ib] * w1[..., None] + attr[ic] * w2[..., None]

    s = interp(S)  # source (neutral panel) position per pixel
    sx, sy = s[..., 0], s[..., 1]
    d = rig.data
    canvas = np.zeros((size, size, 3), np.float32)
    canvas[:] = (0.16, 0.45, 0.48)
    if body:
        plate = asset('CharacterDellaBustBody', True)
        side = 677.16 * scale
        pl = cv2.resize(plate, (int(round(side)), int(round(side))), interpolation=cv2.INTER_AREA)
        ox, oy = int(round(-132 * scale)), int(round(-1 * scale + state.get('offsetY', 0) * scale))
        x0, y0 = max(0, ox), max(0, oy)
        x1, y1 = min(size, ox + pl.shape[1]), min(size, oy + pl.shape[0])
        part = pl[y0 - oy:y1 - oy, x0 - ox:x1 - ox]
        a = part[..., 3:4]
        canvas[y0:y1, x0:x1] = canvas[y0:y1, x0:x1] * (1 - a) + part[..., :3] * a
    mask = asset(d['mask']['asset'], True)[..., 3]
    m = d['mask']
    mscale = mask.shape[0] / m['side']
    core = d['core']
    regions = d['regions']
    sheets = {'faces': asset(d['sheets']['faces']), 'mouths': asset(d['sheets']['mouths']),
              'nuance': asset(d['sheets']['nuance'])}
    pitch = d['sheets']['pitch']
    for sheet, idx, offs, alpha, region in rt.layers(rig, state):
        uv = S if offs is None else S + offs
        u = interp(uv)
        ux = u[..., 0] + (idx % 3) * pitch
        uy = u[..., 1] + (idx // 3) * pitch
        rgb = cv2.remap(sheets[sheet], ux.astype(np.float32), uy.astype(np.float32), cv2.INTER_LINEAR,
                        borderMode=cv2.BORDER_REPLICATE)
        if region == 'head':
            mx = ((sx - m['x']) * mscale).astype(np.float32)
            my = ((sy - m['y']) * mscale).astype(np.float32)
            ma = cv2.remap(mask, mx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT, borderValue=0)
            inside = ((sx - core['x']) / core['rx']) ** 2 + ((sy - core['y']) / core['ry']) ** 2 <= 1
            a = np.maximum(ma, inside.astype(np.float32))
        else:
            rx, ry, rw, rh, inner = regions[region]
            cx, cy = (rx + rw / 2) * 414, (ry + rh / 2) * 414
            a = rt.soft_ellipse(sx, sy, cx, cy, rw * 414 / 2, rh * 414 / 2, inner)
        a = (a * alpha * covered)[..., None].astype(np.float32)
        canvas = canvas * (1 - a) + rgb * a
    return canvas


def save(im, path):
    Image.fromarray((np.clip(im, 0, 1) * 255).astype(np.uint8)).save(path)


def sheet_of(frames, cols, labels=None):
    rows = [np.concatenate(frames[i:i + cols], 1) for i in range(0, len(frames), cols)]
    w = rows[0].shape[1]
    rows = [r if r.shape[1] == w else np.concatenate([r, np.zeros((r.shape[0], w - r.shape[1], 3), np.float32)], 1) for r in rows]
    return np.concatenate(rows, 0)
