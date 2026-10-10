#!/usr/bin/env python3
"""Compile real Foundation message models and synthetic regressions, without an iOS build."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
if not compiler:
    raise SystemExit('BLOCKED: swiftc is not installed. No tests ran; no iOS or paid build was started.')
with tempfile.TemporaryDirectory(prefix='kade-attachments-') as directory:
    work = Path(directory)
    # Compile the production value types, excluding the network/ObservableObject service.
    source = (root / 'Sources/ConversationsService.swift').read_text(encoding='utf-8-sig')
    (work / 'Messages.swift').write_text(source.split('@MainActor', 1)[0], encoding='utf-8')
    shutil.copyfile(root / 'Tests/MessageAttachmentTests.swift', work / 'main.swift')
    binary = work / ('attachment-tests.exe' if os.name == 'nt' else 'attachment-tests')
    subprocess.run([compiler, str(root / 'Sources/MessageAttachments.swift'),
                    str(root / 'Sources/MessageTextSanitizer.swift'), str(work / 'Messages.swift'),
                    str(work / 'main.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
