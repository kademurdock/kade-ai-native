"""Capture the production chat stage with explicitly offline placeholder UI."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

PEOPLE = ['harley', 'kiana', 'lilly', 'della', 'witherspoon', 'lilly-private']
PRIORITY = PEOPLE[:3]

def run(*args):
    return subprocess.check_output(['xcrun', 'simctl', *args], text=True).strip()

def capture(sim):
    out = Path('character-audit').resolve()
    folder = Path(run('get_app_container', sim, 'com.kademurdock.kadeai', 'data')) / 'Documents'
    marker = folder / 'chat-stage-ready.json'
    shots = []
    cases = [(p, 'normal', 'large', 'light') for p in PEOPLE]
    for person in PRIORITY:
        cases.extend([(person, 'keyboard', 'large', 'light'),
                      (person, 'accessibility', 'accessibility-extra-large', 'dark'),
                      (person, 'still', 'large', 'dark'),
                      (person, 'off', 'large', 'light')])
    try:
        for person, variant, size, appearance in cases:
            subprocess.run(['xcrun', 'simctl', 'terminate', sim, 'com.kademurdock.kadeai'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            marker.unlink(missing_ok=True)
            run('ui', sim, 'content_size', size)
            run('ui', sim, 'appearance', appearance)
            env = dict(os.environ, SIMCTL_CHILD_KADE_A11Y_AUDIT='1',
                       SIMCTL_CHILD_KADE_CHARACTER_AUDIT='1',
                       SIMCTL_CHILD_KADE_CHAT_LAYOUT_AUDIT='1',
                       SIMCTL_CHILD_KADE_CHAT_LAYOUT_CHARACTER=person,
                       SIMCTL_CHILD_KADE_CHAT_LAYOUT_VARIANT=variant)
            env.pop('SIMCTL_CHILD_KADE_CALL_LAYOUT_AUDIT', None)
            subprocess.run(['xcrun', 'simctl', 'launch', sim, 'com.kademurdock.kadeai'],
                           env=env, check=True, timeout=20)
            deadline = time.monotonic() + 15
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.2)
            if not marker.exists():
                raise RuntimeError(f'Chat stage did not become ready: {person}/{variant}')
            fixture = json.loads(marker.read_text())
            if (fixture['character'] != person or fixture['variant'] != variant
                    or not fixture['sharedProductionStage']
                    or not fixture['productionPuppetRegistered']
                    or fixture['portraitEnabled'] != (variant != 'off')
                    or fixture['appReduceMotion'] != (variant == 'still')
                    or fixture['audioStarted'] or fixture['microphoneStarted']):
                raise RuntimeError(f'Chat stage fixture drift: {fixture}')
            expected = variant not in ('keyboard', 'accessibility', 'off')
            if fixture['puppetEligibleAtSize'] != expected:
                raise RuntimeError(f'Unexpected chat crop: {fixture}')
            time.sleep(1)
            name = f'chat-stage-{person}-{variant}-{appearance}.png'
            run('io', sim, 'screenshot', str(out / name))
            shots.append({'file': name, 'fixture': fixture, 'textSize': size,
                          'appearance': appearance})
    finally:
        run('ui', sim, 'appearance', 'light')
        run('ui', sim, 'content_size', 'large')
    receipt = {'captured': True, 'view': 'CharacterConversationStage',
               'completeConversationScreen': False, 'placeholderTranscript': True,
               'audioStarted': False, 'microphoneStarted': False,
               'needsVisualReview': True, 'screenshots': shots}
    (out / 'chat-stage-layout.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'captured': len(shots), 'sharedProductionStage': True}))

if __name__ == '__main__':
    capture(sys.argv[1])
