"""Actual Swift negative controls for provider pace, with exact restoration."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
path = root / 'Sources/StreamPlaybackStart.swift'
original = path.read_bytes()
mutants = [
    (b'min(1.5, max(0.5, value))', b'value', b'Inworld clamps rates above its API range'),
    (b'fishPace != "character", options', b'fishPace == "character", options', b'A chosen Fish pace becomes the one voice speed'),
]
for before, after, expected in mutants:
    assert original.count(before) == 1
    try:
        path.write_bytes(original.replace(before, after, 1))
        result = subprocess.run(['bash', 'run-speech-tests.sh'], cwd=root, capture_output=True, timeout=45)
        assert result.returncode == 1 and expected in result.stdout + result.stderr, 'Pace mutant was not caught'
        print('Pace negative control detected: ' + expected.decode(), flush=True)
    finally:
        path.write_bytes(original)
assert path.read_bytes() == original
service = (root / 'Sources/VoiceService.swift').read_text()
assert all(word not in service for word in ('residualRate', 'synthSpeedFactor', 'setRate(live)'))
assert 'player.rate = 1.0' in service and 'streamingPlayer.play(fetch: fetch, rate: 1.0,' in service
assert service.count('let tuned = synthesisSpeed(base: speed)') == 3
print('Pace policy: all 2 negative controls detected; exact source restored; all 3 request paths and original-speed players checked')
