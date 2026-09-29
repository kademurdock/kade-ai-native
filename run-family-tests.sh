#!/usr/bin/env bash
# Run the Family history tests. No Mac, no Codemagic minutes, no Xcode:
# FamilyModels.swift, FamilyPayloads.swift, FamilyGeometry.swift and the
# made-up demo family (FamilyDemoData.swift, DEBUG only, hence -D DEBUG) are
# pure Foundation, so they build with the open-source Swift toolchain too.
# SWIFTC=/path/to/swiftc works as in run-caption-tests.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"${SWIFTC:-swiftc}" -D DEBUG \
  "$ROOT/Sources/FamilyModels.swift" \
  "$ROOT/Sources/FamilyPayloads.swift" \
  "$ROOT/Sources/FamilyGeometry.swift" \
  "$ROOT/Sources/FamilyDemoData.swift" \
  "$ROOT/Tests/FamilyHistoryTests.swift" \
  -o "$OUT/family-tests"
"$OUT/family-tests"
