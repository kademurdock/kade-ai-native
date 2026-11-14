#!/usr/bin/env bash
# Nov 14 2026: Tellavision "Follow along" (the phone listens to a film on her
# TV and speaks its descriptions in step). The rules, every sentence, the
# track, the 16-second memory, the settings, the report, the audio-session
# plan, the checksum of the shipped syncprint.js, and syncprint.js itself in
# real JavaScriptCore: a made-up film is fingerprinted, a noisy clip is found
# at the right second, the tracker locks, the planner picks the right line.
# No sound is played or recorded.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
"${SWIFTC:-swiftc}" "$ROOT/Sources/FollowAlongModel.swift" "$ROOT/Sources/FollowAlongEngine.swift" \
  "$ROOT/Sources/KadeAudioSessionPolicy.swift" "$ROOT/FollowAlongTests/main.swift" -o "$TMP/follow-along-tests"
"$TMP/follow-along-tests" "$ROOT"
# Timing only, never a failure: the matcher with JavaScriptCore's JIT on, then
# asked to be off (as inside the app, where there is no JIT).
FOLLOW_ALONG_TIMING_ONLY=1 "$TMP/follow-along-tests" "$ROOT" || echo "Follow along timing (JIT on) did not finish; not a failure."
JSC_useJIT=false FOLLOW_ALONG_TIMING_ONLY=1 "$TMP/follow-along-tests" "$ROOT" || echo "Follow along timing (JIT off) did not finish; not a failure."
