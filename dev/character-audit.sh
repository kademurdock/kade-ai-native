#!/usr/bin/env bash
set -euo pipefail
[ "${KADE_CHARACTER_AUDIT:-0}" = "1" ] || exit 0
mkdir -p character-audit
# The headless Mac has no usable speaker; provide a CI-only CoreAudio clock.
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
system_profiler SPAudioDataType > character-audit/audio-after.txt
xcodebuild -project KadeAI.xcodeproj -scheme KadeAI -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/character-simulator \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
  build > character-audit/compile.log 2>&1 || { tail -n 80 character-audit/compile.log; exit 1; }
python3 dev/character-audit.py
