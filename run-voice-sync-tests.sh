#!/usr/bin/env bash
# Nov 12 2026: decision 24's account voice-settings rules (ListenerVoicePlan)
# and phase 4 pick 4's stream pick-up rules (StreamResume). Pure Foundation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"${SWIFTC:-swiftc}" "$ROOT/Sources/ListenerVoicePlan.swift" "$ROOT/Sources/StreamResume.swift" \
  "$ROOT/VoiceSyncTests/main.swift" -o "$TMP/voice-sync-tests"
"$TMP/voice-sync-tests"
