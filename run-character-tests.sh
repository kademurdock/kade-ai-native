#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"${SWIFTC:-swiftc}" -D CHARACTER_MODEL_TESTS "$ROOT/Sources/CharacterMotion.swift" "$ROOT/Sources/CharacterAppearance.swift" "$ROOT/Sources/CharacterPerformance.swift" \
  "$ROOT/Sources/CharacterFigureMotion.swift" "$ROOT/Sources/CharacterBustArtwork.swift" \
  "$ROOT/Sources/CharacterKianaBustGeometry.swift" "$ROOT/Sources/CharacterDellaBustGeometry.swift" "$ROOT/Sources/CharacterWitherspoonBustGeometry.swift" \
  "$ROOT/Sources/CharacterStageLayout.swift" "$ROOT/CharacterMotionTests/main.swift" -o "$OUT/character-tests"
# Resolve the default fixture from the checkout, even when invoked by absolute
# path from an audit runner's temporary directory. Preserve an explicit override.
CHARACTER_CUE_FIXTURES="${CHARACTER_CUE_FIXTURES:-$ROOT/CharacterMotionTests/cues.json}" "$OUT/character-tests"
