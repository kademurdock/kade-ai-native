#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
cp "$ROOT/Tests/ConversationStarterTests.swift" "$OUT/main.swift"
"${SWIFTC:-swiftc}" "$ROOT/Sources/ConversationStarters.swift" "$OUT/main.swift" -o "$OUT/starter-tests"
"$OUT/starter-tests"
