#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swiftc Sources/WorkspacePolicy.swift WorkspaceTests/main.swift -o "$TMP/workspace-tests"
"$TMP/workspace-tests"
