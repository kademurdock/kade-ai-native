#!/usr/bin/env bash
# Oct 16 2026: living paintings. The Swift rig against the Python reference
# (LivingPaintingTests/lp-golden.json) and the painted-face motion option.
# macOS only. Same model build as run-puppet-tests.sh plus the rig.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"${SWIFTC:-swiftc}" -O -D PUPPET_MODEL_TESTS \
  "$ROOT/Sources/PuppetScene.swift" "$ROOT/Sources/PuppetMotion.swift" \
  "$ROOT/Sources/CharacterPerformance.swift" "$ROOT/Sources/CharacterAnimationBudget.swift" \
  "$ROOT/Sources/LivingPaintingRig.swift" \
  "$ROOT/LivingPaintingTests/main.swift" -o "$OUT/living-painting-tests"
LIVING_ROOT="$ROOT" "$OUT/living-painting-tests"
