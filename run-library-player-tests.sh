#!/usr/bin/env bash
# The Library player's words and small rules. Plain Foundation: no Xcode needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/Tests/LibraryPlayerTests.swift" "$TMP/main.swift"
"${SWIFTC:-swiftc}" "$ROOT/Sources/LibraryPlayerWords.swift" "$ROOT/Sources/LibraryBrowseModels.swift" "$TMP/main.swift" -o "$TMP/library-player-tests"
"$TMP/library-player-tests"
