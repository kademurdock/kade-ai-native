"""Copies syncprint.js into the app, byte for byte, and records its checksum.

Tellavision Follow along (Nov 14 2026). The app ships an exact copy of the
syncprint library (Sources/syncprint.js); the server ships the same file. The
checksum lives in two places, and FollowAlongTests fails when either differs
from the file:
  - Sources/FollowAlongEngine.swift, `static let scriptSHA256`
  - FollowAlongTests/syncprint.js.sha256
.gitattributes keeps Sources/syncprint.js out of line-ending conversion.

Usage (Python only, no packages): python -I dev/follow-along/vendor-syncprint.py PATH/TO/syncprint.js
"""
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    source = pathlib.Path(argv[1]).read_bytes()
    if b"\r\n" in source:
        print("The library has Windows line endings; the copies must stay LF. Not copied.")
        return 1
    digest = hashlib.sha256(source).hexdigest()
    (ROOT / "Sources" / "syncprint.js").write_bytes(source)
    (ROOT / "FollowAlongTests" / "syncprint.js.sha256").write_bytes((digest + "\n").encode())
    engine = ROOT / "Sources" / "FollowAlongEngine.swift"
    raw = engine.read_bytes()
    pattern = re.compile(rb'static let scriptSHA256 = "[0-9a-f]{64}"')
    if len(pattern.findall(raw)) != 1:
        print("FollowAlongEngine.swift has no single scriptSHA256 line. Not changed.")
        return 1
    engine.write_bytes(pattern.sub(b'static let scriptSHA256 = "' + digest.encode() + b'"', raw))
    version = re.search(rb"var VERSION = '([^']+)'", source)
    print(f"syncprint {version.group(1).decode() if version else '?'}: {len(source)} bytes, sha256 {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
