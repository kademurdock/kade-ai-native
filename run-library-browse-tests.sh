#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$ROOT/Tests/LibraryBrowseTests.swift" "$TMP/main.swift"
"${SWIFTC:-swiftc}" "$ROOT/Sources/LibraryBrowseModels.swift" "$TMP/main.swift" -o "$TMP/library-browse-tests"
"$TMP/library-browse-tests"
