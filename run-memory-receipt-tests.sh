#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc "$ROOT/Sources/MemoryReceipts.swift" "$ROOT/Tests/MemoryReceiptTests.swift" -o "$TMP/memory-receipt-tests"
"$TMP/memory-receipt-tests"
