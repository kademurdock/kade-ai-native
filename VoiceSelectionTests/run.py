"""Compile the production voice-selection methods against an HTTP fixture on Linux/macOS.
No synthesis or paid service calls. Run with SWIFTC pointing to a Swift compiler.
"""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/VoiceService.swift').read_text(encoding='utf-8')

def method(name):
    marker = '    private func ' + name
    if marker not in source:
        marker = '    func ' + name
    start = source.index(marker)
    end = source.index('\n    }', start) + len('\n    }')
    return source[start:end]

production = '\n'.join(method(name) for name in [
    'invalidateVoiceSelections', 'loadUserVoicePrefsIfNeeded',
    'setUserVoiceOverride', 'resolveVoice'])
fixture = (Path(__file__).parent / 'fixture.swift').read_text(encoding='utf-8')
assert fixture.count('// PRODUCTION_METHODS') == 1
with tempfile.TemporaryDirectory() as directory:
    code = Path(directory) / 'fixture.swift'
    code.write_text(fixture.replace('// PRODUCTION_METHODS', production), encoding='utf-8')
    binary = str(Path(directory) / 'voice-selection-tests')
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), '-parse-as-library', str(code), '-o', binary], check=True)
    subprocess.run([binary], check=True)
