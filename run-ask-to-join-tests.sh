#!/usr/bin/env bash
# Oct 29 2026: the in-app front door (Ask to join) request body, including
# the optional sight question. Pure Foundation, so swiftc alone runs it on CI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"${SWIFTC:-swiftc}" -O \
  "$ROOT/Sources/AskToJoinRequest.swift" \
  "$ROOT/AskToJoinTests/main.swift" -o "$OUT/ask-to-join-tests"
"$OUT/ask-to-join-tests"
