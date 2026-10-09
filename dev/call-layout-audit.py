"""Capture the actual CallView using DEBUG-only invented captions, without a call.

Reuses the character audit's installed simulator app; no second compilation.
Screenshots need visual review and do not prove physical VoiceOver behavior.
"""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import time


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
    for label, appearance, size in [
        ("call-layout-light", "light", "large"),
        ("call-layout-largest-text-dark", "dark", "accessibility-extra-extra-extra-large"),
    ]:
        subprocess.run(["xcrun", "simctl", "terminate", sim, bundle],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        marker.unlink(missing_ok=True)
        run("ui", sim, "appearance", appearance)
        run("ui", sim, "content_size", size)
        subprocess.run(["xcrun", "simctl", "launch", sim, bundle], env=env, check=True, timeout=20)
        deadline = time.monotonic() + 15
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        if not marker.exists():
            raise RuntimeError(f"Actual CallView fixture did not become ready for {label}")
        time.sleep(1)
        path = output / f"{label}.png"
        run("io", sim, "screenshot", str(path))
        header = path.read_bytes()[:24]
        if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
            raise RuntimeError(f"No valid screenshot for {label}")
        width, height = struct.unpack(">II", header[16:24])
        shots.append({"file": path.name, "textSize": size, "appearance": appearance,
                      "width": width, "height": height})
    receipt = {"captured": True, "view": "Production CallView", "syntheticCaptions": True,
               "liveCallStarted": False, "needsVisualReview": True,
               "physicalVoiceOverVerified": False, "orientation": "portrait", "screenshots": shots}
    (output / "call-layout.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(receipt, indent=2), flush=True)


if __name__ == "__main__":
    capture(sys.argv[1])
