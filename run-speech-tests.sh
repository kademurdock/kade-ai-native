#!/usr/bin/env bash
# Run the speech-pipeline tests. No Mac, no Codemagic minutes, no Xcode.
#
# SpeechStreamer.swift is pure Foundation, so it builds with the open-source
# Swift toolchain on Linux — which means a session can run this in its own
# sandbox, for free, before a build is ever cut. That is the entire point:
# on Aug 23 2026 four TestFlight builds in a row were compile-green, reviewed,
# and wrong on Kade's phone, and the only tester that caught them was a blind
# woman listening to her own phone.
#
#   ./run-speech-tests.sh
#
# Exit 0 = green. Exit 1 = something in the speech path is broken; the failing
# check prints what it got and what it wanted.
set -euo pipefail
cd "$(dirname "$0")"

SWIFTC="${SWIFTC:-}"
if [ -z "$SWIFTC" ]; then
  if command -v swiftc >/dev/null 2>&1; then
    SWIFTC="$(command -v swiftc)"
  else
    for c in /usr/share/swift/usr/bin/swiftc \
             /opt/swift/usr/bin/swiftc \
             "$HOME"/swift-*/usr/bin/swiftc \
             /sessions/*/sw/swift-*/usr/bin/swiftc; do
      [ -x "$c" ] && SWIFTC="$c" && break
    done
  fi
fi

if [ -z "$SWIFTC" ]; then
  cat >&2 <<'MSG'
No Swift compiler found.

On a Mac it comes with Xcode. On Linux (an agent sandbox, CI, anywhere):

  curl -sL -o swift.tar.gz \
    https://download.swift.org/swift-5.10.1-release/ubuntu2204/swift-5.10.1-RELEASE/swift-5.10.1-RELEASE-ubuntu22.04.tar.gz
  tar xzf swift.tar.gz
  export PATH="$PWD/swift-5.10.1-RELEASE-ubuntu22.04/usr/bin:$PATH"

That download is about 580 MB and wants ~2.5 GB unpacked, so put it somewhere
with room — NOT /tmp on a small root filesystem. Then re-run this script, or
point it straight at the compiler with SWIFTC=/path/to/swiftc.
MSG
  exit 2
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"$SWIFTC" -o "$OUT/speechtests" Sources/SpeechStreamer.swift SpeechPipelineTests/main.swift
"$OUT/speechtests"
