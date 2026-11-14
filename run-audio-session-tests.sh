#!/usr/bin/env bash
# Nov 14 2026: the app's audio-session rules (KadeAudioSessionPolicy: what
# each state asks the session for, and when the app lets it go so VoiceOver
# is back to its own level). Pure Foundation; no audio is played and no
# session is touched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"${SWIFTC:-swiftc}" "$ROOT/Sources/KadeAudioSessionPolicy.swift" "$ROOT/AudioSessionTests/main.swift" -o "$TMP/audio-session-tests"
"$TMP/audio-session-tests"
