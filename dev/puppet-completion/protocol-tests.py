"""Synthetic, memory-only checks of the completion receipt boundary.

These fixtures are deliberately constructed here. They are not screenshots,
native observations, phone/battery measurements or release evidence. Importing
the helper is safe; source/build/simulator/service entry points are fenced off.
Run with Python -B so this test does not create bytecode or copy artifacts.
"""
import ast
import cmath
import copy
import ctypes
from datetime import datetime, timezone
import errno
import hashlib
import importlib.util
from io import BytesIO
import json
import math
from pathlib import Path, PurePosixPath
import plistlib
import re
import subprocess
import struct
import sys
import unittest
from unittest.mock import patch
import zlib

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
SOURCE = "a" * 40
CHECKS = 0
FORBIDDEN_CALLS = 0


def forbidden(*args, **kwargs):
    global FORBIDDEN_CALLS
    FORBIDDEN_CALLS += 1
    raise AssertionError("A pure protocol test attempted external/runtime work")


# This module only defines source/CLI functions at import. Guard the underlying
# process calls as well as every relevant host entry point before any check.
subprocess.run = forbidden
subprocess.check_output = forbidden
subprocess.Popen = forbidden
spec = importlib.util.spec_from_file_location("puppet_completion_protocol", ROOT / "dev/puppet-completion-audit.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
NATIVE_SNAPSHOT=audit.host.native_process_snapshot
NATIVE_BIRTH=audit.host.native_process_birth
OWNED_IDENTITY=audit.host.owned_process_identity
COMPILED_TESTS=audit.host.compiled_tests
audit.host.os.kill=forbidden
audit.host.native_process_snapshot=forbidden
audit.host.native_process_birth=forbidden
audit.host.owned_process_identity=forbidden
for entry in ("source", "initial_source", "sim", "boot_ui", "run_ui", "compiled_tests", "simulator_record", "operation_remaining", "emit", "original_capture_path", "publish_capture_copy", "verified_capture_bytes"):
    setattr(audit.host, entry, forbidden)
for entry in ("save", "ui", "capture", "emit", "main"):
    setattr(audit, entry, forbidden)


# Explicit rest registration, independent of the validator's inventory. The
# fixture arm uses complex-plane rigid rotations to retain both bone lengths.
REST = {
    "harley": ((.20, .86), (.17, 1.09), (.30, 1.25), (.80, .86), (.83, 1.09), (.70, 1.25)),
    "kiana": ((.12, .84), (.13, 1.09), (.29, 1.26), (.88, .90), (.87, 1.12), (.71, 1.26)),
    "lilly": ((.23, .87), (.19, 1.09), (.31, 1.26), (.77, .87), (.81, 1.09), (.69, 1.26)),
    "witherspoon": ((.22, .85), (.18, 1.09), (.31, 1.25), (.78, .85), (.82, 1.09), (.69, 1.25)),
}
CROP = {"harley": 540, "kiana": 620, "lilly": 700, "witherspoon": 620}
PEOPLE = ("harley", "kiana", "lilly", "della", "witherspoon", "lilly-private", "angel")
POSES = ("neutral", "gesturePeak", "settled")


def swift_registrations(source):
    """Read the actual six named renderer vectors, never a copied test table."""
    marker = "static func registration(_ kind: CharacterConversationBodyArtwork.Kind) -> Registration {"
    if len(source.encode()) > 64 * 1024 or source.count(marker) != 1:
        raise ValueError("Missing, duplicate or oversized Swift registration source")
    start = source.index(marker)
    end = source.find("    static func arm(", start)
    if end < 0:
        raise ValueError("Missing Swift registration boundary")
    section = source[start:end]
    cases = list(re.finditer(r"^\s*case \.([a-z]+):", section, re.M))
    kinds = {"kiana", "harley", "lilly", "witherspoon"}
    if len(cases) != 4 or {match[1] for match in cases} != kinds:
        raise ValueError("Missing or duplicate Swift registration kind")
    names = ("leftShoulder", "leftElbow", "leftWrist", "rightShoulder", "rightElbow", "rightWrist")
    scalar = r"([+-]?(?:\d+(?:\.\d*)?|\.\d+))"
    vector = re.compile(r"\b(" + "|".join(names) + r")\s*:\s*\.init\(\s*x:\s*" + scalar
                        + r"\s*,\s*y:\s*" + scalar + r"\s*\)")
    result = {}
    for index, case in enumerate(cases):
        block = section[case.end():cases[index + 1].start() if index + 1 < len(cases) else len(section)]
        points = list(vector.finditer(block))
        if len(points) != 6 or {point[1] for point in points} != set(names):
            raise ValueError("Missing or duplicate Swift joint vector")
        values = {point[1]: (float(point[2]), float(point[3])) for point in points}
        if not all(math.isfinite(value) for pair in values.values() for value in pair):
            raise ValueError("Nonfinite Swift joint vector")
        result[case[1]] = tuple(values[name] for name in names)
    return result


def registration_coherent(source, registration):
    if swift_registrations(source) != registration:
        raise ValueError("Native capture validator differs from the actual Swift rig")


def set_arm(values, person, side, shoulder_degrees, elbow_degrees, wrist_degrees):
    kind = "lilly" if person == "lilly-private" else person
    points = REST[kind][:3] if side == "left" else REST[kind][3:]
    shoulder, elbow, wrist = (complex(*point) for point in points)
    upper = (elbow - shoulder) * cmath.exp(1j * math.radians(shoulder_degrees))
    lower = (wrist - elbow) * cmath.exp(1j * math.radians(shoulder_degrees + elbow_degrees))
    elbow = shoulder + upper
    wrist = elbow + lower
    for name, point in (("Shoulder", shoulder), ("Elbow", elbow), ("Wrist", wrist)):
        values[side + name + "X"] = point.real
        values[side + name + "Y"] = point.imag
    values[side + "ShoulderDegrees"] = shoulder_degrees
    values[side + "ElbowDegrees"] = elbow_degrees
    values[side + "WristDegrees"] = wrist_degrees
    values[side + "HandDegrees"] = math.degrees(cmath.phase(lower)) - 90 + wrist_degrees
    values[side + "Openness"] = .12


def fixture(person, pose):
    kind = "lilly" if person == "lilly-private" else person
    peak = pose == "gesturePeak"
    values = dict(headAngle=.12, bodyAngle=.08, headOffsetY=.10, bodyOffsetY=0.0,
                  nearArmAngle=0.0, farArmAngle=0.0)
    if kind in REST:
        set_arm(values, person, "left", .8 if peak else 0, -14 if peak else 0, -4 if peak else 0)
        set_arm(values, person, "right", -.6 if peak else 0, 10 if peak else 0, 3 if peak else 0)
        values.update(bodyDegrees=.08, bodyLift=.001, headDegrees=.12, headLift=.0005)
        values.update(headAngle=values["headDegrees"], bodyAngle=values["bodyDegrees"],
                      headOffsetY=values["headLift"] * CROP[kind], bodyOffsetY=-values["bodyLift"] * CROP[kind],
                      nearArmAngle=values["rightShoulderDegrees"], farArmAngle=values["leftShoulderDegrees"])
    elif person == "della":
        values.update(leftShoulderDegrees=.35 if peak else 0, rightShoulderDegrees=-.45 if peak else 0,
                      nearArmAngle=-.45 if peak else 0, farArmAngle=.35 if peak else 0)
    else:
        values.update(claspDegrees=.40 if peak else 0, claspOffsetX=.001 if peak else 0,
                      claspOffsetY=-.002 if peak else 0, gazeX=.06, gazeY=.04,
                      nearArmAngle=.40 if peak else 0, farArmAngle=.40 if peak else 0)
    height = 208 if person == "angel" else 208 * 620 / 414
    time = 1000 + PEOPLE.index(person) * 100 + (-.05 if pose == "neutral" else .65 if peak else 14.25)
    fps = 12 if pose == "neutral" else 24
    return {
        "schema": "kade.puppet-completion-ready.v1", "source": SOURCE,
        "phase": person + "-" + pose, "character": person, "avatarPath": "/images/" + audit.IDS[person][1],
        "appearance": "light", "windowPoints": [440, 956],
        "geometry": {"window": [0, 0, 440, 956], "stage": [96, 196, 248, height + 48],
                     "portrait": [96, 200, 248, height + 40]},
        "render": {"agentID": audit.IDS[person][0], "renderer": audit.RENDERERS[person],
                   "assets": list(audit.ASSETS[person]), "side": 208, "height": height, "time": time,
                   "active": True, "framesPerSecond": fps, "paused": False,
                   "face": 0 if pose == "neutral" else 1, "viseme": 2 if peak else 0, "values": values},
        "samples": {"count": 9, "active": 9, "paused": 0, "distinctTimes": 9,
                    "distinctVectors": 4, "maximumFPS": fps, "invalid": False},
        "policy": "normal", "captureFrozen": True, "completedInputs": 9,
        "jointCoordinateSpace": "rendererLocalBeforeParentTransform", "syntheticOutput": True,
        "networkRequestsBlocked": True, "blockedRequestCount": 0,
        "audioStarted": False, "microphoneStarted": False, "cameraStarted": False,
        "physicalPhoneVerified": False, "batteryMeasured": False, "voiceOverVerified": False,
    }


def synthetic_png_chunk(kind, payload):
    """Construct a synthetic PNG chunk; this never opens an image or file."""
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)


def synthetic_png(raw, width=320, height=600, depth=8, color=6, compression=0, filtering=0, interlace=0, chunks=None):
    header = struct.pack(">IIBBBBB", width, height, depth, color, compression, filtering, interlace)
    body = [(b"IHDR", header), (b"IDAT", zlib.compress(raw)), (b"IEND", b"")] if chunks is None else chunks
    return b"\x89PNG\r\n\x1a\n" + b"".join(synthetic_png_chunk(kind, payload) for kind, payload in body)


def synthetic_pixel_rows(color=6, uniform=None, transparent=False):
    """Invent local pixels, not native/visual proof or copied screenshots."""
    channels = 4 if color == 6 else 3
    if uniform is not None:
        return [uniform * 320] * 600
    rows = []
    for y in range(600):
        pixels = bytearray()
        for x in range(320):
            pixels.extend(((x * 13 + y) % 256, (x + y * 7) % 256, (x * 3 + y * 11) % 256))
            if channels == 4:
                pixels.append(0 if transparent else 255)
        rows.append(bytes(pixels))
    return rows


def synthetic_filtered_scanlines(rows, channels, filters):
    """Encode independent PNG predictor fixtures, including preceding-row input."""
    result = bytearray()
    previous = bytes(len(rows[0]))
    encoded_rows = {}
    for y, row in enumerate(rows):
        kind = filters[y % len(filters)]
        result.append(kind)
        key = (row, previous, kind)
        if key in encoded_rows:
            result.extend(encoded_rows[key])
            previous = row
            continue
        encoded = bytearray()
        for index, value in enumerate(row):
            left = row[index - channels] if index >= channels else 0
            up = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if kind == 0:
                predictor = 0
            elif kind == 1:
                predictor = left
            elif kind == 2:
                predictor = up
            elif kind == 3:
                predictor = (left + up) // 2
            else:
                estimate = left + up - upper_left
                distances = (abs(estimate - left), abs(estimate - up), abs(estimate - upper_left))
                predictor = (left, up, upper_left)[distances.index(min(distances))]
            encoded.append((value - predictor) & 255)
        encoded_rows[key] = bytes(encoded)
        result.extend(encoded)
        previous = row
    return bytes(result)


class ProtocolChecks(unittest.TestCase):
    def compiled_memory(self, sidecar=None, dangling=False, main=b"synthetic-main-code-v1", other_sidecars=False, hash_log=None):
        """Exercise the real compiled_tests reader with only invented in-memory files."""
        host = audit.host
        root = "/memory/identity-audit"
        products = root + "/build/della-host-layout-simulator/Build/Products"
        app = products + "/Debug-iphonesimulator/KadeAI.app"
        runner = products + "/Debug-iphonesimulator/KadeAIUITests-Runner.app"
        bundle = runner + "/PlugIns/KadeAIUITests.xctest"
        run = products + "/KadeAIA11yAudit_synthetic.xctestrun"
        initial = {"sha": SOURCE}
        files = {run: plistlib.dumps({"__xctestrun_metadata__": {"FormatVersion": 1}, "KadeAIUITests": {
            "BlueprintName": "KadeAIUITests", "IsUITestBundle": True, "UseDestinationArtifacts": False,
            "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/KadeAIUITests-Runner.app",
            "TestBundlePath": "__TESTHOST__/PlugIns/KadeAIUITests.xctest",
            "UITargetAppPath": "__TESTROOT__/Debug-iphonesimulator/KadeAI.app"}})}
        directories = {products, app, runner, bundle}; links = set(); hashed = hash_log if hash_log is not None else []
        for path, executable, identifier in ((app, "KadeAI", host.BUNDLE_ID),
            (runner, "KadeAIUITests-Runner", "com.kademurdock.kadeai.uitests.xctrunner"),
            (bundle, "KadeAIUITests", "com.kademurdock.kadeai.uitests")):
            info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": executable, "DTPlatformName": "iphonesimulator"}
            if path == app:
                info.update(CFBundleShortVersionString="2.2.14", CFBundleVersion="100",
                            UISupportedInterfaceOrientations=["UIInterfaceOrientationPortrait"])
            files[path + "/Info.plist"] = plistlib.dumps(info)
            files[path + "/" + executable] = main if path == app else ("synthetic-" + executable).encode()
        if sidecar:
            path = app + "/" + sidecar
            if dangling: links.add(path)
            else: files[path] = b"synthetic-unhashed-app-code"
        if other_sidecars:
            files[runner + "/KadeAIUITests-Runner.debug.dylib"] = b"synthetic-other-role"
            files[bundle + "/__preview.dylib"] = b"synthetic-other-role"
        class MemoryPath:
            def __init__(self, value): self.value = str(value)
            def __str__(self): return self.value
            def __eq__(self, other): return isinstance(other, MemoryPath) and self.value == other.value
            def __truediv__(self, value): return MemoryPath(str(PurePosixPath(self.value) / value))
            @property
            def parent(self): return MemoryPath(str(PurePosixPath(self.value).parent))
            @property
            def name(self): return PurePosixPath(self.value).name
            def resolve(self, strict=False): return self
            def is_relative_to(self, other): return PurePosixPath(self.value).is_relative_to(PurePosixPath(str(other)))
            def relative_to(self, other): return MemoryPath(str(PurePosixPath(self.value).relative_to(PurePosixPath(str(other)))))
            def glob(self, pattern):
                self_test.assertEqual((self.value, pattern), (products, "KadeAIA11yAudit_*.xctestrun"))
                return [MemoryPath(run)]
            def is_dir(self): return self.value in directories
            def is_file(self): return self.value in files
            def exists(self): return self.value in files or self.value in directories
            def is_symlink(self): return self.value in links
            def stat(self): return type("MemoryStat", (), {"st_size": len(files[self.value])})()
            def read_bytes(self): return files[self.value]
        self_test = self
        def hash_memory(path):
            hashed.append(str(path))
            return hashlib.sha256(path.read_bytes()).hexdigest()
        with patch.object(host, "Path", MemoryPath), patch.object(host, "ROOT", MemoryPath(root)), \
             patch.object(host, "APP", MemoryPath(app)), patch.object(host, "initial_source", return_value=initial), \
             patch.object(host, "sha", side_effect=hash_memory):
            return COMPILED_TESTS(SOURCE, emit_inventory=False), hashed, app

    def test_compiled_app_cannot_hide_code_in_debug_or_preview_sidecars(self):
        global CHECKS
        result, hashed, app = self.compiled_memory()
        self.assertEqual(set(result), {"schema", "source", "formatVersion", "xctestrun", "xctestrunSha256", "artifacts",
                                       "unsignedSimulatorOnly", "testTarget"}); CHECKS += 1
        self.assertEqual(result["schema"], "kade.della-host-compiled-tests.v1"); CHECKS += 1
        for item in result["artifacts"].values():
            self.assertEqual(set(item), {"path", "bundleId", "infoPlistSha256", "executableSha256"}); CHECKS += 1
        self.assertIn(app + "/KadeAI", hashed); CHECKS += 1
        # The real integration must reject each presence mode before reaching
        # main-binary hashing, rather than merely testing a detached predicate.
        for leaf in ("KadeAI.debug.dylib", "__preview.dylib"):
            for dangling in (False, True):
                calls = []
                with self.assertRaisesRegex(RuntimeError, "Compiled app code is split from the fingerprinted main executable"):
                    self.compiled_memory(leaf, dangling, hash_log=calls)
                self.assertFalse(calls); CHECKS += 1
        different, _, _ = self.compiled_memory(main=b"synthetic-main-code-v2")
        self.assertNotEqual(result["artifacts"]["app"]["executableSha256"],
                            different["artifacts"]["app"]["executableSha256"]); CHECKS += 1
        self.assertEqual(result["artifacts"]["app"]["infoPlistSha256"],
                         different["artifacts"]["app"]["infoPlistSha256"]); CHECKS += 1
        other_roles, _, _ = self.compiled_memory(other_sidecars=True)
        self.assertEqual(other_roles, result); CHECKS += 1

    def test_app_debug_override_preserves_every_other_project_setting_and_build_argument(self):
        global CHECKS
        project = (ROOT / "project.yml").read_text(encoding="utf-8")
        helper = (ROOT / "dev/della-host-layout-audit.py").read_text(encoding="utf-8")
        original_project_sha = "a74a49f90313513ba42a4d7d784113fefb94635297b99be894606293eddad892"
        # Bind the exact original command expression bytes. ast.dump is a
        # Python-version-dependent representation, not the build arguments.
        original_command_sha = "bf5b25c7e5fd0070363cb4d18c44c755902d21c1a1dbccfa0dda2f8999293999"
        snippet = '      configs:\n        Debug:\n          ENABLE_DEBUG_DYLIB: "NO"\n'
        def coherent_project(value):
            section = re.search(r"^  KadeAI:\n(.*?)(?=^  [A-Za-z][A-Za-z0-9]*:|\Z)", value, re.M | re.S)
            if value.count("ENABLE_DEBUG_DYLIB") != 1 or value.count(snippet) != 1 or section is None \
               or snippet not in section[1] or hashlib.sha256(value.replace(snippet, "").encode()).hexdigest() != original_project_sha:
                raise ValueError("The sole KadeAI Debug configuration must preserve all other project bytes")
        def command_expression(value):
            builds = [node for node in ast.parse(value).body if isinstance(node, ast.FunctionDef) and node.name == "build_tests"]
            if len(builds) != 1: raise ValueError("Missing unique build_tests function")
            commands = [node.value for node in ast.walk(builds[0]) if isinstance(node, ast.Assign)
                        and any(isinstance(target, ast.Name) and target.id == "command" for target in node.targets)]
            if len(commands) != 1 or hashlib.sha256(ast.get_source_segment(value, commands[0]).encode()).hexdigest() != original_command_sha:
                raise ValueError("The single unsigned Debug host build argument list changed")
        coherent_project(project); command_expression(helper); CHECKS += 2
        for changed in (project.replace('ENABLE_DEBUG_DYLIB: "NO"', 'ENABLE_DEBUG_DYLIB: false', 1), project.replace("        Debug:\n", "        Release:\n", 1),
                        project.replace(snippet, ""), project + snippet, project.replace("  KadeAI:\n", "  AnotherApp:\n", 1),
                        project.replace("MARKETING_VERSION: \"2.2.14\"", "MARKETING_VERSION: \"2.2.15\"", 1)):
            with self.assertRaises(ValueError): coherent_project(changed)
            CHECKS += 1
        with self.assertRaises(ValueError): command_expression(helper.replace("'-configuration','Debug'", "'-configuration','Release'", 1))
        CHECKS += 1
        with self.assertRaises(ValueError): command_expression(helper.replace("'build-for-testing']", "'ENABLE_DEBUG_DYLIB=NO','build-for-testing']", 1))
        CHECKS += 1

    def png_memory_path(self, content):
        class MemoryPNG:
            name = "synthetic-frame.png"
            def read_bytes(self):
                return content
        return MemoryPNG()

    def png_rejected(self, content):
        global CHECKS
        with self.assertRaises((RuntimeError, ValueError, zlib.error)):
            audit.host.png(self.png_memory_path(content))
        CHECKS += 1

    def test_reconstructed_blank_pngs_cannot_be_rendering_proof(self):
        # Valid CRC/zlib/filter bytes cannot make a black or empty framebuffer
        # useful evidence. Filters can make encoded black bytes non-uniform.
        for color, channels in ((2, 3), (6, 4)):
            for rgb in (b"\0\0\0", b"\xff\xff\xff", b"\x7f\x7f\x7f"):
                pixel = rgb + (b"\xff" if channels == 4 else b"")
                for filtering in range(5):
                    raw = synthetic_filtered_scanlines(synthetic_pixel_rows(color, pixel), channels, [filtering])
                    self.png_rejected(synthetic_png(raw, color=color))
        raw = synthetic_filtered_scanlines(synthetic_pixel_rows(6, b"\0\0\0\0"), 4, [0, 1, 2, 3, 4])
        self.png_rejected(synthetic_png(raw))
        # Invisible RGB variation must not disguise an entirely transparent image.
        raw = synthetic_filtered_scanlines(synthetic_pixel_rows(transparent=True), 4, [4, 3, 2, 1, 0])
        self.png_rejected(synthetic_png(raw))
        # One visible color plus changing hidden RGB/alpha still has no visible
        # app structure, despite nonuniform reconstructed RGBA bytes.
        for pixels in (b"\x7f\x7f\x7f\xff\x7f\x7f\x7f\x40",
                       b"\x7f\x7f\x7f\xff\x01\x02\x03\0"):
            raw = synthetic_filtered_scanlines([pixels * 160] * 600, 4, [0, 1, 2, 3, 4])
            self.png_rejected(synthetic_png(raw))

    def test_real_pixel_png_filters_keep_exact_public_metadata(self):
        global CHECKS
        for color, channels in ((2, 3), (6, 4)):
            raw = synthetic_filtered_scanlines(synthetic_pixel_rows(color), channels, [0, 1, 2, 3, 4])
            content = synthetic_png(raw, color=color)
            self.assertEqual(audit.host.png(self.png_memory_path(content)), {
                "file": "synthetic-frame.png", "bytes": len(content), "sha256": hashlib.sha256(content).hexdigest(),
                "pixels": [320, 600]})
            CHECKS += 1
            # Consecutive split IDAT and native ancillary chunks retain the exact
            # original bytes/hash rather than a recompressed image proxy.
            header = struct.pack(">IIBBBBB", 320, 600, 8, color, 0, 0, 0)
            compressed = zlib.compress(raw); middle = len(compressed) // 2
            content = synthetic_png(raw, chunks=[(b"IHDR", header), (b"sRGB", b"\0"), (b"PLTE", b"\0\0\0\xff\xff\xff"),
                (b"IDAT", compressed[:middle]), (b"IDAT", compressed[middle:]), (b"IEND", b"")])
            self.assertEqual(audit.host.png(self.png_memory_path(content))["sha256"], hashlib.sha256(content).hexdigest())
            CHECKS += 1
            # tRNS changes RGB visibility and is outside the narrowly supported
            # native RGB/RGBA screenshot contract. Never ignore its semantics.
            self.png_rejected(synthetic_png(raw, color=color, chunks=[(b"IHDR", header),
                (b"tRNS", b"\0" * 6), (b"IDAT", compressed), (b"IEND", b"")]))

    def test_png_decode_is_bounded_exact_and_fail_closed(self):
        raw = synthetic_filtered_scanlines(synthetic_pixel_rows(), 4, [0])
        header = struct.pack(">IIBBBBB", 320, 600, 8, 6, 0, 0, 0)
        compressed = zlib.compress(raw)
        for options in ({"depth": 16}, {"depth": 1}, {"color": 3}, {"color": 0}, {"color": 4},
                        {"compression": 1}, {"filtering": 1}, {"interlace": 1}, {"width": 319}, {"height": 599}):
            self.png_rejected(synthetic_png(raw, **options))
        last_row = len(raw) - (320 * 4 + 1)
        for malformed in (raw[:-1], raw + b"\0", raw + b"\0" * len(raw), b"\5" + raw[1:],
                          raw[:last_row] + b"\5" + raw[last_row + 1:]):
            self.png_rejected(synthetic_png(malformed))
        for chunks in (
            [(b"IHDR", header), (b"IDAT", compressed[:-1]), (b"IEND", b"")],
            [(b"IHDR", header), (b"IDAT", compressed + b"trailing"), (b"IEND", b"")],
            [(b"IHDR", header), (b"IDAT", compressed + zlib.compress(raw)), (b"IEND", b"")],
            [(b"IHDR", header), (b"IDAT", b"not-zlib"), (b"IEND", b"")],
            [(b"IHDR", header), (b"IHDR", header), (b"IDAT", compressed), (b"IEND", b"")],
            [(b"IHDR", header), (b"IDAT", compressed), (b"IEND", b"unexpected")],
            [(b"IHDR", header), (b"IDAT", compressed[:1]), (b"tEXt", b"fixture"), (b"IDAT", compressed[1:]), (b"IEND", b"")],
            [(b"IHDR", header), (b"ABCD", b"unknown critical"), (b"IDAT", compressed), (b"IEND", b"")],
            [(b"IHDR", header), (b"ABC1", b"invalid type"), (b"IDAT", compressed), (b"IEND", b"")],
            [(b"IHDR", header), (b"tExt", b"reserved bit"), (b"IDAT", compressed), (b"IEND", b"")],
            [(b"IHDR", header), (b"PLTE", b""), (b"IDAT", compressed), (b"IEND", b"")],
            [(b"IHDR", header), (b"PLTE", b"\0\0"), (b"IDAT", compressed), (b"IEND", b"")],
            [(b"IHDR", header), (b"PLTE", b"\0" * 771), (b"IDAT", compressed), (b"IEND", b"")],
            [(b"IHDR", header), (b"IEND", b"")],
            [(b"IHDR", header), (b"IDAT", compressed)],
        ):
            self.png_rejected(synthetic_png(raw, chunks=chunks))
        content = synthetic_png(raw)
        self.png_rejected(content[:-1])
        self.png_rejected(content + b"trailing")
        corrupted = bytearray(content); corrupted[-13] ^= 1
        self.png_rejected(bytes(corrupted))
        self.png_rejected(content[:33] + struct.pack(">I", 0xffffffff) + content[37:])


    def lossless_fixture(self,color=6):
        channels=3 if color==2 else 4
        raw=synthetic_filtered_scanlines(synthetic_pixel_rows(color),channels,[0,1,2,3,4])
        header=struct.pack('>IIBBBBB',320,600,8,color,0,0,0)
        compressed=zlib.compress(raw,0);middle=len(compressed)//2
        chunks=[(b'IHDR',header),(b'sRGB',b'\0'),(b'pHYs',struct.pack('>IIB',3780,3780,1)),
                (b'IDAT',compressed[:middle]),(b'IDAT',compressed[middle:]),(b'tEXt',b'fixture\0native bytes retained'),(b'IEND',b'')]
        return synthetic_png(raw,chunks=chunks),raw

    def test_lossless_capture_copy_retains_original_crc_chunks_and_all_scanlines(self):
        global CHECKS
        for color in (2,6):
            original,scanlines=self.lossless_fixture(color)
            encoded,record=audit.host.encode_capture_png(original,'synthetic-frame.png')
            self.assertLess(len(encoded),len(original));self.assertEqual(record['method'],'zlib9')
            metadata=audit.host.verify_capture_encoding(original,encoded,record,'synthetic-frame.png')
            self.assertEqual(record['originalSha256'],hashlib.sha256(original).hexdigest())
            self.assertEqual(record['encodedSha256'],hashlib.sha256(encoded).hexdigest())
            self.assertEqual(record['inflatedSha256'],hashlib.sha256(scanlines).hexdigest())
            self.assertEqual(metadata,audit.host.png(self.png_memory_path(encoded)))
            before=audit.host._capture_png_parts(original,'synthetic-frame.png')
            after=audit.host._capture_png_parts(encoded,'synthetic-frame.png')
            self.assertEqual(before[2],after[2]);self.assertEqual(before[2],scanlines)
            self.assertEqual([c for k,c in before[1] if k!=b'IDAT'],[c for k,c in after[1] if k!=b'IDAT'])
            CHECKS+=10

    def test_lossless_capture_identity_never_publishes_a_larger_copy(self):
        global CHECKS
        original,_=self.lossless_fixture()
        first,record=audit.host.encode_capture_png(original,'synthetic-frame.png')
        second,identity=audit.host.encode_capture_png(first,'synthetic-frame.png')
        self.assertEqual(second,first);self.assertEqual(identity['method'],'identity')
        self.assertEqual(identity['originalSha256'],identity['encodedSha256'])
        self.assertEqual(identity['originalBytes'],identity['encodedBytes']);CHECKS+=4

    def test_lossless_capture_receipt_binds_both_original_and_published_bytes(self):
        global CHECKS
        original,raw=self.lossless_fixture();encoded,record=audit.host.encode_capture_png(original,'synthetic-frame.png')
        changed_raw=bytearray(raw);changed_raw[5]^=1
        original_parts=audit.host._capture_png_parts(encoded,'synthetic-frame.png')
        changed=b'\x89PNG\r\n\x1a\n'+b''.join(synthetic_png_chunk(b'IDAT',zlib.compress(bytes(changed_raw),9)) if kind==b'IDAT' else chunk for kind,chunk in original_parts[1])
        for before,after in ((changed,encoded),(encoded,encoded),(original,changed),(original,encoded[:-1]),(original,encoded+b'extra')):
            with self.assertRaises(RuntimeError):audit.host.verify_capture_encoding(before,after,record,'synthetic-frame.png')
            CHECKS+=1
        # Updating the published file hash alone cannot hide altered pixels.
        forged=dict(record,encodedSha256=hashlib.sha256(changed).hexdigest(),encodedBytes=len(changed))
        with self.assertRaises(RuntimeError):audit.host.verify_capture_encoding(original,changed,forged,'synthetic-frame.png')
        CHECKS+=1
        before=audit.host._capture_png_parts(encoded,'synthetic-frame.png')
        changed_chunks=b'\x89PNG\r\n\x1a\n'+b''.join(synthetic_png_chunk(b'pHYs',struct.pack('>IIB',1000,1000,1)) if kind==b'pHYs' else chunk for kind,chunk in before[1])
        forged=dict(record,encodedSha256=hashlib.sha256(changed_chunks).hexdigest(),encodedBytes=len(changed_chunks))
        with self.assertRaises(RuntimeError):audit.host.verify_capture_encoding(original,changed_chunks,forged,'synthetic-frame.png')
        CHECKS+=1

    def test_lossless_capture_rejects_malformed_and_forged_encoding_records(self):
        global CHECKS
        original,_=self.lossless_fixture();encoded,record=audit.host.encode_capture_png(original,'synthetic-frame.png')
        for key in record:
            changed=dict(record);del changed[key]
            with self.assertRaises(RuntimeError):audit.host.verify_capture_encoding(original,encoded,changed,'synthetic-frame.png')
            CHECKS+=1
        changes=[('schema','wrong'),('method','lossy'),('originalFile','../native.png'),('originalFile','native-originals/other.png'),
                 ('originalBytes',True),('originalBytes',0),('encodedBytes',True),('encodedBytes',len(encoded)+1),
                 ('inflatedBytes',False),('inflatedBytes',72_006_001),('inflatedBytes',1),('inflatedSha256','0'*64),
                 ('nonIdatSha256','0'*64),('originalSha256','0'*64),('encodedSha256','0'*64)]
        for key,value in changes:
            with self.assertRaises(RuntimeError):audit.host.verify_capture_encoding(original,encoded,dict(record,**{key:value}),'synthetic-frame.png')
            CHECKS+=1
        with self.assertRaises(RuntimeError):audit.host.verify_capture_encoding(original,encoded,dict(record,extra=True),'synthetic-frame.png')
        CHECKS+=1
        for name in ('../native.png','sub/native.png','sub'+chr(92)+'native.png','not-a-png'):
            with self.assertRaises(RuntimeError):audit.host.encode_capture_png(original,name)
            CHECKS+=1

    def test_lossless_capture_inventory_requires_every_original_receipt(self):
        global CHECKS
        original,_=self.lossless_fixture();name='della-host-test.png'
        encoded,record=audit.host.encode_capture_png(original,name)
        metadata=audit.host.verify_capture_encoding(original,encoded,record,name)
        report={'passed':True,'captures':{'test':metadata},'captureEncodings':{'test':record}}
        audit.host.validate_capture_encoding_inventory(report,{'test'},'della-host-');CHECKS+=1
        variants=[dict(report,captureEncodings={}),dict(report,captures={}),dict(report,captureEncodings=None),
                  dict(report,captureEncodings={'test':record,'extra':record}),dict(report,captures={'extra':metadata})]
        for changed in variants:
            with self.assertRaises(RuntimeError):audit.host.validate_capture_encoding_inventory(changed,{'test'},'della-host-')
            CHECKS+=1
        with self.assertRaises(RuntimeError):audit.host.validate_capture_encoding_inventory(report,{'test','missing'},'della-host-')
        CHECKS+=1
        bad=copy.deepcopy(report);bad['captures']['test']['sha256']='0'*64
        with self.assertRaises(RuntimeError):audit.host.validate_capture_encoding_inventory(bad,{'test'},'della-host-')
        CHECKS+=1

    def test_lossless_capture_keeps_existing_png_validation_fail_closed(self):
        global CHECKS
        original,raw=self.lossless_fixture()
        for invalid in (original[:-1],original+b'junk',synthetic_png(raw,interlace=1),synthetic_png(raw,depth=16),
                        synthetic_png(raw[:-1]),synthetic_png(raw+b'junk')):
            with self.assertRaises(RuntimeError):audit.host.encode_capture_png(invalid,'synthetic-frame.png')
            CHECKS+=1
        blank=synthetic_filtered_scanlines(synthetic_pixel_rows(6,b'\0\0\0\xff'),4,[0,1,2,3,4])
        with self.assertRaises(RuntimeError):audit.host.encode_capture_png(synthetic_png(blank),'synthetic-frame.png')
        CHECKS+=1

    def owned_fixture(self):
        identifier='12345678-1234-1234-1234-123456789ABC'
        path='/Users/runner/Library/Developer/CoreSimulator/Devices/'+identifier+'/data/Containers/Bundle/Application/ABCDEFAB-1234-1234-1234-123456789ABC/KadeAI.app/KadeAI'
        data={'schema':'kade.della-host-owned-process.v1','pid':2468,'uid':501,'birthSeconds':1791700000,
              'birthMicroseconds':123456,'identifier':identifier,'bundleInstance':'ABCDEFAB-1234-1234-1234-123456789ABC',
              'bundleId':audit.host.BUNDLE_ID,'executable':'KadeAI','executablePathSha256':hashlib.sha256(path.encode()).hexdigest(),
              'infoPlistSha256':'b'*64,'executableSha256':'a'*64,
              'launchStartedAtUtc':datetime.fromtimestamp(1791700000,timezone.utc).isoformat(),
              'launchFinishedAtUtc':datetime.fromtimestamp(1791700000.5,timezone.utc).isoformat(),
              'capturedAtUtc':datetime.fromtimestamp(1791700001,timezone.utc).isoformat()}
        compiled={'artifacts':{'app':{'infoPlistSha256':'b'*64,'executableSha256':'a'*64}}}
        kernel={key:data[key] for key in ('pid','uid','birthSeconds','birthMicroseconds')};kernel['path']=path
        return data,compiled,kernel

    def test_owned_pid_parser_and_exact_native_identity(self):
        global CHECKS
        host=audit.host;owned,compiled,kernel=self.owned_fixture()
        self.assertEqual((ctypes.sizeof(host.DarwinBSDInfo),host.DarwinBSDInfo.birthSeconds.offset,
                          host.DarwinBSDInfo.birthMicroseconds.offset),(136,120,128));CHECKS+=1
        self.assertEqual(host.launch_pid(host.BUNDLE_ID+': 2468'),2468);CHECKS+=1
        for output in (None,True,host.BUNDLE_ID+': 0',host.BUNDLE_ID+': 1',host.BUNDLE_ID+': -2',host.BUNDLE_ID+': +2',
                       host.BUNDLE_ID+': 2147483648',host.BUNDLE_ID+': 0002',host.BUNDLE_ID+': 2468\nother',
                       'other.bundle: 2468',host.BUNDLE_ID+': 2468 42'):
            with self.assertRaises(RuntimeError):host.launch_pid(output)
            CHECKS+=1
        self.assertIs(host.validate_owned_process(owned,owned['identifier'],compiled),owned);CHECKS+=1
        for key,value in [('pid',True),('pid',2468.0),('uid',True),('uid',-1),('birthSeconds',True),('birthMicroseconds',10**6),
                          ('identifier','wrong'),('bundleId','other'),('executable','KadeKeyboard'),('bundleInstance','private path'),
                          ('executableSha256','c'*64),('infoPlistSha256','c'*64),('executablePathSha256','raw private path'),
                          ('launchStartedAtUtc',owned['capturedAtUtc']),('launchFinishedAtUtc',owned['launchStartedAtUtc']),
                          ('capturedAtUtc',owned['launchStartedAtUtc'])]:
            changed=copy.deepcopy(owned);changed[key]=value
            with self.assertRaises(RuntimeError):host.validate_owned_process(changed,owned['identifier'],compiled)
            CHECKS+=1
        changed=dict(owned,private='not permitted')
        with self.assertRaises(RuntimeError):host.validate_owned_process(changed,owned['identifier'],compiled)
        CHECKS+=1

    def test_native_path_exit_race_and_other_errors(self):
        global CHECKS
        host=audit.host;owned,compiled,kernel=self.owned_fixture()
        class NativeFunction:
            def __init__(self,action):self.action=action
            def __call__(self,*args):return self.action(*args)
        for result,number in [(0,errno.ESRCH),(0,errno.EPERM),(0,errno.ENOENT),(3,0)]:
            def info(pid,kind,unused,buffer,size):
                target=ctypes.cast(buffer,ctypes.POINTER(host.DarwinBSDInfo)).contents
                target.pid=pid;target.uid=501;target.birthSeconds=owned['birthSeconds'];target.birthMicroseconds=123456
                return size
            def path(pid,buffer,size):
                ctypes.set_errno(number)
                if result:buffer.value=b'/wrong-length'
                return result
            library=type('MemoryLibrary',(),{})();library.proc_pidinfo=NativeFunction(info);library.proc_pidpath=NativeFunction(path)
            with patch.object(host.sys,'platform','darwin'),patch.object(host.ctypes,'CDLL',return_value=library):
                if number==errno.ESRCH:self.assertIsNone(NATIVE_SNAPSHOT(owned['pid']))
                else:
                    with self.assertRaises(RuntimeError):NATIVE_SNAPSHOT(owned['pid'])
            CHECKS+=1

    def test_post_signal_bsd_is_zombie_aware_and_never_reads_a_path(self):
        global CHECKS
        host=audit.host;owned,_,_=self.owned_fixture()
        class NativeFunction:
            def __init__(self,action):self.action=action
            def __call__(self,*args):return self.action(*args)
        for count,number in [(136,0),(0,errno.ESRCH),(0,errno.EPERM),(0,errno.ENOENT),(0,0),(134,0)]:
            def info(pid,kind,include_zombies,buffer,size):
                self.assertEqual((kind,include_zombies,size),(3,1,136))
                target=ctypes.cast(buffer,ctypes.POINTER(host.DarwinBSDInfo)).contents
                target.pid=pid;target.uid=501;target.birthSeconds=owned['birthSeconds'];target.birthMicroseconds=123456
                ctypes.set_errno(number);return count
            # No proc_pidpath symbol is provided; any post-signal path access fails this canary.
            library=type('MemoryBSDLibrary',(),{})();library.proc_pidinfo=NativeFunction(info)
            with patch.object(host.sys,'platform','darwin'),patch.object(host.ctypes,'CDLL',return_value=library):
                if count==136:self.assertEqual(NATIVE_BIRTH(owned['pid']),{key:owned[key] for key in ('pid','uid','birthSeconds','birthMicroseconds')})
                elif number==errno.ESRCH:self.assertIsNone(NATIVE_BIRTH(owned['pid']))
                else:
                    with self.assertRaises(RuntimeError):NATIVE_BIRTH(owned['pid'])
            CHECKS+=1

    def diagnostic_native_library(self,owned,path,status=2,birth_delta=0,count=136,number=0):
        host=audit.host;calls=[]
        class NativeFunction:
            def __init__(self,action):self.action=action
            def __call__(self,*args):return self.action(*args)
        def info(pid,kind,zombies,buffer,size):
            calls.append(('bsd',pid,kind,zombies))
            target=ctypes.cast(buffer,ctypes.POINTER(host.DarwinBSDInfo)).contents
            target.pid=pid;target.uid=501;target.status=status
            target.birthSeconds=owned['birthSeconds'];target.birthMicroseconds=owned['birthMicroseconds']+birth_delta
            ctypes.set_errno(number);return count
        def executable(pid,buffer,size):
            calls.append(('path',pid))
            buffer.value=path.encode();return len(buffer.value)
        library=type('MemoryDiagnosticLibrary',(),{})()
        library.proc_pidinfo=NativeFunction(info);library.proc_pidpath=NativeFunction(executable)
        return library,calls

    def test_status_sidechannel_preserves_native_snapshot_and_birth_objects(self):
        global CHECKS
        host=audit.host;owned,_,kernel=self.owned_fixture()
        for status in (0,2,5,2**32-1):
            library,calls=self.diagnostic_native_library(owned,kernel['path'],status=status)
            sink={}
            with patch.object(host.sys,'platform','darwin'),patch.object(host.ctypes,'CDLL',return_value=library):
                plain=NATIVE_SNAPSHOT(owned['pid']);observed=NATIVE_SNAPSHOT(owned['pid'],status_sink=sink)
                birth=NATIVE_BIRTH(owned['pid'])
            self.assertEqual(plain,kernel);self.assertEqual(observed,plain)
            self.assertEqual(sink,{'status':status})
            self.assertEqual(birth,{key:owned[key] for key in ('pid','uid','birthSeconds','birthMicroseconds')})
            self.assertEqual(calls,[('bsd',2468,3,0),('path',2468),('bsd',2468,3,0),('path',2468),('bsd',2468,3,1)])
            self.assertNotIn('status',observed);CHECKS+=6
        for count,number in ((0,errno.ESRCH),(0,errno.EPERM),(134,0)):
            library,calls=self.diagnostic_native_library(owned,kernel['path'],count=count,number=number)
            sink={}
            with patch.object(host.sys,'platform','darwin'),patch.object(host.ctypes,'CDLL',return_value=library):
                if number==errno.ESRCH:self.assertIsNone(NATIVE_SNAPSHOT(owned['pid'],status_sink=sink))
                else:
                    with self.assertRaises(RuntimeError):NATIVE_SNAPSHOT(owned['pid'],status_sink=sink)
            self.assertEqual(sink,{})
            self.assertEqual(calls,[('bsd',2468,3,0)]);CHECKS+=3

    def test_offscope_revalidation_retains_metadata_before_the_unchanged_guard(self):
        global CHECKS
        host=audit.host;owned,compiled,kernel=self.owned_fixture()
        class MemoryBase:
            def __init__(self,value):self.value=str(value)
            def __str__(self):return self.value
            def __truediv__(self,value):return MemoryBase(self.value+'/'+value)
            @classmethod
            def home(cls):return cls('/Users/runner')
            # An off-scope snapshot must fail before alias/artifact operations.
            def resolve(self,*args,**kwargs):return forbidden()
            def open(self,*args,**kwargs):return forbidden()
        other_id='00000000-1234-1234-1234-123456789ABC'
        cases=((kernel['path'].replace('/KadeAI.app/KadeAI','/KadeAI.app/KadeAI.debug.dylib'),'sameSimulatorOtherPath',0),
               (kernel['path'].replace(owned['identifier'],other_id),'anotherSimulatorApp',0),
               (kernel['path'].replace(owned['identifier'],other_id.lower()),'anotherSimulatorApp',0),
               ('/private/var/memory/KadeAI.app/KadeAI','sameAppSuffixElsewhere',0),
               ('/usr/lib/dyld','otherAbsolutePath',0),
               ('/usr/lib/dyld','otherAbsolutePath',1),
               (kernel['path'].replace(owned['identifier'],owned['identifier'].lower()),'sameSimulatorOtherPath',0))
        for path,category,birth_delta in cases:
            library,calls=self.diagnostic_native_library(owned,path,birth_delta=birth_delta)
            record={};signals=[]
            with patch.object(host.sys,'platform','darwin'),patch.object(host.ctypes,'CDLL',return_value=library),\
                 patch.object(host,'Path',MemoryBase),patch.object(host.os,'getuid',return_value=501,create=True),\
                 patch.object(host,'native_process_snapshot',side_effect=NATIVE_SNAPSHOT),\
                 patch.object(host,'owned_process_identity',side_effect=OWNED_IDENTITY),\
                 patch.object(host.os,'kill',side_effect=lambda *args:signals.append(args)),\
                 patch.object(host.time,'monotonic',return_value=0),patch.object(host,'now',return_value=owned['capturedAtUtc']):
                with self.assertRaisesRegex(RuntimeError,'outside the exact simulator installed app'):
                    host.terminate_owned_process(owned,owned['identifier'],compiled,100,record)
            diagnostic=record['revalidationDiagnostic']
            self.assertEqual(diagnostic['pathCategory'],category)
            self.assertFalse(diagnostic['exactSimulatorAppScope'])
            self.assertEqual(diagnostic['executablePathSha256'],hashlib.sha256(path.encode()).hexdigest())
            self.assertEqual(diagnostic['matchesOriginal'],{'pid':True,'uid':True,'birth':birth_delta==0,'path':False})
            self.assertEqual((diagnostic['status'],diagnostic['birthMicroseconds']),(2,123456+birth_delta))
            self.assertEqual(signals,[])
            self.assertEqual(calls,[('bsd',2468,3,0),('path',2468)])
            self.assertFalse(record['passed'] or record['identityVerified'] or record['signalSubmitted'] or record['observedExit'])
            self.assertEqual(record['pollCount'],0)
            self.assertIs(host.validate_owned_termination(record,owned),record)
            encoded=json.dumps(record)
            self.assertNotIn(path,encoded);self.assertNotIn('/Users/runner',encoded)
            CHECKS+=12
        # A vanished or incomplete kernel observation cannot fabricate metadata.
        for count,number in ((0,errno.ESRCH),(134,0)):
            library,calls=self.diagnostic_native_library(owned,kernel['path'],count=count,number=number)
            record={};signals=[]
            with patch.object(host.sys,'platform','darwin'),patch.object(host.ctypes,'CDLL',return_value=library),\
                 patch.object(host,'native_process_snapshot',side_effect=NATIVE_SNAPSHOT),\
                 patch.object(host,'owned_process_identity',side_effect=OWNED_IDENTITY),\
                 patch.object(host.os,'kill',side_effect=lambda *args:signals.append(args)),\
                 patch.object(host.time,'monotonic',return_value=0),patch.object(host,'now',return_value=owned['capturedAtUtc']):
                with self.assertRaises(RuntimeError):host.terminate_owned_process(owned,owned['identifier'],compiled,100,record)
            self.assertNotIn('revalidationDiagnostic',record)
            self.assertEqual(signals,[]);self.assertEqual(calls,[('bsd',2468,3,0)])
            self.assertIs(host.validate_owned_termination(record,owned),record);CHECKS+=5

    def test_revalidation_diagnostic_is_typed_consistent_and_never_exit_proof(self):
        global CHECKS
        host=audit.host;owned,_,kernel=self.owned_fixture()
        base=kernel['path'].rsplit('/',3)[0]
        data=host.owned_revalidation_diagnostic(kernel,2,base,owned['identifier'],True,owned)
        self.assertEqual(data['pathCategory'],'expectedSimulatorApp')
        self.assertTrue(data['exactSimulatorAppScope'] and all(data['matchesOriginal'].values()))
        self.assertIs(host.validate_owned_revalidation_diagnostic(data,owned),data);CHECKS+=3
        bad=(('schema','wrong'),('pid',True),('pid',2469),('uid',True),('uid',-1),('uid',2**32),
             ('birthSeconds',True),('birthSeconds',0),('birthSeconds',10**11),
             ('birthMicroseconds',True),('birthMicroseconds',-1),('birthMicroseconds',10**6),
             ('status',True),('status',-1),('status',2**32),('status',2.0),
             ('executablePathSha256','raw private path'),('exactSimulatorAppScope',1),
             ('pathCategory','unreviewed category'),('pathCategory',True),('pathCategory',None),
             ('pathCategory','otherAbsolutePath'),('matchesOriginal',None),
             ('matchesOriginal',{'pid':True,'uid':True,'birth':True,'path':1}),
             ('matchesOriginal',{'pid':True,'uid':True,'birth':True,'path':False}))
        for key,value in bad:
            changed=copy.deepcopy(data);changed[key]=value
            with self.assertRaises(RuntimeError):host.validate_owned_revalidation_diagnostic(changed,owned)
            CHECKS+=1
        for changed in (None,{},dict(data,rawPath=kernel['path']),dict(data,extra=True)):
            with self.assertRaises(RuntimeError):host.validate_owned_revalidation_diagnostic(changed,owned)
            CHECKS+=1
        changed=copy.deepcopy(data);changed['uid']=502;changed['matchesOriginal']['uid']=False
        self.assertIs(host.validate_owned_revalidation_diagnostic(changed,owned),changed);CHECKS+=1
        stopped={'schema':'kade.della-host-owned-exit.v1','pid':owned['pid'],'identitySha256':host.owned_identity_digest(owned),
                 'timeoutSeconds':30,'signal':'SIGTERM','signalSubmitted':False,'identityVerified':False,
                 'observedExit':False,'passed':False,'timedOut':False,'exitCode':None,'pollCount':0,
                 'startedAtUtc':owned['capturedAtUtc'],'finishedAtUtc':owned['capturedAtUtc'],'elapsedSeconds':0}
        self.assertIs(host.validate_owned_termination(stopped,owned),stopped);CHECKS+=1
        stopped['revalidationDiagnostic']=data
        self.assertIs(host.validate_owned_termination(stopped,owned),stopped)
        self.assertFalse(stopped['passed'] or stopped['identityVerified'] or stopped['signalSubmitted'] or stopped['observedExit']);CHECKS+=2
        for key,value in (('passed',True),('signalSubmitted',True),('observedExit',True),('revalidationDiagnostic',None)):
            changed=copy.deepcopy(stopped);changed[key]=value
            with self.assertRaises(RuntimeError):host.validate_owned_termination(changed,owned)
            CHECKS+=1
        changed=copy.deepcopy(stopped);changed.update(identityVerified=True,signalSubmitted=True,observedExit=True,passed=True,pollCount=1)
        changed['revalidationDiagnostic']['pathCategory']='otherAbsolutePath'
        changed['revalidationDiagnostic']['exactSimulatorAppScope']=False
        with self.assertRaises(RuntimeError):host.validate_owned_termination(changed,owned)
        CHECKS+=1

    def test_expected_scope_diagnostic_keeps_owned_record_and_single_real_signal_contract(self):
        global CHECKS
        host=audit.host;owned,_,kernel=self.owned_fixture()
        binary=b'synthetic unchanged compiled app, never native proof'
        plist_bytes=host.plistlib.dumps({'CFBundleIdentifier':host.BUNDLE_ID,'CFBundleExecutable':'KadeAI'})
        files={kernel['path']:binary,kernel['path'].rsplit('/',1)[0]+'/Info.plist':plist_bytes}
        owned['executableSha256']=hashlib.sha256(binary).hexdigest()
        owned['infoPlistSha256']=hashlib.sha256(plist_bytes).hexdigest()
        compiled={'artifacts':{'app':{key:owned[key] for key in ('infoPlistSha256','executableSha256')}}}
        reads=[]
        class MemoryPath:
            def __init__(self,value):self.value=str(value)
            def __str__(self):return self.value
            def __eq__(self,other):return isinstance(other,MemoryPath) and self.value==other.value
            def __truediv__(self,value):return MemoryPath(self.value+'/'+value)
            @classmethod
            def home(cls):return cls('/Users/runner')
            @property
            def parent(self):return MemoryPath(self.value.rsplit('/',1)[0])
            def resolve(self,strict=False):return self
            def is_symlink(self):return False
            def is_file(self):return self.value in files
            def stat(self):return type('MemoryStat',(),{'st_size':len(files[self.value])})()
            def open(self,mode):reads.append(self.value);return BytesIO(files[self.value])
        library,calls=self.diagnostic_native_library(owned,kernel['path'])
        original_info=library.proc_pidinfo.action
        def changing_status(*args):
            result=original_info(*args)
            target=ctypes.cast(args[3],ctypes.POINTER(host.DarwinBSDInfo)).contents
            target.status=2 if len([call for call in calls if call[0]=='bsd'])==1 else 5
            return result
        library.proc_pidinfo.action=changing_status
        signals=[]
        def kill(pid,signum):
            if signum==host.signal.SIGTERM:signals.append((pid,signum))
            else:
                self.assertEqual((pid,signum),(2468,0))
                raise ProcessLookupError(errno.ESRCH,'synthetic observed absence')
        with patch.object(host.sys,'platform','darwin'),patch.object(host.ctypes,'CDLL',return_value=library),\
             patch.object(host,'Path',MemoryPath),patch.object(host.os,'getuid',return_value=501,create=True),\
             patch.object(host,'native_process_snapshot',side_effect=NATIVE_SNAPSHOT),\
             patch.object(host,'owned_process_identity',side_effect=OWNED_IDENTITY),\
             patch.object(host.os,'kill',side_effect=kill),patch.object(host.time,'monotonic',return_value=0),\
             patch.object(host,'now',return_value=owned['capturedAtUtc']):
            plain=OWNED_IDENTITY(owned['pid'],owned['identifier'],compiled,100,
                                 owned['launchStartedAtUtc'],owned['launchFinishedAtUtc'])
            calls.clear();reads.clear();diagnostic_record={}
            observed=OWNED_IDENTITY(owned['pid'],owned['identifier'],compiled,100,
                                    owned['launchStartedAtUtc'],owned['launchFinishedAtUtc'],
                                    revalidation_record=diagnostic_record,original_owned=owned)
            self.assertEqual(observed,plain);self.assertEqual(observed,owned)
            self.assertNotIn('revalidationDiagnostic',observed);self.assertNotIn('status',observed)
            self.assertEqual(len(calls),4);self.assertEqual(len(reads),2)
            self.assertEqual(diagnostic_record['revalidationDiagnostic']['status'],2)
            self.assertEqual(diagnostic_record['revalidationDiagnostic']['pathCategory'],'expectedSimulatorApp')
            CHECKS+=8
            calls.clear();reads.clear();record={}
            host.terminate_owned_process(owned,owned['identifier'],compiled,100,record)
        self.assertEqual(signals,[(2468,host.signal.SIGTERM)])
        self.assertEqual(calls,[('bsd',2468,3,0),('path',2468)]*3)
        self.assertEqual(len(reads),2)
        self.assertTrue(record['passed'] and record['identityVerified'] and record['signalSubmitted'] and record['observedExit'])
        self.assertEqual(record['pollCount'],1);self.assertIsNone(record['exitCode'])
        self.assertEqual(record['revalidationDiagnostic']['status'],2)
        self.assertTrue(record['revalidationDiagnostic']['exactSimulatorAppScope'])
        self.assertTrue(all(record['revalidationDiagnostic']['matchesOriginal'].values()))
        self.assertIs(host.validate_owned_termination(record,owned),record);CHECKS+=10

    def test_owned_installed_bundle_hashes_aliases_uid_and_birth(self):
        global CHECKS
        host=audit.host;owned,_,kernel=self.owned_fixture()
        for scenario in ('valid','uid','pid','device','otherExecutable','alias','plistIdentity','binaryHash','plistHash','birthChanged','oldBirth','oversized'):
            plist_bytes=host.plistlib.dumps({'CFBundleIdentifier':host.BUNDLE_ID,'CFBundleExecutable':'KadeAI'})
            binary=b'synthetic compiled executable bytes, never native proof'
            files={kernel['path']:binary,kernel['path'].rsplit('/',1)[0]+'/Info.plist':plist_bytes}
            compiled={'artifacts':{'app':{'infoPlistSha256':hashlib.sha256(plist_bytes).hexdigest(),
                                        'executableSha256':hashlib.sha256(binary).hexdigest()}}}
            if scenario=='plistIdentity':files[kernel['path'].rsplit('/',1)[0]+'/Info.plist']=host.plistlib.dumps({'CFBundleIdentifier':'other','CFBundleExecutable':'KadeAI'})
            if scenario=='binaryHash':compiled['artifacts']['app']['executableSha256']='a'*64
            if scenario=='plistHash':compiled['artifacts']['app']['infoPlistSha256']='a'*64
            class MemoryPath:
                def __init__(self,value):self.value=str(value)
                def __str__(self):return self.value
                def __eq__(self,other):return isinstance(other,MemoryPath) and self.value==other.value
                def __truediv__(self,value):return MemoryPath(self.value+'/'+value)
                @classmethod
                def home(cls):return cls('/Users/runner')
                @property
                def parent(self):return MemoryPath(self.value.rsplit('/',1)[0])
                def resolve(self,strict=False):return MemoryPath('/alias') if scenario=='alias' else self
                def is_symlink(self):return scenario=='alias'
                def is_file(self):return self.value in files
                def stat(self):return type('MemoryStat',(),{'st_size':300*1024*1024 if scenario=='oversized' else len(files[self.value])})()
                def open(self,mode):return BytesIO(files[self.value])
            first=copy.deepcopy(kernel);second=copy.deepcopy(kernel)
            if scenario=='uid':first['uid']=502
            if scenario=='pid':first['pid']=2469
            if scenario=='device':first['path']=first['path'].replace(owned['identifier'],'00000000-1234-1234-1234-123456789ABC')
            if scenario=='otherExecutable':first['path']=first['path'].replace('/KadeAI.app/KadeAI','/Other.app/Other')
            if scenario=='birthChanged':second['birthMicroseconds']+=1
            launch=owned['capturedAtUtc'] if scenario=='oldBirth' else owned['launchStartedAtUtc']
            with patch.object(host,'Path',MemoryPath),patch.object(host.os,'getuid',return_value=501,create=True),\
                 patch.object(host,'native_process_snapshot',side_effect=[first,second]),patch.object(host.time,'monotonic',return_value=0),\
                 patch.object(host,'now',return_value=owned['capturedAtUtc']):
                if scenario=='valid':
                    result=OWNED_IDENTITY(owned['pid'],owned['identifier'],compiled,1,launch,owned['launchFinishedAtUtc'])
                    self.assertEqual(result['executableSha256'],compiled['artifacts']['app']['executableSha256']);CHECKS+=1
                else:
                    with self.assertRaises(RuntimeError):OWNED_IDENTITY(owned['pid'],owned['identifier'],compiled,1,launch,owned['launchFinishedAtUtc'])
                    CHECKS+=1

    def test_one_owned_signal_actual_absence_identity_reuse_and_deadlines(self):
        global CHECKS
        host=audit.host;owned,compiled,kernel=self.owned_fixture()
        scenarios=('exit','pathExitRace','bsdAbsentAlive','alive','shortDeadline','fifteenBoundAlive','freshUidChanged','freshBirthChanged','finalKernelChanged',
                   'signalPermission','signalAbsent','probePermission','pidReused','unknownPid')
        for scenario in scenarios:
            clock=[0.0];signals=[];probes=[0];snapshots=[0];record={}
            fresh=copy.deepcopy(owned)
            if scenario=='freshUidChanged':fresh['uid']=502
            if scenario=='freshBirthChanged':fresh['birthMicroseconds']+=1
            def kill(pid,signum):
                self.assertEqual(pid,2468)
                if signum==host.signal.SIGTERM:
                    signals.append((pid,signum))
                    if scenario=='signalPermission':raise PermissionError(errno.EPERM,'synthetic')
                    if scenario=='signalAbsent':raise ProcessLookupError(errno.ESRCH,'synthetic')
                else:
                    self.assertEqual(signum,0);probes[0]+=1
                    if scenario=='probePermission':raise PermissionError(errno.EPERM,'synthetic')
                    if scenario in ('exit','pathExitRace') and probes[0]>=3:raise ProcessLookupError(errno.ESRCH,'synthetic')
            def snapshot(pid):
                snapshots[0]+=1
                if scenario=='finalKernelChanged':return dict(kernel,birthMicroseconds=123457)
                if scenario=='pidReused' and probes[0]:return dict(kernel,birthMicroseconds=123457)
                if scenario in ('pathExitRace','bsdAbsentAlive') and probes[0]:return None
                return copy.deepcopy(kernel)
            def sleep(seconds):clock[0]+=seconds
            def now():return datetime.fromtimestamp(1791700002+clock[0],timezone.utc).isoformat()
            with patch.object(host,'owned_process_identity',return_value=fresh),patch.object(host,'native_process_snapshot',side_effect=snapshot),\
                 patch.object(host,'native_process_birth',side_effect=snapshot),\
                 patch.object(host.os,'kill',side_effect=kill),patch.object(host.time,'monotonic',side_effect=lambda:clock[0]),\
                 patch.object(host.time,'sleep',side_effect=sleep),patch.object(host,'now',side_effect=now):
                if scenario in ('exit','pathExitRace'):
                    host.terminate_owned_process(owned,owned['identifier'],compiled,100,record)
                    self.assertTrue(record['passed'] and record['observedExit']);CHECKS+=1
                else:
                    with self.assertRaises((RuntimeError,PermissionError,ProcessLookupError)):
                        host.terminate_owned_process(None if scenario=='unknownPid' else owned,owned['identifier'],compiled,
                                                     2 if scenario=='shortDeadline' else 100,record,bound=15 if scenario=='fifteenBoundAlive' else 30)
                    self.assertFalse(record['passed']);CHECKS+=1
            self.assertLessEqual(len(signals),1);self.assertIsNone(record['exitCode']);CHECKS+=2
            if scenario in ('unknownPid','freshUidChanged','freshBirthChanged','finalKernelChanged'):
                self.assertEqual(signals,[]);CHECKS+=1
            if scenario in ('alive','shortDeadline','bsdAbsentAlive','fifteenBoundAlive'):
                self.assertTrue(record['timedOut']);self.assertLessEqual(clock[0],15.000001 if scenario=='fifteenBoundAlive' else 30);CHECKS+=2
            self.assertIs(host.validate_owned_termination(record,None if scenario=='unknownPid' else owned),record);CHECKS+=1
        valid={'schema':'kade.della-host-owned-exit.v1','pid':owned['pid'],'identitySha256':host.owned_identity_digest(owned),
               'timeoutSeconds':30,'signal':'SIGTERM','signalSubmitted':True,'identityVerified':True,'observedExit':True,
               'passed':True,'timedOut':False,'exitCode':None,'pollCount':3,'startedAtUtc':owned['capturedAtUtc'],
               'finishedAtUtc':datetime.fromtimestamp(1791700003,timezone.utc).isoformat(),'elapsedSeconds':2}
        for key,value in [('pid',2468.0),('pid',True),('exitCode',0),('exitCode',-15),('signal','SIGKILL'),('signalSubmitted',False),
                          ('identityVerified',False),('observedExit',False),('timedOut',True),('timeoutSeconds',31),('elapsedSeconds',32),
                          ('pollCount',True),('identitySha256','c'*64),('error','password=not-real')]:
            changed=copy.deepcopy(valid);changed[key]=value
            with self.assertRaises(RuntimeError):host.validate_owned_termination(changed,owned)
            CHECKS+=1
        changed=copy.deepcopy(valid);changed['startedAtUtc']=owned['launchStartedAtUtc']
        with self.assertRaises(RuntimeError):host.validate_owned_termination(changed,owned)
        CHECKS+=1

    def test_compiled_after_is_attempted_and_clipped_even_when_owned_cleanup_fails(self):
        global CHECKS
        host=audit.host;owned,_,_=self.owned_fixture();initial={'sha':SOURCE}
        compiled={'schema':'kade.della-host-compiled-tests.v1','source':initial,'formatVersion':1,'unsignedSimulatorOnly':True,
                  'testTarget':'KadeAIUITests','xctestrun':'build/della-host-layout-simulator/Build/Products/KadeAIA11yAudit_memory.xctestrun',
                  'xctestrunSha256':'c'*64,'artifacts':{}}
        for role,leaf,identifier in [('app','Debug-iphonesimulator/KadeAI.app',host.BUNDLE_ID),
            ('runner','Debug-iphonesimulator/KadeAIUITests-Runner.app','com.kademurdock.kadeai.uitests.xctrunner'),
            ('testBundle','Debug-iphonesimulator/KadeAIUITests-Runner.app/PlugIns/KadeAIUITests.xctest','com.kademurdock.kadeai.uitests')]:
            compiled['artifacts'][role]={'path':'build/della-host-layout-simulator/Build/Products/'+leaf,'bundleId':identifier,
                                        'infoPlistSha256':'b'*64,'executableSha256':'a'*64}
        for scenario in ('cleanupFailure','cleanupAndRehashFailure','cleanupAndChangedRunner'):
            clock=[0.0];ready=[False];observations=[];report={}
            class MemoryPath:
                def __init__(self,value):self.value=str(value)
                def __str__(self):return self.value
                def __truediv__(self,value):return MemoryPath(self.value+'/'+value)
                def mkdir(self,**kwargs):pass
                def unlink(self,**kwargs):ready[0]=False
                def exists(self):return ready[0]
                def is_file(self):return self.value.endswith('compiled-tests.json') or ready[0]
                def stat(self):return type('MemoryStat',(),{'st_size':len(json.dumps(compiled)) if self.value.endswith('compiled-tests.json') else 2})()
                def read_text(self):return json.dumps(compiled)
                def read_bytes(self):return b'{}'
            def now():return datetime.fromtimestamp(1791700000+clock[0],timezone.utc).isoformat()
            def command(*args,timeout,deadline,record,env=None):
                record.update(operation=args[0],timeoutSeconds=timeout,passed=True)
                if args[0]=='get_app_container':return '/memory/CoreSimulator/Devices/'+owned['identifier']+'/data/Containers/Data/Application/ABCDEFAB-1234-1234-1234-123456789ABC'
                if args[0]=='launch':ready[0]=True;return host.BUNDLE_ID+': 2468'
                return ''
            def identity(*args):
                result=copy.deepcopy(owned);result.update(birthMicroseconds=0,launchStartedAtUtc=args[-2],launchFinishedAtUtc=args[-1],capturedAtUtc=now())
                return result
            def terminate(identity,identifier,artifact,deadline,record):
                clock[0]+=30;record.update(passed=False)
                raise RuntimeError('Synthetic owned exit did not occur')
            def artifacts(expected,emit_inventory=False):
                observations.append(host._OPERATION_DEADLINE)
                self.assertFalse(emit_inventory)
                self.assertLessEqual(host._OPERATION_DEADLINE,1000+100)
                if len(observations)==2 and scenario=='cleanupAndRehashFailure':raise RuntimeError('Synthetic hash read failed')
                result=copy.deepcopy(compiled)
                if len(observations)==2 and scenario=='cleanupAndChangedRunner':result['artifacts']['runner']['executableSha256']='d'*64
                return result
            with patch.object(host,'Path',MemoryPath),patch.object(host,'OUT',MemoryPath('/memory/receipts')),\
                 patch.object(host,'preflight_sim',side_effect=command),patch.object(host,'owned_process_identity',side_effect=identity),\
                 patch.object(host,'terminate_owned_process',side_effect=terminate),patch.object(host,'compiled_tests',side_effect=artifacts),\
                 patch.object(host,'validate_ready',return_value={}),patch.object(host,'now',side_effect=now),\
                 patch.object(host.time,'monotonic',side_effect=lambda:clock[0]),patch.object(host.time,'time',side_effect=lambda:1000+clock[0]),\
                 patch.object(host,'_OPERATION_DEADLINE',2000):
                with self.assertRaises(RuntimeError):host.app_preflight(SOURCE,owned['identifier'],initial,{},100,report)
                self.assertEqual(host._OPERATION_DEADLINE,2000);CHECKS+=1
            self.assertEqual(observations,[1070,1100]);CHECKS+=1
            self.assertFalse(report['passed'] or report['terminated']);CHECKS+=1
            self.assertEqual(report['compiledAfterVerified'],scenario=='cleanupFailure');CHECKS+=1
            self.assertIn('compiledAfter',report['operationSeconds']);CHECKS+=1
            if scenario!='cleanupFailure':self.assertIn('compiledAfterErrorType',report);CHECKS+=1

    def test_capture_owned_v2_all_phases_and_original_fifteen_second_bound(self):
        global CHECKS
        host=audit.host;owned,_,_=self.owned_fixture();initial={'sha':SOURCE}
        compiled={'schema':'kade.della-host-compiled-tests.v1','source':initial,'formatVersion':1,'unsignedSimulatorOnly':True,
                  'testTarget':'KadeAIUITests','xctestrun':'build/della-host-layout-simulator/Build/Products/KadeAIA11yAudit_memory.xctestrun',
                  'xctestrunSha256':'c'*64,'artifacts':{}}
        for role,leaf,identifier in [('app','Debug-iphonesimulator/KadeAI.app',host.BUNDLE_ID),
            ('runner','Debug-iphonesimulator/KadeAIUITests-Runner.app','com.kademurdock.kadeai.uitests.xctrunner'),
            ('testBundle','Debug-iphonesimulator/KadeAIUITests-Runner.app/PlugIns/KadeAIUITests.xctest','com.kademurdock.kadeai.uitests')]:
            compiled['artifacts'][role]={'path':'build/della-host-layout-simulator/Build/Products/'+leaf,'bundleId':identifier,
                                        'infoPlistSha256':'b'*64,'executableSha256':'a'*64}
        def termination(identity,bound=30):
            return {'schema':'kade.della-host-owned-exit.v1','pid':identity['pid'],'identitySha256':host.owned_identity_digest(identity),
                    'timeoutSeconds':bound,'signal':'SIGTERM','signalSubmitted':True,'identityVerified':True,'observedExit':True,
                    'passed':True,'timedOut':False,'exitCode':None,'pollCount':1,'startedAtUtc':identity['capturedAtUtc'],
                    'finishedAtUtc':datetime.fromtimestamp(datetime.fromisoformat(identity['capturedAtUtc']).timestamp()+1,timezone.utc).isoformat(),
                    'elapsedSeconds':1}
        legacy={'schema':'kade.della-host-capture.v2','source':initial,'passed':True,'compiledAfterVerified':True,'compiledRunner':compiled,
                'ownedProcesses':{},'ownedTerminations':{},'captureTimings':{},
                'simulators':{key:{'identifier':owned['identifier']} for key in ('large','small')}}
        for index,phase in enumerate(host.PHASES):
            identity=copy.deepcopy(owned);identity['pid']+=index;identity['birthSeconds']+=index
            for field in ('launchStartedAtUtc','launchFinishedAtUtc','capturedAtUtc'):
                identity[field]=datetime.fromtimestamp(datetime.fromisoformat(identity[field]).timestamp()+index,timezone.utc).isoformat()
            legacy['ownedProcesses'][phase]=identity;legacy['ownedTerminations'][phase]=termination(identity)
            legacy['captureTimings'][phase]={'startedAtUtc':identity['launchStartedAtUtc']}
        self.assertIs(host.validate_capture_ownership(legacy),legacy);CHECKS+=1
        phase=host.PHASES[0]
        mutations=[lambda value:value.update(schema='old'),lambda value:value.update(compiledAfterVerified=False),
                   lambda value:value['ownedProcesses'].pop(phase),lambda value:value['ownedTerminations'].pop(phase),
                   lambda value:value['ownedTerminations'][phase].update(passed=False),
                   lambda value:value['ownedTerminations'][phase].update(exitCode=0),
                   lambda value:value['ownedProcesses'][phase].update(uid=True)]
        for mutate in mutations:
            changed=copy.deepcopy(legacy);mutate(changed)
            with self.assertRaises(RuntimeError):host.validate_capture_ownership(changed)
            CHECKS+=1
        duplicate=copy.deepcopy(legacy);duplicate['ownedProcesses'][host.PHASES[1]]=copy.deepcopy(duplicate['ownedProcesses'][phase])
        duplicate['ownedTerminations'][host.PHASES[1]]=termination(duplicate['ownedProcesses'][phase])
        duplicate['captureTimings'][host.PHASES[1]]={'startedAtUtc':owned['launchStartedAtUtc']}
        with self.assertRaises(RuntimeError):host.validate_capture_ownership(duplicate)
        CHECKS+=1
        completion={'schema':'kade.puppet-completion-capture.v2','source':initial,'passed':True,'compiledAfterVerified':True,
                    'compiledRunner':compiled,'device':{'identifier':owned['identifier']},'ownedProcess':owned,
                    'ownedTermination':termination(owned,15),'terminationVerified':True,'elapsedSeconds':299,
                    'startedAtUtc':owned['launchStartedAtUtc'],'finishedAtUtc':termination(owned,15)['finishedAtUtc']}
        self.assertIs(audit.validate_capture_ownership(completion),completion);CHECKS+=1
        for key,value in [('schema','old'),('compiledAfterVerified',False),('ownedProcess',None),('ownedTermination',None),
                          ('terminationVerified',False),('elapsedSeconds',301.001)]:
            changed=copy.deepcopy(completion);changed[key]=value
            with self.assertRaises(RuntimeError):audit.validate_capture_ownership(changed)
            CHECKS+=1
        changed=copy.deepcopy(completion);changed['ownedTermination']['timeoutSeconds']=15.001
        with self.assertRaises(RuntimeError):audit.validate_capture_ownership(changed)
        CHECKS+=1
        for key,value in [('startedAtUtc',owned['capturedAtUtc']),('finishedAtUtc',owned['capturedAtUtc'])]:
            changed=copy.deepcopy(completion);changed[key]=value
            with self.assertRaises(RuntimeError):audit.validate_capture_ownership(changed)
            CHECKS+=1
    def test_distinct_boot_order_and_unchanged_proof_budgets(self):
        global CHECKS
        regression={"finishedAtUtc":"2026-10-11T05:00:00+00:00"}
        boot={"startedAtUtc":"2026-10-11T05:00:01+00:00","finishedAtUtc":"2026-10-11T05:00:02+00:00"}
        launch={"startedAtUtc":"2026-10-11T05:00:03+00:00"}
        CHECKS += 1
        audit.require_boot_order(regression,boot,launch)
        for owner,key,value in ((regression,"finishedAtUtc",boot["startedAtUtc"]),
                                (boot,"startedAtUtc",regression["finishedAtUtc"]),
                                (boot,"finishedAtUtc",boot["startedAtUtc"]),
                                (launch,"startedAtUtc",boot["finishedAtUtc"]),
                                (launch,"startedAtUtc","2026-10-11T04:59:59+00:00"),
                                (launch,"startedAtUtc","2026-10-11T05:00:03")):
            old=owner[key];owner[key]=value
            CHECKS += 1
            with self.assertRaises(RuntimeError):audit.require_boot_order(regression,boot,launch)
            owner[key]=old
        for actual,expected in ((audit.host.BOOT_SECONDS,600),(audit.host.UI_SECONDS["large"],900),
                                (audit.host.UI_SECONDS["small"],720),(audit.host.OPERATION_SECONDS,4920),
                                (audit.host.JOB_SECONDS,5400),(audit.CAPTURE_SECONDS,300),(audit.MAX_FILES,25),
                                (len(audit.PHASES),21),(len(audit.EVENTS),28),(len(audit.UI_METHODS),3)):
            CHECKS += 1
            self.assertEqual(actual,expected)

    def accepted(self, data):
        global CHECKS
        CHECKS += 1
        self.assertIs(audit.validate_ready(data, data["phase"], SOURCE), data)

    def rejected(self, data, phase=None, source=SOURCE):
        global CHECKS
        CHECKS += 1
        with self.assertRaises(RuntimeError):
            audit.validate_ready(data, phase or data["phase"], source)

    def mutate(self, person, pose, path, value):
        data = fixture(person, pose)
        target = data
        for part in path[:-1]:
            target = target[part]
        target[path[-1]] = value
        self.rejected(data)

    def test_all_cast_three_native_contracts_synthetic(self):
        self.assertEqual(PEOPLE, audit.PEOPLE)
        self.assertEqual(POSES, audit.POSES)
        for person in PEOPLE:
            for pose in POSES:
                with self.subTest(person=person, pose=pose):
                    self.accepted(fixture(person, pose))
        self.assertEqual(len(audit.COMMON | audit.JOINTS), 32)
        self.assertEqual(REST, audit.REGISTRATION)

    def test_actual_swift_registration_matches_native_validator(self):
        global CHECKS
        path = ROOT / "Sources/CharacterConversationBodyGeometry.swift"
        self.assertLessEqual(path.stat().st_size, 64 * 1024)
        source = path.read_text(encoding="utf-8")
        CHECKS += 1
        registration_coherent(source, audit.REGISTRATION)
        self.assertEqual(swift_registrations(source), REST)
        # A matching but stale validator/fixture pair must still fail against
        # the real renderer, including the historical Kiana shoulder mistake.
        stale = copy.deepcopy(audit.REGISTRATION)
        stale["kiana"] = ((.13, .94), (.13, 1.14), (.27, 1.30), (.87, .94), (.87, 1.14), (.73, 1.30))
        CHECKS += 1
        with self.assertRaises(ValueError):
            registration_coherent(source, stale)
        for bad in (
            source.replace("case .lilly:", "case .unknown:", 1),
            source.replace("case .kiana:", "case .kiana:\n        case .kiana:", 1),
            source.replace("leftShoulder: .init(x: 0.12, y: 0.84)", "unknownShoulder: .init(x: 0.12, y: 0.84)", 1),
            source.replace("leftShoulder: .init(x: 0.12, y: 0.84)",
                           "leftShoulder: .init(x: 0.12, y: 0.84), leftShoulder: .init(x: 0.12, y: 0.84)", 1),
            source.replace("leftShoulder: .init(x: 0.12, y: 0.84)", "leftShoulder: .init(x: .nan, y: 0.84)", 1),
        ):
            CHECKS += 1
            with self.assertRaises(ValueError):
                registration_coherent(bad, audit.REGISTRATION)

    def test_source_identity_art_and_phase_binding(self):
        for person in PEOPLE:
            for pose in POSES:
                data = fixture(person, pose)
                other = PEOPLE[(PEOPLE.index(person) + 1) % len(PEOPLE)]
                with self.subTest(person=person, pose=pose):
                    for path, value in (
                        (("source",), "b" * 40), (("schema",), "kade.puppet-completion-ready.v2"),
                        (("character",), other), (("avatarPath",), "/images/" + audit.IDS[other][1]),
                        (("render", "agentID"), audit.IDS[other][0]),
                        (("render", "renderer"), "unregistered-rig"), (("render", "assets"), ["CharacterOtherFace"]),
                    ):
                        self.mutate(person, pose, path, value)
                    self.rejected(data, phase=other + "-" + pose)
                    self.rejected(data, source="c" * 40)
        data = fixture("harley", "neutral")
        data["phase"] = "harley-unknown"
        self.rejected(data)

    def test_unknown_fields_and_strict_numeric_types(self):
        for section in (None, "geometry", "render", "samples"):
            data = fixture("harley", "gesturePeak")
            (data if section is None else data[section])["inventedProof"] = True
            self.rejected(data)
        for person in PEOPLE:
            data = fixture(person, "gesturePeak")
            data["render"]["values"]["inventedJoint"] = .2
            self.rejected(data)
            for bad in (True, False, "0", None, math.nan, math.inf, -math.inf):
                for field in tuple(fixture(person, "gesturePeak")["render"]["values"]):
                    with self.subTest(person=person, field=field, bad=repr(bad)):
                        self.mutate(person, "gesturePeak", ("render", "values", field), bad)
        for path in (("completedInputs",), ("blockedRequestCount",), ("render", "side"),
                     ("render", "face"), ("render", "viseme"), ("render", "framesPerSecond"),
                     ("samples", "count"), ("samples", "active"), ("samples", "paused"),
                     ("samples", "distinctTimes"), ("samples", "distinctVectors")):
            self.mutate("harley", "gesturePeak", path, True)

    def test_rectangles_shape_framing_and_parent_relationship(self):
        for bad in ([0, 0, 440], [0, 0, 440, 956, 1], [False, 0, 440, 956],
                    [0, 0, math.nan, 956], [0, 0, math.inf, 956], [0, 0, -1, 956]):
            self.mutate("harley", "gesturePeak", ("geometry", "window"), bad)
        for path, value in (
            (("windowPoints",), [430, 932]), (("appearance",), "dark"),
            (("render", "side"), 160), (("render", "height"), 208),
            (("geometry", "portrait"), [96, 200, 249.1, 351.4975845410628]),
            (("geometry", "portrait"), [96, 200, 248, 400]),
            (("geometry", "portrait"), [435, 200, 248, 351.4975845410628]),
            (("geometry", "stage"), [0, 0, 1, 1]),
        ):
            self.mutate("harley", "gesturePeak", path, value)
        data = fixture("harley", "gesturePeak")
        data["geometry"]["stage"][0] += 80
        self.rejected(data)

    def test_clock_counts_policy_and_no_external_claim_inflation(self):
        for person in PEOPLE:
            for pose in POSES:
                data = fixture(person, pose)
                for path, value in (
                    (("render", "time"), data["render"]["time"] + 1),
                    (("render", "framesPerSecond"), 30), (("samples", "maximumFPS"), 30),
                    (("render", "active"), False), (("render", "paused"), True),
                    (("samples", "count"), 257), (("samples", "active"), 2),
                    (("samples", "paused"), 1), (("samples", "distinctTimes"), 2),
                    (("samples", "distinctTimes"), 10), (("samples", "distinctVectors"), 1),
                    (("samples", "distinctVectors"), 10), (("samples", "invalid"), True),
                    (("captureFrozen",), False), (("completedInputs",), 8),
                    (("policy",), "resume"), (("jointCoordinateSpace",), "screenAfterParentTransform"),
                    (("syntheticOutput",), False), (("networkRequestsBlocked",), False),
                    (("blockedRequestCount",), 1),
                ):
                    self.mutate(person, pose, path, value)
                for claim in ("audioStarted", "microphoneStarted", "cameraStarted", "physicalPhoneVerified", "batteryMeasured", "voiceOverVerified"):
                    self.mutate(person, pose, (claim,), True)
                    self.mutate(person, pose, (claim,), 0)

    def test_attached_bone_lengths_hand_rotation_and_limits(self):
        for person in (*REST, "lilly-private"):
            data = fixture(person, "gesturePeak")
            global CHECKS
            CHECKS += 1
            audit.validate_joints(data["render"]["values"], person)
            for side in ("left", "right"):
                for joint in ("Shoulder", "Elbow", "Wrist"):
                    data = fixture(person, "gesturePeak")
                    data["render"]["values"][side + joint + "X"] += .003
                    self.rejected(data)
                self.mutate(person, "gesturePeak", ("render", "values", side + "HandDegrees"), 0)
                for name, amount in (("ShoulderDegrees", 4.01), ("ElbowDegrees", 28.01), ("WristDegrees", 10.01)):
                    values = fixture(person, "gesturePeak")["render"]["values"]
                    angles = [values[side + key] for key in ("ShoulderDegrees", "ElbowDegrees", "WristDegrees")]
                    angles[("ShoulderDegrees", "ElbowDegrees", "WristDegrees").index(name)] = amount
                    set_arm(values, person, side, *angles)
                    CHECKS += 1
                    with self.assertRaises(RuntimeError):
                        audit.validate_joints(values, person)
                self.mutate(person, "gesturePeak", ("render", "values", side + "Openness"), 1.01)

    def test_common_transform_and_joint_pose_are_the_same_renderer(self):
        for person in PEOPLE:
            for field in audit.COMMON:
                data = fixture(person, "gesturePeak")
                data["render"]["values"][field] += .01 if field in ("nearArmAngle", "farArmAngle") else 20
                self.rejected(data)
        for person in (*REST, "lilly-private"):
            for field in ("headDegrees", "bodyDegrees", "headLift", "bodyLift"):
                self.mutate(person, "gesturePeak", ("render", "values", field), .05 if "Lift" in field else 4)

    def test_resting_life_rate_and_reviewed_crop_limits(self):
        # Oct 16 2026: the resting stage runs at 12 fps, never the old 8, and
        # the wider crop-checked turns are accepted while larger ones are not.
        for person in PEOPLE:
            self.mutate(person, "neutral", ("render", "framesPerSecond"), 8)
            self.mutate(person, "neutral", ("samples", "maximumFPS"), 8)
        for person, degrees, allowed in (("kiana", 1.05, True), ("kiana", 1.2, False),
                                         ("witherspoon", -1.25, True), ("witherspoon", 1.4, False),
                                         ("witherspoon", .3, True), ("witherspoon", .5, False),
                                         ("harley", 1.9, True), ("harley", 2.1, False)):
            data = fixture(person, "gesturePeak")
            data["render"]["values"].update(headDegrees=degrees, headAngle=degrees)
            if allowed:
                self.accepted(data)
            else:
                self.rejected(data)

    def test_rest_and_settled_mean_all_arm_controls_settle(self):
        for person in (*REST, "lilly-private"):
            for pose in ("neutral", "settled"):
                for side in ("left", "right"):
                    for joint, angles in (("elbow", (0, 20, 0)), ("wrist", (0, 0, 8))):
                        with self.subTest(person=person, pose=pose, side=side, joint=joint):
                            data = fixture(person, pose)
                            set_arm(data["render"]["values"], person, side, *angles)
                            self.rejected(data)
        for pose in ("neutral", "settled"):
            for field in ("claspOffsetX", "claspOffsetY"):
                self.mutate("angel", pose, ("render", "values", field), .001)
        for person in PEOPLE:
            data = fixture(person, "gesturePeak")
            data["render"]["values"]["nearArmAngle"] = 0
            data["render"]["values"]["farArmAngle"] = 0
            self.rejected(data)


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.loadTestsFromTestCase(ProtocolChecks))
    print(json.dumps({"schema": "kade.puppet-completion-local-protocol-tests.v1", "syntheticFixtures": True,
                      "nativeProof": False, "checks": CHECKS, "passed": result.wasSuccessful(),
                      "forbiddenRuntimeCalls": FORBIDDEN_CALLS}, separators=(",", ":")))
    raise SystemExit(0 if result.wasSuccessful() and FORBIDDEN_CALLS == 0 else 1)
