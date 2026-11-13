#!/usr/bin/env bash
# Nov 13 2026: the "still waiting" chime for listening to a described video
# while it is made (WaitingChime: when it may sound, the 20-second loop, the
# words). Pure Foundation; no audio is played.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"${SWIFTC:-swiftc}" "$ROOT/Sources/WaitingChime.swift" "$ROOT/WaitingChimeTests/main.swift" -o "$TMP/waiting-chime-tests"
"$TMP/waiting-chime-tests"
