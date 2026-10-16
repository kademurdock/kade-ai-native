#!/usr/bin/env bash
# Oct 16 2026: puppet scene conformance (the web kit's own fixtures), the motion
# engine port, the validator and a Core Graphics drawing smoke test. macOS only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# Since the resting-life work, CharacterAnimationBudget needs the face clock
# (CharacterMotion.swift) and its model-only dependencies: the same Sources
# set the character tests compile.
CHARACTER_FILES=()
for name in CharacterMotion CharacterAppearance CharacterPerformance CharacterFacialPolicy \
    CharacterAnimationBudget CharacterConversationBodyArtwork CharacterConversationBodyGeometry \
    CharacterDellaArmMotion CharacterDellaArticulatedGeometry CharacterDellaHostLayout \
    CharacterAngelVectorMotion CharacterAngelVectorArt CharacterHarleyHandPrototype CharacterFigureMotion \
    CharacterBustArtwork CharacterKianaBustGeometry CharacterDellaBustGeometry \
    CharacterWitherspoonBustGeometry CharacterStageLayout; do
  CHARACTER_FILES+=("$ROOT/Sources/$name.swift")
done
"${SWIFTC:-swiftc}" -D PUPPET_MODEL_TESTS -D CHARACTER_MODEL_TESTS \
  "$ROOT/Sources/PuppetScene.swift" "$ROOT/Sources/PuppetMotion.swift" "$ROOT/Sources/PuppetRenderer.swift" \
  "${CHARACTER_FILES[@]}" \
  "$ROOT/PuppetTests/main.swift" -o "$OUT/puppet-tests"
PUPPET_FIXTURES="${PUPPET_FIXTURES:-$ROOT/PuppetTests/fixtures}" "$OUT/puppet-tests"
