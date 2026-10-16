#!/usr/bin/env bash
# Oct 16 2026: puppet scene conformance (the web kit's own fixtures), the motion
# engine port, the validator and a Core Graphics drawing smoke test. macOS only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"${SWIFTC:-swiftc}" -D PUPPET_MODEL_TESTS \
  "$ROOT/Sources/PuppetScene.swift" "$ROOT/Sources/PuppetMotion.swift" "$ROOT/Sources/PuppetRenderer.swift" \
  "$ROOT/Sources/CharacterPerformance.swift" "$ROOT/Sources/CharacterAnimationBudget.swift" \
  "$ROOT/PuppetTests/main.swift" -o "$OUT/puppet-tests"
PUPPET_FIXTURES="${PUPPET_FIXTURES:-$ROOT/PuppetTests/fixtures}" "$OUT/puppet-tests"
