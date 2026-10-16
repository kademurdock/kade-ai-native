#!/usr/bin/env bash
# Oct 16 2026: screenshots of the DEBUG puppet gallery (PuppetGalleryView) for
# review. Usage: bash dev/puppet-gallery.sh build/check   (the derived data path
# of an unsigned Debug simulator build). Writes build/gallery/*.png.
# Fail-soft by design: every problem is printed and the script exits 0, so the
# compile check stays the gate and a slow simulator never fails a run.
set -u
DERIVED="${1:-build/check}"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/KadeAI.app"
OUT="build/gallery"
mkdir -p "$OUT"
note() { echo "puppet-gallery: $*"; }
# macOS has no `timeout`; perl's alarm survives exec and stops a hung simctl.
limit() { local seconds="$1"; shift; perl -e 'alarm shift @ARGV; exec @ARGV' "$seconds" "$@"; }

if [ ! -d "$APP" ]; then note "no app at $APP"; exit 0; fi
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist" 2>/dev/null || echo com.kademurdock.kadeai)"
# An unsigned arm64 simulator build is only linker-signed; an ad-hoc signature
# keeps install and launch predictable. Harmless when it is already signed.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || note "ad-hoc signing skipped"

RUNTIMES="$(limit 300 xcrun simctl list runtimes available -j 2>/dev/null)"
RUNTIME="$(printf '%s' "$RUNTIMES" | python3 -c '
import json, sys
try:
    rows = [r for r in json.load(sys.stdin).get("runtimes", []) if r.get("isAvailable") and ".iOS-" in r.get("identifier", "")]
except Exception:
    rows = []
rows.sort(key=lambda r: [int(p) for p in r.get("version", "0").split(".") if p.isdigit()])
print(rows[-1]["identifier"] if rows else "")
')"
if [ -z "$RUNTIME" ]; then note "no available iOS simulator runtime"; exit 0; fi
TYPES="$(limit 120 xcrun simctl list devicetypes -j 2>/dev/null)"
DEVICE_TYPE="$(printf '%s' "$TYPES" | python3 -c '
import json, sys
try:
    names = [(t["name"], t["identifier"]) for t in json.load(sys.stdin).get("devicetypes", [])]
except Exception:
    names = []
import re
pro = sorted((int(m.group(1)), n[1]) for n in names for m in [re.fullmatch(r"iPhone (\d+) Pro", n[0])] if m)
phones = [n[1] for n in names if n[0].startswith("iPhone")]
print(pro[-1][1] if pro else (phones[-1] if phones else ""))
')"
if [ -z "$DEVICE_TYPE" ]; then note "no iPhone device type"; exit 0; fi
note "runtime $RUNTIME, device $DEVICE_TYPE"

UDID="$(limit 180 xcrun simctl create "Puppet gallery" "$DEVICE_TYPE" "$RUNTIME" 2>/dev/null)"
if [ -z "$UDID" ]; then note "could not create a simulator"; exit 0; fi
cleanup() {
  limit 120 xcrun simctl shutdown "$UDID" >/dev/null 2>&1
  limit 120 xcrun simctl delete "$UDID" >/dev/null 2>&1
}
trap cleanup EXIT

limit 600 xcrun simctl boot "$UDID" || note "boot returned an error (continuing to wait)"
if ! limit 600 xcrun simctl bootstatus "$UDID" -b; then note "simulator never finished booting"; exit 0; fi
limit 60 xcrun simctl status_bar "$UDID" override --time 9:41 >/dev/null 2>&1 || true
if ! limit 300 xcrun simctl install "$UDID" "$APP"; then note "install failed"; exit 0; fi

shots=0
for page in 0 1 2; do
  limit 60 xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1
  if ! limit 180 xcrun simctl launch "$UDID" "$BUNDLE" -KadePuppetGallery -KadePuppetGalleryPage "$page"; then
    note "launch of page $page failed"; continue
  fi
  # The first launch also warms the simulator's render server and lets the
  # fresh device's welcome notifications come and go before any screenshot.
  if [ "$page" = 0 ]; then sleep 30; else sleep 10; fi
  if limit 120 xcrun simctl io "$UDID" screenshot "$OUT/gallery-page$page.png"; then
    shots=$((shots + 1))
  else
    note "screenshot of page $page failed"
  fi
done
note "$shots screenshot(s) in $OUT"
exit 0
