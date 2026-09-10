#!/usr/bin/env bash
set -euo pipefail
[ "${KADE_CHARACTER_AUDIT:-0}" = "1" ] || exit 0
mkdir -p character-audit
# Use one CI-only device for input, output and system sounds. A mixed default
# aggregate with the Mac VM's Apple Virtual Sound Device can stall AudioQueue.
# Nothing from these build-machine tools is bundled in the app.
system_profiler SPAudioDataType > character-audit/audio-before.txt
brew install --cask blackhole-2ch > character-audit/audio-setup.txt 2>&1
brew install switchaudio-osx >> character-audit/audio-setup.txt 2>&1
sudo killall -9 coreaudiod || true
for attempt in 1 2 3 4 5; do
  if SwitchAudioSource -s 'BlackHole 2ch' >> character-audit/audio-setup.txt 2>&1; then break; fi
  sleep 2
done
SwitchAudioSource -s 'BlackHole 2ch' >> character-audit/audio-setup.txt 2>&1
SwitchAudioSource -t input -s 'BlackHole 2ch' >> character-audit/audio-setup.txt 2>&1
SwitchAudioSource -t system -s 'BlackHole 2ch' >> character-audit/audio-setup.txt 2>&1
system_profiler SPAudioDataType > character-audit/audio-after.txt
python3 dev/audio-preflight.py
xcodebuild -project KadeAI.xcodeproj -scheme KadeAI -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/character-simulator \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  build > character-audit/compile.log 2>&1 || { tail -n 80 character-audit/compile.log; exit 1; }
python3 dev/character-audit.py
