"""Compares the app's syncprint.js with the server's copy. A release step.

Tellavision Follow along (Nov 14 2026). The app (kade-ai-native,
Sources/syncprint.js) and the server (the LibreChat fork,
api/server/services/kadeSyncprint/syncprint.js) must ship the same syncprint
(design 5.4 item 1, risk 9). Each project's own test checks its copy against
its own checksum file only, so nothing else compares the two. Run this before
either side ships a change to Follow along, and before an iPhone release that
carries Follow along.

It checks that the two files are the same bytes, that each checksum file is
right for its own copy, and that the two checksum files are the same bytes
(both use the format "<sha256>  syncprint.js"). When the copies differ it
names the parts that differ, and says whether any of them is a part that
makes or reads fingerprints, so you can tell whether the server's
fingerprints are read the same way by the app.

To make them the same, from one syncprint commit:
  python -I dev/follow-along/vendor-syncprint.py PATH/TO/syncprint.js PATH/TO/LibreChat-fork

Usage (Python only, no packages):
  python -I dev/follow-along/compare-syncprint.py PATH/TO/LibreChat-fork
  python -I dev/follow-along/compare-syncprint.py --self-test
Exit 0: the same. Exit 1: they differ, so the release waits. Exit 2: a file is missing.
"""
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SERVER_FOLDER = pathlib.Path("api") / "server" / "services" / "kadeSyncprint"
# A new part starts at each top-level declaration inside the library's wrapper.
PART = re.compile(r"^  (?:function (\w+)\(|(\w+\.prototype\.\w+) = function\b|var (\w+) = )")
# The parts that make a fingerprint, write it, read it, or analyse a clip the
# same way. The matcher, the tracker and the planner run on the phone only.
FINGERPRINT = {"getPlan", "fftCore", "framePower", "Picker", "frameCount", "analyse", "printParams",
               "printProblem", "makePrint", "pairAll", "crc32", "put16", "put32", "get16", "get32",
               "encodePrint", "decodePrint", "MAGIC", "HEADER_BYTES", "EPS_POWER", "FORMAT_VERSION"}


def parts(text):
    """The library cut into named parts, in order. The comments and blank
    lines between two parts belong to neither (they introduce the next one)."""
    found = {}
    name = "(the opening)"
    lines = []

    def keep():
        while lines and (not lines[-1].strip() or lines[-1].strip().startswith("//")):
            lines.pop()
        found[name] = "\n".join(lines)

    for line in text.split("\n"):
        match = PART.match(line)
        if match:
            keep()
            name = next(group for group in match.groups() if group)
            lines = []
        lines.append(line)
    keep()
    return found


def is_fingerprint(name):
    return name in FINGERPRINT or name.startswith("Picker.prototype.")


def checksum_line(path):
    """A checksum file's line. A Windows checkout may end it with CR LF; the
    line itself is what is compared."""
    return path.read_bytes().replace(b"\r\n", b"\n") if path.is_file() else None


def self_test():
    """The script's own check: the same copies pass, a changed copy or a
    wrong checksum file fails, a missing folder is named."""
    import tempfile
    app = (ROOT / "Sources" / "syncprint.js").read_bytes()
    line = (hashlib.sha256(app).hexdigest() + "  syncprint.js\n").encode()
    results = []
    with tempfile.TemporaryDirectory() as folder:
        server = pathlib.Path(folder) / SERVER_FOLDER
        server.mkdir(parents=True)
        (server / "syncprint.js").write_bytes(app)
        (server / "syncprint.js.sha256").write_bytes(line)
        results.append(("the same copies", main(["", folder]), 0))
        (server / "syncprint.js.sha256").write_bytes(line.replace(b"\n", b"\r\n"))
        results.append(("a checksum file with a Windows line ending", main(["", folder]), 0))
        (server / "syncprint.js.sha256").write_bytes(line[:-2] + b"x\n")
        results.append(("a wrong checksum file", main(["", folder]), 1))
        changed = app.replace(b"var GAIN_KEEP = 8;", b"var GAIN_KEEP = 9;")
        (server / "syncprint.js").write_bytes(changed)
        (server / "syncprint.js.sha256").write_bytes((hashlib.sha256(changed).hexdigest() + "  syncprint.js\n").encode())
        results.append(("a changed copy", main(["", folder]), 1))
        results.append(("no server copy", main(["", str(pathlib.Path(folder) / "nothing")]), 2))
    failed = [name for name, got, want in results if got != want]
    print("compare-syncprint self-test: " + ("passed" if not failed else "FAILED: " + ", ".join(failed)))
    return 1 if failed else 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) != 2:
        print(__doc__)
        return 2
    app = ROOT / "Sources" / "syncprint.js"
    app_sum = ROOT / "FollowAlongTests" / "syncprint.js.sha256"
    server_dir = pathlib.Path(argv[1]) / SERVER_FOLDER
    server = server_dir / "syncprint.js"
    server_sum = server_dir / "syncprint.js.sha256"
    for path in (app, app_sum, server, server_sum):
        if not path.is_file():
            print(f"Missing: {path}")
            return 2
    app_bytes = app.read_bytes()
    server_bytes = server.read_bytes()
    app_digest = hashlib.sha256(app_bytes).hexdigest()
    server_digest = hashlib.sha256(server_bytes).hexdigest()
    print(f"App copy:    {app_digest}")
    print(f"Server copy: {server_digest}")
    problems = []
    if checksum_line(app_sum) != (app_digest + "  syncprint.js\n").encode():
        problems.append("The app's checksum file does not match its copy (FollowAlongTests/syncprint.js.sha256).")
    if checksum_line(server_sum) != (server_digest + "  syncprint.js\n").encode():
        problems.append("The server's checksum file does not match its copy.")
    if app_bytes == server_bytes:
        if not problems:
            print("The same: the app and the server ship the same syncprint.js, and both checksum files agree.")
            return 0
    else:
        problems.append("The two copies differ. Copy one syncprint commit into both before shipping.")
        mine = parts(app_bytes.decode("utf-8", "replace"))
        theirs = parts(server_bytes.decode("utf-8", "replace"))
        changed = [name for name in mine if name in theirs and mine[name] != theirs[name]]
        only_app = [name for name in mine if name not in theirs]
        only_server = [name for name in theirs if name not in mine]
        if changed:
            print("Parts that differ: " + ", ".join(changed))
        if only_app:
            print("Only in the app's copy: " + ", ".join(only_app))
        if only_server:
            print("Only in the server's copy: " + ", ".join(only_server))
        touched = [name for name in changed + only_app + only_server if is_fingerprint(name)]
        if touched:
            print("Fingerprint parts differ (" + ", ".join(touched) + "): the server's fingerprints may not suit the app.")
        else:
            print("No part that makes or reads a fingerprint differs, and a fingerprint carries its own settings:"
                  " the app reads the server's fingerprints the same way. The release still waits for one copy in both.")
    for problem in problems:
        print(problem)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
