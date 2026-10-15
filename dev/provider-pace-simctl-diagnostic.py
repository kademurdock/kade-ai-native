"""Bounded pre-app simulator diagnostic, never native acceptance evidence."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import sys
import time

PARENT = '29b749501ed66f625ff6922eb5ab85d1fb49f5f4'
BRANCH = 'codex/provider-pace-simctl-diagnostic-20261015'
FILES = {'dev/provider-pace-simctl-diagnostic.py', '.github/workflows/provider-pace-simctl-diagnostic.yml'}
START = time.monotonic()
DEADLINE = START + 480
RECEIPT = {'schema': 'kade.pre-app-simctl-diagnostic.v1', 'parent': PARENT,
           'startedUTC': datetime.now(timezone.utc).isoformat(), 'nativeProof': False,
           'appInstalled': False, 'appLaunched': False, 'appInputsChanged': False,
           'signing': False, 'speechRequests': 0, 'operations': [], 'passed': False}


def command(args, bound, cleanup=False):
    """One owned process group, bounded output/deadline and finite cleanup."""
    limit = DEADLINE if cleanup else DEADLINE - 45
    allowance = min(bound, limit - time.monotonic())
    assert allowance > 0, 'Diagnostic global deadline exhausted'
    started = time.monotonic()
    record = {'args': args, 'boundSeconds': bound, 'effectiveSeconds': round(allowance, 3),
              'loadBefore': list(os.getloadavg()), 'timedOut': False, 'outputLimitExceeded': False}
    RECEIPT['operations'].append(record)
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True, bufsize=0)
    output = bytearray()

    def stop():
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=1)

    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                left = started + allowance - time.monotonic()
                if left <= 0:
                    record['timedOut'] = True
                    stop()
                    break
                for key, _ in selector.select(min(.2, left)):
                    block = os.read(key.fileobj.fileno(), 4096)
                    if not block:
                        selector.unregister(key.fileobj)
                        continue
                    if len(output) + len(block) > 65536:
                        record['outputLimitExceeded'] = True
                        stop()
                        raise RuntimeError('Diagnostic output cap reached')
                    output.extend(block)
        process.wait(timeout=max(.001, min(1, started + allowance - time.monotonic())))
    finally:
        stop()
        record.update(elapsedSeconds=round(time.monotonic() - started, 3),
                      exitCode=process.poll(), loadAfter=list(os.getloadavg()),
                      capturedBytes=len(output), outputSha256=hashlib.sha256(output).hexdigest(),
                      sample=[line[:240] for line in bytes(output).decode('utf-8', 'replace').splitlines()[:6]])
        record['passed'] = not record['timedOut'] and not record['outputLimitExceeded'] and record['exitCode'] == 0
        process.stdout.close()
    assert record['passed'], 'Diagnostic command failed: ' + args[0] + ' ' + ' '.join(args[1:2])
    return bytes(output).decode('utf-8').strip()


def main():
    assert sys.platform == 'darwin' and os.environ.get('RUNNER_OS') == 'macOS'
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    assert event['repository']['full_name'] == 'kademurdock/kade-ai-native'
    assert event['repository']['private'] is False and event.get('deleted') is False
    assert os.environ['GITHUB_EVENT_NAME'] == 'push' and os.environ['GITHUB_REF'] == 'refs/heads/' + BRANCH
    source = command(['git', 'rev-parse', 'HEAD'], 10)
    assert source == os.environ['GITHUB_SHA']
    assert set(command(['git', 'diff', '--name-only', PARENT, source], 10).splitlines()) == FILES
    assert not command(['git', 'status', '--porcelain'], 10)
    RECEIPT.update(source=source, githubRunId=os.environ['GITHUB_RUN_ID'],
                   runnerImage=os.environ.get('ImageVersion'), cpuCount=os.cpu_count())
    version = command(['xcodebuild', '-version'], 30)
    assert version.splitlines()[0] == 'Xcode 26.4.1'
    RECEIPT['xcodeVersion'] = version
    RECEIPT['memory'] = command(['sysctl', '-n', 'hw.memsize'], 10)
    types = json.loads(command(['xcrun', 'simctl', 'list', 'devicetypes', '--json'], 45))['devicetypes']
    kind = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max'
    assert any(d['identifier'] == kind for d in types)
    runtimes = json.loads(command(['xcrun', 'simctl', 'list', 'runtimes', '--json'], 45))['runtimes']
    matches = [r for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier']
               and re.fullmatch(r'26\.4(?:\.[0-9]+)?', str(r.get('version', '')))]
    assert matches, 'Existing iOS26.4 runtime required; never download another'
    runtime = matches[-1]['identifier']
    devices = json.loads(command(['xcrun', 'simctl', 'list', 'devices', '--json'], 45))['devices']
    existing = {d['udid'] for rows in devices.values() for d in rows}
    identifier = None
    try:
        created = command(['xcrun', 'simctl', 'create', 'Kade pre-app diagnostic large', kind, runtime], 30)
        assert re.fullmatch(r'[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}', created)
        assert created not in existing
        identifier = created
        RECEIPT.update(ownedSimulator=identifier, runtime=runtime)
        command(['xcrun', 'simctl', 'boot', identifier], 45)
        command(['xcrun', 'simctl', 'bootstatus', identifier, '-b'], 420)
        # Same failing operation and unchanged30-second bound, before any app install.
        initial = command(['xcrun', 'simctl', 'ui', identifier, 'appearance'], 30)
        RECEIPT['initialAppearance'] = initial
        for appearance in ('dark', 'light'):
            command(['xcrun', 'simctl', 'ui', identifier, 'appearance', appearance], 30)
            actual = command(['xcrun', 'simctl', 'ui', identifier, 'appearance'], 30)
            assert actual.lower() == appearance
        RECEIPT['appearanceRoundTripPassed'] = True
    finally:
        if identifier:
            # Only the UUID returned by this run's create, never shutdown/delete all.
            command(['xcrun', 'simctl', 'shutdown', identifier], 30, cleanup=True)
            command(['xcrun', 'simctl', 'delete', identifier], 30, cleanup=True)
            RECEIPT['ownedSimulatorCleanupVerified'] = True
    RECEIPT['passed'] = True


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        RECEIPT.update(errorType=type(error).__name__, error=str(error)[:300])
    finally:
        RECEIPT.update(elapsedSeconds=round(time.monotonic() - START, 3),
                       finishedUTC=datetime.now(timezone.utc).isoformat())
        encoded = json.dumps(RECEIPT, separators=(',', ':'))
        assert len(encoded.encode()) <= 65536
        print('KADE_PRE_APP_SIMCTL_DIAGNOSTIC ' + encoded, flush=True)
    sys.exit(0 if RECEIPT['passed'] else 1)
