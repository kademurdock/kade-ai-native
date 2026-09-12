#!/usr/bin/env bash
set -euo pipefail
[ "${KADE_CHARACTER_AUDIT:-0}" = "1" ] || exit 0
mkdir -p character-audit
# The production call engine is rendered offline. Physical speaker, Bluetooth,
# microphone and AVAudioPlayer acceptance remain separate device checks.
xcodebuild -project KadeAI.xcodeproj -scheme KadeAI -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/character-simulator \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  build > character-audit/compile.log 2>&1 || { tail -n 80 character-audit/compile.log; exit 1; }
python3 dev/character-audit.py
