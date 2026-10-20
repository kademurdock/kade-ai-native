#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
# The Arcade's pure models: plain Foundation, no simulator (part of every build since Oct 19 2026).
# Add a game (Oct 19 2026): Sources/ArcadeImport.swift is pure too (Foundation, CryptoKit, Compression).
# Touch play (Oct 20 2026): Sources/ArcadeTouchPlay.swift is pure too, checked by Tests/ArcadeTouchPlayTests.swift.
swiftc Sources/ArcadeModels.swift Sources/ArcadeImport.swift Sources/ArcadeTouchPlay.swift \
  Tests/ArcadeModelsTests.swift Tests/ArcadeTouchPlayTests.swift -o "$TEST_DIR/arcade-tests"
"$TEST_DIR/arcade-tests"
