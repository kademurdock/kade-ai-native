#!/usr/bin/env bash
# Oct 16 2026: living paintings. The Swift rig against the Python reference
# (LivingPaintingTests/lp-golden.json) and the painted-face motion option.
# macOS only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# PuppetMotion's frame budget reaches the character model files (see
# run-puppet-tests.sh for why this is the character tests' own set).
CHARACTER_FILES=()
for name in CharacterMotion CharacterAppearance CharacterPerformance CharacterFacialPolicy \
    CharacterAnimationBudget CharacterConversationBodyArtwork CharacterConversationBodyGeometry \
    CharacterDellaArmMotion CharacterDellaArticulatedGeometry CharacterDellaHostLayout \
    CharacterAngelVectorMotion CharacterAngelVectorArt CharacterHarleyHandPrototype CharacterFigureMotion \
    CharacterBustArtwork CharacterKianaBustGeometry CharacterDellaBustGeometry \
    CharacterWitherspoonBustGeometry CharacterStageLayout; do
  CHARACTER_FILES+=("$ROOT/Sources/$name.swift")
done
"${SWIFTC:-swiftc}" -O -D PUPPET_MODEL_TESTS -D CHARACTER_MODEL_TESTS \
  "$ROOT/Sources/PuppetScene.swift" "$ROOT/Sources/PuppetMotion.swift" \
  "${CHARACTER_FILES[@]}" \
  "$ROOT/Sources/LivingPaintingRig.swift" \
  "$ROOT/LivingPaintingTests/main.swift" -o "$OUT/living-painting-tests"
LIVING_ROOT="$ROOT" "$OUT/living-painting-tests"
