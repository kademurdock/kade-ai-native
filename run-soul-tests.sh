#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"${SWIFTC:-swiftc}" -parse-as-library "$ROOT/Sources/KadeSoul.swift" \
  "$ROOT/SoulTests/main.swift" -o "$OUT/soul-tests"
"$OUT/soul-tests"
