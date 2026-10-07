#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/Tests/ReplySpeechFocusTests.swift" "$TMP/main.swift"
"${SWIFTC:-swiftc}" "$ROOT/Sources/ReplySpeechFocus.swift" "$TMP/main.swift" -o "$TMP/reply-focus-tests"
"$TMP/reply-focus-tests"
