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
  # PART 92.7 — SAY THE NUMBER, AND SAY HOW TO DELETE IT.
  # The Aug-24 05:20Z session opened with a DEAD SHELL: "useradd: /etc/passwd:
  # No space left on device", three identical failures, every tool call refused,
  # and it took a restart by Kade to clear. Cause: the session before it followed
  # these very instructions, unpacked ~2.5 GB of toolchain, and left it there —
  # on a disk that is SHARED between sessions. The advice was right about where
  # NOT to put it and silent about ever removing it, so the cost landed on the
  # next session instead of the one that spent it.
  # So: measure the disk before advising the unpack, and print the cleanup line
  # in the same breath as the install line.
  NEED_MB=3072
  DEST="${SWIFT_DEST:-$PWD}"
  AVAIL_MB="$(df -Pm "$DEST" 2>/dev/null | awk 'NR==2 {print $4}')"
  {
    echo "No Swift compiler found."
    echo
    echo "On a Mac it comes with Xcode. On Linux (an agent sandbox, CI, anywhere)"
    echo "the toolchain is a ~580 MB download that wants ~2.5 GB unpacked."
    echo
    if [ -n "$AVAIL_MB" ]; then
      echo "Free space in ${DEST}: ${AVAIL_MB} MB (want at least ${NEED_MB} MB)."
      if [ "$AVAIL_MB" -lt "$NEED_MB" ]; then
        echo
        echo "  *** NOT ENOUGH ROOM. DO NOT UNPACK IT HERE. ***"
        echo "  Filling this disk does not just fail the build — it can take the"
        echo "  whole shell down, including the ability to create a user, and the"
        echo "  next session inherits it. Pick a bigger volume via SWIFT_DEST,"
        echo "  or free space first."
      fi
    else
      echo "Could not read free space for ${DEST} — check it yourself before unpacking."
    fi
    echo
    echo "  cd \"$DEST\""
    echo "  curl -sL -o swift.tar.gz \\"
    echo "    https://download.swift.org/swift-5.10.1-release/ubuntu2204/swift-5.10.1-RELEASE/swift-5.10.1-RELEASE-ubuntu22.04.tar.gz"
    echo "  tar xzf swift.tar.gz && rm -f swift.tar.gz"
    echo "  export PATH=\"$DEST/swift-5.10.1-RELEASE-ubuntu22.04/usr/bin:\$PATH\""
    echo
    echo "WHEN YOU ARE DONE, DELETE IT — it is a build tool, not an artifact:"
    echo
    echo "  rm -rf \"$DEST/swift-5.10.1-RELEASE-ubuntu22.04\" \"$DEST/swift.tar.gz\""
    echo
    echo "Or skip all of it and point straight at a compiler you already have:"
    echo "  SWIFTC=/path/to/swiftc ./run-speech-tests.sh"
  } >&2
  exit 2
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
"$SWIFTC" -o "$OUT/speechtests" Sources/SpeechStreamer.swift Sources/StreamingWavParser.swift SpeechPipelineTests/main.swift
"$OUT/speechtests"
