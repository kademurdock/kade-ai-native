"""Verify the registered character source art and bundled asset catalog.

Run --check without rewriting committed asset catalog entries. All build lanes
verify these source hashes; Release uses the same resources as simulator tests.
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
    ("kiana-body-support.png", "CharacterKianaBustBody", "241bdd2307fb2fa687ebaab47bd4159fb5ef25d4d99a5e17c65a15d0f3a22b86", (1145, 1374)),
    ("della-body-plate.png", "CharacterDellaBustBody", "e0709e31501d6b3e2b59a18c7cff93e1012b411e489b9ba9f956e8b72281018e", (1254, 1254)),
    ("della-head-alpha.png", "CharacterDellaBustMask", "036d2ce6292fec1cb0226fe69f584789d46eadf4625e925e293ed717fecc1b1a", (1254, 1254)),
    ("witherspoon-body-support.png", "CharacterWitherspoonBustBody", "b8cab50d34fd94fef153b711f24ab4bf24a9cc42c535fa43816fd5113843d8df", (1024, 1536)),
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
        destination = ROOT / "Sources/Assets.xcassets" / (name + ".imageset")
        if not check:
            destination.mkdir(exist_ok=True)
            shutil.copyfile(source, destination / filename)
            (destination / "Contents.json").write_text(json.dumps({
                "images": [{"filename": filename, "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1}
            }, indent=2) + "\n", encoding="utf-8")
        if (destination / filename).read_bytes() != data:
            raise ValueError(f"Bundled character art drifted: {name}")
        images = json.loads((destination / "Contents.json").read_text())["images"]
        if images != [{"filename": filename, "idiom": "universal"}]:
            raise ValueError(f"Bundled character entry drifted: {name}")
        results.append({"asset": name, "sha256": expected, "pixels": size})
    return {"verified": results, "staged": not check, "bundled": True}

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    print(json.dumps(prepare(parser.parse_args().check), indent=2))
