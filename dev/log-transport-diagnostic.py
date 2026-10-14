"""Synthetic, bounded log transport diagnostic; never a native app proof."""
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

BRANCH = 'codex/native-large-log-diagnostic-20261014'
PARENT = '2cf699cfae00c0663505e671e1d61880bfc0834b'
FILES = {'.github/workflows/native-log-transport-diagnostic.yml', 'dev/log-transport-diagnostic.py'}
SIZES = (19900054, 20114314)


def git(*args):
    return subprocess.check_output(['git', *args], text=True, timeout=15).strip()


def payload(index, size):
    return hashlib.shake_256(('kade-synthetic-log-diagnostic-v1-' + str(index)).encode()).digest(size)


def main():
    chunk_size = int(os.environ['DIAGNOSTIC_CHUNK'])
    assert chunk_size in (65536, 1048576)
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    source = git('rev-parse', 'HEAD')
    assert os.environ['GITHUB_REPOSITORY'] == 'kademurdock/kade-ai-native'
    assert os.environ['GITHUB_EVENT_NAME'] == 'push'
    assert os.environ['GITHUB_REF'] == 'refs/heads/' + BRANCH
    assert os.environ['GITHUB_SHA'] == event['after'] == source
    assert event['repository']['private'] is False and event['deleted'] is False
    assert event['repository']['full_name'] == 'kademurdock/kade-ai-native'
    assert git('rev-parse', 'HEAD^') == PARENT and not git('status', '--porcelain')
    assert set(git('diff', '--name-only', PARENT, 'HEAD').splitlines()) == FILES
    started = time.monotonic()
    for index, size in enumerate(SIZES):
        raw = payload(index, size)
        digest = hashlib.sha256(raw).hexdigest()
        encoded = base64.b64encode(raw).decode('ascii')
        chunks = [encoded[n:n + chunk_size] for n in range(0, len(encoded), chunk_size)]
        prefix = 'KADE_SYNTHETIC_TRANSPORT_' + str(index)
        header = dict(source=source, rawBytes=size, encodedBytes=len(encoded), chunks=len(chunks),
                      chunkSize=chunk_size, sha256=digest, synthetic=True, nativeProof=False)
        print(prefix + '_BEGIN ' + json.dumps(header, separators=(',', ':')), flush=True)
        for number, chunk in enumerate(chunks, 1):
            assert time.monotonic() - started < 60, 'Diagnostic retains the one-minute bound'
            print(prefix + f'_CHUNK {number:06d} ' + chunk, flush=True)
        print(prefix + '_END ' + digest, flush=True)
    print('KADE_SYNTHETIC_TRANSPORT_RESULT ' + json.dumps(dict(chunkSize=chunk_size,
          elapsedSeconds=time.monotonic() - started, nativeProof=False)), flush=True)


if __name__ == '__main__':
    main()
