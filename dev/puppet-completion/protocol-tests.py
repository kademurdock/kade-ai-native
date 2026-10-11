"""Synthetic, memory-only checks of the completion receipt boundary.

These fixtures are deliberately constructed here. They are not screenshots,
native observations, phone/battery measurements or release evidence. Importing
the helper is safe; source/build/simulator/service entry points are fenced off.
Run with Python -B so this test does not create bytecode or copy artifacts.
"""
import cmath
import importlib.util
import json
import math
from pathlib import Path
import subprocess
import sys
import unittest

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
for entry in ("source", "initial_source", "sim", "run_ui", "compiled_tests", "simulator_record", "operation_remaining", "emit"):
    setattr(audit.host, entry, forbidden)
for entry in ("save", "ui", "capture", "emit", "main"):
    setattr(audit, entry, forbidden)


# Explicit rest registration, independent of the validator's inventory. The
# fixture arm uses complex-plane rigid rotations to retain both bone lengths.
REST = {
    "harley": ((.18, .88), (.14, 1.11), (.28, 1.29), (.82, .88), (.86, 1.11), (.72, 1.29)),
    "kiana": ((.13, .94), (.13, 1.14), (.27, 1.30), (.87, .94), (.87, 1.14), (.73, 1.30)),
    "lilly": ((.20, .92), (.17, 1.13), (.30, 1.30), (.80, .92), (.83, 1.13), (.70, 1.30)),
    "witherspoon": ((.19, .85), (.16, 1.10), (.30, 1.29), (.81, .85), (.84, 1.10), (.70, 1.29)),
}
CROP = {"harley": 540, "kiana": 620, "lilly": 700, "witherspoon": 620}
PEOPLE = ("harley", "kiana", "lilly", "della", "witherspoon", "lilly-private", "angel")
POSES = ("neutral", "gesturePeak", "settled")


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
    fps = 8 if pose == "neutral" else 24
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


class ProtocolChecks(unittest.TestCase):
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
