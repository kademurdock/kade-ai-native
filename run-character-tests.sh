#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"${SWIFTC:-swiftc}" "$ROOT/Sources/CharacterMotion.swift" "$ROOT/Sources/CharacterAppearance.swift" "$ROOT/Sources/CharacterPerformance.swift" \
  "$ROOT/Sources/CharacterFigureMotion.swift" "$ROOT/CharacterMotionTests/main.swift" -o "$OUT/character-tests"
"$OUT/character-tests"
