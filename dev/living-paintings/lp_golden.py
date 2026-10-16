"""Writes LivingPaintingTests/lp-golden.json: vertex positions and draw lists
for fixed states from the Python reference (lp_runtime.py), for every
character's rig. The Swift port (LivingPaintingRig) must match them. Run after
any rig or runtime change: python dev/living-paintings/lp_golden.py"""
import json
import os

import lp_runtime as rt

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
DELLA = [
    ('rest', {}),
    ('blink, squint, glance', {'channels': {'eye.blink': 0.6, 'eye.squint': 0.3, 'gaze.x': 0.7, 'gaze.y': -0.4}}),
    ('turn, nod, tilt, hair', {'channels': {'head.yaw': 0.8, 'head.pitch': -0.5, 'head.roll': 0.6, 'hair.swing': -0.7},
                               'rollDegrees': 2.5, 'offsetY': -1.2}),
    ('smiling and talking', {'face': 'faces.1', 'channels': {'mouth.open': 0.55, 'mouth.wide': 0.3, 'mouth.round': 0.2}}),
    ('expression fade', {'face': 'faces.6', 'prior': 'faces.3', 'blend': 0.4, 'channels': {'mouth.open': 0.05}}),
    ('laugh keeps its mouth', {'face': 'faces.2', 'channels': {'mouth.open': 0.9, 'eye.blink': 0.95}}),
    ('keyforms', {'channels': {'brow.raise': 0.8, 'brow.furrow': 0.5, 'brow.sad': 0.4, 'eye.wide': 0.6,
                               'mouth.smile': -0.5, 'cheek.raise': 0.7}}),
    ('wink and nuance', {'face': 'nuance.3', 'prior': None, 'blend': 0.7, 'channels': {'eye.wink': 0.8, 'brow.raise': -0.5}}),
]
# Each of the rest of the cast: tilted lids mid-blink, the head's turn (with a
# pinned crown and no engine roll for Mrs. Witherspoon), talking through a
# smile, and a laugh painted with its eyes closed (no blink there).
CAST = [
    ('blink, squint, glance', {'channels': {'eye.blink': 0.6, 'eye.squint': 0.2, 'gaze.x': -0.6, 'gaze.y': 0.3}}),
    ('turn, nod, tilt, hair', {'channels': {'head.yaw': -0.7, 'head.pitch': 0.5, 'head.roll': -0.6, 'hair.swing': 0.8},
                               'rollDegrees': -1.5, 'offsetY': -0.8}),
    ('smiling and talking', {'face': 'faces.1', 'prior': 'faces.3', 'blend': 0.6,
                             'channels': {'mouth.open': 0.6, 'mouth.round': 0.4, 'mouth.smile': 0.3}}),
    ('laugh with a blink', {'face': 'faces.2', 'channels': {'eye.blink': 0.8, 'brow.raise': 0.3}}),
]
STRIDE = 13


def main():
    cases = []
    for name, states in [('della', DELLA), ('kiana', CAST), ('harley', CAST), ('lilly', CAST), ('witherspoon', CAST)]:
        rig = rt.Rig(os.path.join(ROOT, 'Sources', f'LivingPainting{name.capitalize()}.json'))
        for label, state in states:
            v = rt.vertices(rig, state)
            picks = list(range(0, rig.X.size, STRIDE))
            layers = []
            for sheet, idx, offs, alpha, region in rt.layers(rig, state):
                layers.append({'panel': f'{sheet}.{idx}', 'flow': offs is not None, 'alpha': round(float(alpha), 9),
                               'region': region})
            cases.append({'rig': f'LivingPainting{name.capitalize()}', 'name': f'{name}: {label}',
                          'state': {**state, 'channels': state.get('channels', {})},
                          'indices': picks,
                          'vertices': [round(float(c), 6) for i in picks for c in v[i]],
                          'layers': layers})
    out = os.path.join(ROOT, 'LivingPaintingTests', 'lp-golden.json')
    with open(out, 'w', encoding='utf-8', newline='') as f:
        json.dump({'tolerance': 0.002, 'stride': STRIDE, 'cases': cases}, f, separators=(',', ':'))
    print('wrote', out, len(cases), 'cases')


if __name__ == '__main__':
    main()
