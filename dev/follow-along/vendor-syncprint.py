"""Copies syncprint.js into the app, byte for byte, and records its checksum.

Tellavision Follow along (Nov 14 2026). The app ships an exact copy of the
syncprint library (Sources/syncprint.js); the server ships the same file. The
checksum lives in two places, and FollowAlongTests fails when either differs
from the file:
  - Sources/FollowAlongEngine.swift, `static let scriptSHA256`
  - FollowAlongTests/syncprint.js.sha256, in the server's own format:
    "<sha256>  syncprint.js" and a newline, so the app's file and the
    server's (api/server/services/kadeSyncprint/syncprint.js.sha256) can be
    compared byte for byte.
.gitattributes keeps Sources/syncprint.js out of line-ending conversion.

Give the LibreChat fork's folder as well to copy the same file into the
server in the same step (its syncprint.js and its checksum file), so the two
copies cannot drift apart. Then run dev/follow-along/compare-syncprint.py
and both projects' tests.

Usage (Python only, no packages):
  python -I dev/follow-along/vendor-syncprint.py PATH/TO/syncprint.js [PATH/TO/LibreChat-fork]
"""
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SERVER_FOLDER = pathlib.Path("api") / "server" / "services" / "kadeSyncprint"


def checksum_line(digest):
    return (digest + "  syncprint.js\n").encode()


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__)
        return 2
    source = pathlib.Path(argv[1]).read_bytes()
    if b"\r\n" in source:
        print("The library has Windows line endings; the copies must stay LF. Not copied.")
        return 1
    digest = hashlib.sha256(source).hexdigest()
    engine = ROOT / "Sources" / "FollowAlongEngine.swift"
    raw = engine.read_bytes()
    pattern = re.compile(rb'static let scriptSHA256 = "[0-9a-f]{64}"')
    if len(pattern.findall(raw)) != 1:
        print("FollowAlongEngine.swift has no single scriptSHA256 line. Not changed.")
        return 1
    server = None
    if len(argv) == 3:
        server = pathlib.Path(argv[2]) / SERVER_FOLDER
        if not (server / "syncprint.js").is_file():
            print(f"No server copy at {server / 'syncprint.js'}. Nothing copied.")
            return 1
    (ROOT / "Sources" / "syncprint.js").write_bytes(source)
    (ROOT / "FollowAlongTests" / "syncprint.js.sha256").write_bytes(checksum_line(digest))
    engine.write_bytes(pattern.sub(b'static let scriptSHA256 = "' + digest.encode() + b'"', raw))
    if server is not None:
        (server / "syncprint.js").write_bytes(source)
        (server / "syncprint.js.sha256").write_bytes(checksum_line(digest))
    version = re.search(rb"var VERSION = '([^']+)'", source)
    print(f"syncprint {version.group(1).decode() if version else '?'}: {len(source)} bytes, sha256 {digest}")
    print("Copied into the app" + (" and the server." if server is not None else ". The server still needs the same file."))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
