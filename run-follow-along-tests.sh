#!/usr/bin/env bash
# Nov 14 2026: Tellavision "Follow along" (the phone listens to a film on her
# TV and speaks its descriptions in step). The rules, every sentence, the
# track, the 16-second memory, the settings, the report, the audio-session
# plan, the checksum of the shipped syncprint.js, and syncprint.js itself in
# real JavaScriptCore: a made-up film is fingerprinted, a noisy clip is found
# at the right second, the tracker locks, the planner picks the right line.
# Since the review the same day, the loop runs on the made-up film too, and
# the microphone capture converts test tones through a change of format.
# No sound is played or recorded.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if ! "${SWIFTC:-swiftc}" "$ROOT/Sources/FollowAlongModel.swift" "$ROOT/Sources/FollowAlongEngine.swift" \
  "$ROOT/Sources/FollowAlongLoop.swift" "$ROOT/Sources/FollowAlongCapture.swift" \
  "$ROOT/Sources/KadeAudioSessionPolicy.swift" "$ROOT/FollowAlongTests/main.swift" \
  -o "$TMP/follow-along-tests" > "$TMP/compile.log" 2>&1; then
  cat "$TMP/compile.log"
  # The first errors as annotations, which a public repository shows without
  # a token (its logs need one).
  grep -E "error:" "$TMP/compile.log" | head -n 10 | sed -e 's/%/%25/g' -e 's/^/::error title=Follow along tests compile::/' || true
  exit 1
fi
if ! "$TMP/follow-along-tests" "$ROOT" > "$TMP/run.log" 2>&1; then
  cat "$TMP/run.log"
  # A crash prints no FAILED line of its own: say where it stopped.
  if ! grep -q "^::error" "$TMP/run.log"; then
    last="$(grep -v '^::' "$TMP/run.log" | tail -n 3 | tr '\n' ' ' | sed -e 's/%/%25/g')"
    echo "::error title=Follow along tests::the test program stopped without a result. Its last lines: $last"
  fi
  exit 1
fi
cat "$TMP/run.log"
# Timing only, never a failure: the matcher with JavaScriptCore's JIT on, then
# asked to be off (as inside the app, where there is no JIT).
FOLLOW_ALONG_TIMING_ONLY=1 "$TMP/follow-along-tests" "$ROOT" || echo "Follow along timing (JIT on) did not finish; not a failure."
JSC_useJIT=false FOLLOW_ALONG_TIMING_ONLY=1 "$TMP/follow-along-tests" "$ROOT" || echo "Follow along timing (JIT off) did not finish; not a failure."
