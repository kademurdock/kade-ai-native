#!/usr/bin/env bash
# Run the described-caption tests. No Mac, no Codemagic minutes, no Xcode.
# DescribedCaptions.swift is pure Foundation, like SpeechStreamer.swift, so it
# builds with the open-source Swift toolchain. Finding or installing swiftc:
# see run-speech-tests.sh (and its disk-space warning) — SWIFTC=/path/to/swiftc works here too.
set -euo pipefail
cd "$(dirname "$0")"
SWIFTC="${SWIFTC:-$(command -v swiftc || true)}"
if [ -z "$SWIFTC" ]; then
  echo "No Swift compiler found. See run-speech-tests.sh for how to get one, then:" >&2
  echo "  SWIFTC=/path/to/swiftc ./run-caption-tests.sh" >&2
  exit 2
fi
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"$SWIFTC" -o "$OUT/captiontests" Sources/DescribedCaptions.swift DescribedCaptionsTests/main.swift
"$OUT/captiontests"
