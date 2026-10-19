#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
# The Arcade's pure models: plain Foundation, no simulator (part of every build since Oct 19 2026).
swiftc Sources/ArcadeModels.swift Tests/ArcadeModelsTests.swift -o "$TEST_DIR/arcade-tests"
"$TEST_DIR/arcade-tests"
