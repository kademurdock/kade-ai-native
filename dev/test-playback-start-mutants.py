"""Meaningful negative controls for the actual Swift start/replay policies.

No provider, signing or hardware is used. Run after the unchanged speech suite
passes; restore the exact source even when a mutant is not detected.
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
path = root / 'Sources/StreamPlaybackStart.swift'
original = path.read_bytes()
mutants = [
    (b'seconds > 0', b'seconds >= 0', b'unadvanced node clock is not playback'),
    (b'guard !recovered else', b'guard true else', b'second stall fails instead of claiming playback'),
    (b'data.count <= limit - bytes.count', b'true', b'replay memory stays bounded and rejects overflow'),
    (b'guard current else { return .cancelled }', b'guard current else { return .started }', b'cancel beats even a positive renderer clock'),
]
for before, after, expected in mutants:
    assert original.count(before) == 1
    try:
        path.write_bytes(original.replace(before, after, 1))
        result = subprocess.run(['bash', 'run-speech-tests.sh'], cwd=root, capture_output=True, timeout=45)
        assert result.returncode == 1 and expected in result.stdout + result.stderr, 'Mutant was not caught by its behavior check'
        print('Playback negative control detected: ' + expected.decode(), flush=True)
    finally:
        path.write_bytes(original)
assert path.read_bytes() == original
print('Playback policy: all 4 negative controls detected; exact source restored')
