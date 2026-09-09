#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"${SWIFTC:-swiftc}" "$ROOT/Sources/CharacterMotion.swift" "$ROOT/CharacterMotionTests/main.swift" -o "$OUT/character-tests"
"$OUT/character-tests"
