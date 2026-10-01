#!/usr/bin/env python3
"""Capture the signed artifact's identity before attempting an upload."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import zipfile


def receipt(ipa: Path, source: str) -> dict:
    with zipfile.ZipFile(ipa) as archive:
        names = [name for name in archive.namelist() if name.startswith('Payload/') and name.endswith('.app/Info.plist') and name.count('/') == 2]
        if len(names) != 1:
            raise ValueError('Expected exactly one main app in the signed IPA')
        info = plistlib.loads(archive.read(names[0]))
        identity = {key: str(info[key]) for key in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion')}
    with ipa.open('rb') as binary:
        digest = hashlib.file_digest(binary, 'sha256').hexdigest()
    return {'schema': 1, 'file': ipa.name, 'bytes': ipa.stat().st_size, 'sha256': digest,
            'sourceCommit': source, 'platform': 'IOS', 'identity': identity,
            'recovery': 'Inspect existing Apple build uploads for this exact identity before retrying upload. Reuse this signed IPA; do not rebuild.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--source', default=os.environ.get('CM_COMMIT', ''))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not args.source:
        parser.error('A verified source commit is required')
    args.output.write_text(json.dumps(receipt(args.ipa, args.source), indent=2) + '\n', encoding='utf-8')
