"""Stage unchanged experimental art for a DEBUG simulator review only.

Release workflows never invoke this script. Run --check to verify sources
without writing the temporary asset catalog entries.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct

ROOT = Path(__file__).resolve().parents[1]
ASSETS = (
    ("body.png", "CharacterHarleyBustBody", "83c301e933b2503090f01f2cc75f249f8711f0573bb82e604c160be00e4683d4", (1024, 1536)),
    ("mask.png", "CharacterHarleyBustMask", "26e0133c20e0d69d6f6dc3a262cdfd6d466d3dbfdbd582f2a2742ff7a3ac7dc1", (1254, 1254)),
    ("lilly-body-support.png", "CharacterLillyBustBody", "237505b328b8a056a4f58aab5f7becbbac1760ee0d33dd49fd8b48f1d4dfd630", (1254, 1254)),
)

def prepare(check=False):
    results = []
    for filename, name, expected, size in ASSETS:
        source = ROOT / "dev/puppet-review-assets" / filename
        data = source.read_bytes()
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError(f"Review art changed: {filename}")
        if data[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", data[16:24]) != size or data[25] != 6:
            raise ValueError(f"Expected RGBA PNG canvas: {filename}")
        if not check:
            destination = ROOT / "Sources/Assets.xcassets" / (name + ".imageset")
            destination.mkdir(exist_ok=True)
            shutil.copyfile(source, destination / filename)
            (destination / "Contents.json").write_text(json.dumps({
                "images": [{"filename": filename, "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1}
            }, indent=2) + "\n", encoding="utf-8")
        results.append({"asset": name, "sha256": expected, "pixels": size})
    return {"verified": results, "staged": not check, "productionApproved": False}

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    print(json.dumps(prepare(parser.parse_args().check), indent=2))
