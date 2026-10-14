"""Read-only startup diagnostics, never native app proof or a release gate."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

PARENT = 'b8b61c1855dfe4d85cb6f9508dd44ba8ea48d178'
BRANCH = 'codex/puppet-simulator-diagnostics-20261014'
FILES = {'.github/workflows/puppet-simulator-diagnostics.yml', 'dev/inspect-simulator-startup.py'}
REPO = 'kademurdock/kade-ai-native'


def git(*args):
    return subprocess.check_output(['git', *args], text=True, timeout=15).strip()


def measure(label, arguments):
    started = time.monotonic()
    entry = {'label': label, 'timeoutSeconds': 45, 'timedOut': False}
    raw = b''
    error = b''
    try:
        answer = subprocess.run(['xcrun', 'simctl', 'list', *arguments, '--json'],
                                capture_output=True, timeout=45, check=False)
        raw, error = answer.stdout, answer.stderr
        entry['exitCode'] = answer.returncode
    except subprocess.TimeoutExpired as failure:
        raw, error = failure.stdout or b'', failure.stderr or b''
        entry.update(timedOut=True, exitCode=None)
    entry.update(elapsedSeconds=round(time.monotonic() - started, 3),
                 stdoutBytes=len(raw), stderrBytes=len(error),
                 stdoutSHA256=hashlib.sha256(raw).hexdigest(),
                 stderrSHA256=hashlib.sha256(error).hexdigest())
    if entry.get('exitCode') == 0:
        assert len(raw) <= 1024 * 1024, 'Unexpected inventory size'
        inventory = json.loads(raw)
        if arguments == ['runtimes']:
            ios = [v for v in inventory['runtimes'] if '.iOS-' in v.get('identifier', '')]
            entry['iOS'] = [{k: v.get(k) for k in ('identifier', 'version', 'isAvailable')} for v in ios]
        elif arguments == ['devicetypes']:
            entry['deviceTypeCount'] = len(inventory['devicetypes'])
        else:
            raise AssertionError('Unexpected diagnostic operation')
    # Only synthetic runner service errors, never environment/credentials.
    if error:
        safe = re.sub(rb'https?://\S+', b'[URL omitted]', error[-1600:]).decode('utf-8', errors='replace')
        entry['boundedError'] = safe
    print('KADE_SIMULATOR_DIAGNOSTIC_OPERATION ' + json.dumps(entry, separators=(',', ':')), flush=True)
    return entry


def main():
    assert sys.platform == 'darwin'
    assert os.environ['GITHUB_REPOSITORY'] == REPO
    assert os.environ['GITHUB_REF'] == 'refs/heads/' + BRANCH
    assert os.environ['GITHUB_EVENT_NAME'] == 'push'
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text(encoding='utf-8'))
    assert event['repository']['private'] is False and event['deleted'] is False
    assert os.environ['DEVELOPER_DIR'] == '/Applications/Xcode_26.4.1.app/Contents/Developer'
    assert git('rev-parse', 'HEAD') == os.environ['GITHUB_SHA']
    assert git('rev-parse', 'HEAD^') == PARENT
    assert set(git('diff', '--name-only', PARENT, 'HEAD').splitlines()) == FILES
    assert not git('status', '--porcelain')
    version = subprocess.check_output(['xcodebuild', '-version'], text=True, timeout=30)
    assert version.splitlines()[0] == 'Xcode 26.4.1'
    mode = os.environ['DIAGNOSTIC_ORDER']
    assert mode in ('runtimes-first', 'types-first')
    order = ['runtimes', 'devicetypes'] if mode == 'runtimes-first' else ['devicetypes', 'runtimes']
    print('KADE_SIMULATOR_DIAGNOSTIC_BEGIN ' + json.dumps({
        'source': os.environ['GITHUB_SHA'], 'parentCandidate': PARENT, 'order': mode,
        'operations': order, 'nativeProof': False, 'appCompilation': False,
        'deviceCreation': False, 'signing': False, 'uploads': False}), flush=True)
    results = [measure(item, [item]) for item in order]
    print('KADE_SIMULATOR_DIAGNOSTIC_END ' + json.dumps({
        'source': os.environ['GITHUB_SHA'], 'order': mode, 'operations': results,
        'nativeProof': False, 'sameSourceFullProofStillRequired': True}), flush=True)
    # A diagnostic process can complete while an observation fails. Neither is
    # a native proof. Every actual timeout/exit remains explicit in the receipt.


if __name__ == '__main__':
    main()
