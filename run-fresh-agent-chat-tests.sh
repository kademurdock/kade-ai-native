#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"${SWIFTC:-swiftc}" -parse-as-library "$ROOT/Sources/KadeFreshAgentChat.swift" \
  "$ROOT/FreshAgentChatTests/main.swift" -o "$OUT/fresh-agent-chat-tests"
"$OUT/fresh-agent-chat-tests"
