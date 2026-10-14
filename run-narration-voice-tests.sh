#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc Sources/NarrationVoiceChoice.swift Sources/VoiceCatalog.swift NarrationVoiceTests/main.swift -o "$out/narration-voice-tests"
"$out/narration-voice-tests"
