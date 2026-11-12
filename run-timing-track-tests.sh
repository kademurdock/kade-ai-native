#!/usr/bin/env bash
# Nov 11 2026: Inworld timing tracks (Sources/KadeTimingTrack.swift). The
# website's timing-track tests case for case, golden mouth picks written from
# the website's own module (dev/timing-track/golden.mjs), the WAV readers past
# a kdtm chunk, the presentation and call timeline, and the puppet engine's
# tracked mouth. macOS only (same model build as run-living-painting-tests.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"${SWIFTC:-swiftc}" -D PUPPET_MODEL_TESTS \
  "$ROOT/Sources/KadeTimingTrack.swift" "$ROOT/Sources/StreamingWavParser.swift" \
  "$ROOT/Sources/PuppetScene.swift" "$ROOT/Sources/PuppetMotion.swift" \
  "$ROOT/Sources/CharacterPerformance.swift" "$ROOT/Sources/CharacterAnimationBudget.swift" \
  "$ROOT/TimingTrackTests/main.swift" -o "$OUT/timing-track-tests"
TIMING_ROOT="$ROOT" "$OUT/timing-track-tests"
