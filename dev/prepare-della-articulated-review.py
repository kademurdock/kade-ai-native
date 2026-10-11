"""Stage the optional Della art study for an unsigned simulator review only.

The source PNG lives outside Sources, so a normal Release has no study asset.
Run --prepare before xcodegen for a local Debug simulator review, then --clean
before any Release archive. Neither operation triggers a build or upload.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "dev/della-articulated-review/della-body-gesture-master-v1.png"
DESTINATION = ROOT / "Sources/Assets.xcassets/CharacterDellaArticulatedReview.imageset"
EXPECTED = "285b6e1f176b79ba08cfc7a4252a3d8864901eabbdcbc1e58f304299164206d2"
ENTRY = {"images": [{"filename": SOURCE.name, "idiom": "universal"}],
         "info": {"author": "xcode", "version": 1}}


def verify_source():
    data = SOURCE.read_bytes()
    if hashlib.sha256(data).hexdigest() != EXPECTED:
        raise ValueError("Della study source changed")
    if (data[:8] != b"\x89PNG\r\n\x1a\n" or
            struct.unpack(">II", data[16:24]) != (1254, 1254) or data[25] != 6):
        raise ValueError("Della study must remain the original square RGBA PNG")
    return data


def verify_staged(data):
    if not DESTINATION.exists():
        return False
    if (DESTINATION / SOURCE.name).read_bytes() != data:
        raise ValueError("Staged Della study changed; refusing to replace or remove it")
    if json.loads((DESTINATION / "Contents.json").read_text()) != ENTRY:
        raise ValueError("Staged Della catalog entry changed")
    if {p.name for p in DESTINATION.iterdir()} != {SOURCE.name, "Contents.json"}:
        raise ValueError("Unexpected study files; refusing to remove them")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--prepare", action="store_true")
    group.add_argument("--clean", action="store_true")
    args = parser.parse_args()
    data = verify_source()
    staged = verify_staged(data)
    if args.prepare and not staged:
        DESTINATION.mkdir()
        shutil.copyfile(SOURCE, DESTINATION / SOURCE.name)
        (DESTINATION / "Contents.json").write_text(json.dumps(ENTRY, indent=2) + "\n")
        staged = verify_staged(data)
    elif args.clean and staged:
        # Fixed destination, verified byte contents, and no recursive deletion.
        (DESTINATION / SOURCE.name).unlink()
        (DESTINATION / "Contents.json").unlink()
        DESTINATION.rmdir()
        staged = False
    print(json.dumps({"sourceSHA256": EXPECTED, "pixels": [1254, 1254],
                      "stagedForReview": staged, "productionRegistered": False}, indent=2))


if __name__ == "__main__":
    main()
