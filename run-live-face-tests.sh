#!/usr/bin/env bash
# Oct 28 2026: the live video face gate (who may open a paid face) and the
# painted-loop pick. Pure Foundation, so swiftc alone runs it on CI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"${SWIFTC:-swiftc}" -O \
  "$ROOT/Sources/LiveFacePolicy.swift" \
  "$ROOT/LiveFaceTests/main.swift" -o "$OUT/live-face-tests"
"$OUT/live-face-tests"
