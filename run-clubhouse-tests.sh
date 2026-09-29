#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/ClubhouseLibraryModels.swift Tests/ClubhouseLibraryTests.swift -o "$TEST_DIR/clubhouse-tests"
"$TEST_DIR/clubhouse-tests"
