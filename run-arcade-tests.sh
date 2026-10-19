#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
# The Arcade compiles only with the KADE_ARCADE flag (internal TestFlight builds).
swiftc -D KADE_ARCADE Sources/ArcadeModels.swift Tests/ArcadeModelsTests.swift -o "$TEST_DIR/arcade-tests"
"$TEST_DIR/arcade-tests"
