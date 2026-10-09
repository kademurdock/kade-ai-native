"""Capture production CallView with local captions and no call or microphone.

The six exact character identities use the ordinary production compositor.
Priority characters also cover compact accessibility text, app still and off.
These are layout captures; advancing PCM is covered by the playback audit.
"""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import time


CHARACTERS = ("harley", "kiana", "lilly", "della", "witherspoon", "lilly-private")
PRIORITY = CHARACTERS[:3]


def scenarios():
    rows = [(character, "large", "light", "large") for character in CHARACTERS]
    for character in PRIORITY:
        rows.extend([
            (character, "accessibility", "dark", "accessibility-extra-extra-extra-large"),
            (character, "still", "dark", "large"),
            (character, "off", "light", "large"),
        ])
    return rows


def capture(sim):
    output = Path("character-audit").resolve()
    output.mkdir(exist_ok=True)
    bundle = "com.kademurdock.kadeai"

    def run(*args):
        return subprocess.check_output(["xcrun", "simctl", *args], text=True, timeout=20).strip()

    documents = Path(run("get_app_container", sim, bundle, "data")) / "Documents"
    marker = documents / "call-layout-ready.txt"
    shots = []
    env = dict(os.environ, SIMCTL_CHILD_KADE_A11Y_AUDIT="1",
               SIMCTL_CHILD_KADE_CHARACTER_AUDIT="1", SIMCTL_CHILD_KADE_CALL_LAYOUT_AUDIT="1")
    try:
        for character, variant, appearance, size in scenarios():
            label = f"call-layout-{character}-{variant}"
            subprocess.run(["xcrun", "simctl", "terminate", sim, bundle],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
            marker.unlink(missing_ok=True)
            run("ui", sim, "appearance", appearance)
            run("ui", sim, "content_size", size)
            fixture_env = dict(env, SIMCTL_CHILD_KADE_CALL_LAYOUT_CHARACTER=character,
                               SIMCTL_CHILD_KADE_CALL_LAYOUT_VARIANT=variant)
            subprocess.run(["xcrun", "simctl", "launch", sim, bundle],
                           env=fixture_env, check=True, timeout=20)
            deadline = time.monotonic() + 15
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.2)
            if not marker.exists():
                raise RuntimeError(f"Actual CallView fixture did not become ready for {label}")
            fixture = json.loads(marker.read_text())
            if (fixture.get("character") != character or fixture.get("variant") != variant
                    or not fixture.get("agentID")
                    or fixture["agentID"] != fixture.get("expectedAgentID")
                    or not fixture.get("productionPuppetRegistered")):
                raise RuntimeError(f"CallView did not resolve the requested production character: {fixture}")
            if (fixture.get("portraitEnabled") != (variant != "off")
                    or fixture.get("appReduceMotion") != (variant == "still")
                    or fixture.get("audioStarted") is not False
                    or fixture.get("microphoneStarted") is not False):
                raise RuntimeError(f"Unexpected offline CallView fixture policy: {fixture}")
            # The real view's task writes readiness. Let caption and preference
            # updates commit before photographing the resulting screen.
            time.sleep(1)
            path = output / f"{label}.png"
            run("io", sim, "screenshot", str(path))
            header = path.read_bytes()[:24]
            if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
                raise RuntimeError(f"No valid screenshot for {label}")
            width, height = struct.unpack(">II", header[16:24])
            shots.append({"file": path.name, "textSize": size, "appearance": appearance,
                          "width": width, "height": height, "fixture": fixture,
                          "compactViaAccessibilityText": variant == "accessibility"})
    finally:
        # The simulator may next host chat fixtures; restore its global traits.
        for trait, value in [("appearance", "light"), ("content_size", "large")]:
            try:
                run("ui", sim, trait, value)
            except (OSError, subprocess.SubprocessError) as error:
                print(f"Could not restore simulator {trait}: {error}", file=sys.stderr)

    receipt = {"captured": True, "view": "Production CallView", "syntheticCaptions": True,
               "productionSelection": True, "liveCallStarted": False,
               "audioStarted": False, "microphoneStarted": False,
               "needsVisualReview": True, "systemReduceMotionVerified": False,
               "physicalVoiceOverVerified": False, "orientation": "portrait",
               "characterCount": len(CHARACTERS), "screenshots": shots}
    (output / "call-layout.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(receipt, indent=2), flush=True)


if __name__ == "__main__":
    capture(sys.argv[1])
