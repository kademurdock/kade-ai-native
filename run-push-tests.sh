#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -parse-as-library "$ROOT/Sources/PushService.swift" "$ROOT/PushServiceTests/main.swift" -o "$OUT/push-tests"
"$OUT/push-tests"
