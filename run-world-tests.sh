#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/WorldModels.swift Tests/WorldModelsTests.swift -o "$TEST_DIR/world-tests"
"$TEST_DIR/world-tests"
