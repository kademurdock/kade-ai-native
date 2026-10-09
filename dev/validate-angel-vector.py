"""Validate original vector source, identity binding and conservative motion hulls.

This examines drawing data and coordinates only. It neither generates nor edits
an image and cannot establish native rendering or physical iPhone acceptance.
"""
import hashlib
import itertools
import json
import math
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ASSET = ROOT / "Sources/Assets.xcassets/CharacterAngelVectorArt.dataset/angel-vector.json"
EXPECTED_SHA = "805783c577c0beb332256fd8786fefa6b42d8a24a2f499b4e1a3de9e26f7f1e0"
GROUPS = {"leftWing", "rightWing", "body", "head", "halo"}
LENGTHS = {"M": 2, "L": 2, "Q": 4, "C": 6, "Z": 0}


def rotate(point, pivot, degrees):
    angle = math.radians(degrees)
    x, y = point[0] - pivot[0], point[1] - pivot[1]
    return [pivot[0] + x * math.cos(angle) - y * math.sin(angle),
            pivot[1] + x * math.sin(angle) + y * math.cos(angle)]


def main():
    data = ASSET.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    assert digest == EXPECTED_SHA, "Original Angel master hash changed"
    art = json.loads(data)
    assert art["schema"] == 1 and art["canvas"] == 1024
    assert set(art["pivots"]) == GROUPS == {shape["group"] for shape in art["shapes"]}
    assert len({shape["id"] for shape in art["shapes"]}) == len(art["shapes"])
    assert len(art["features"]["eyes"]) == len(art["features"]["cheeks"]) == 2
    for shape in art["shapes"]:
        assert shape["path"][0]["op"] == "M"
        for command in shape["path"]:
            assert command["op"] in LENGTHS and len(command["v"]) == LENGTHS[command["op"]]
            assert all(math.isfinite(value) and -128 <= value <= 1152 for value in command["v"])
        for paint in [shape["fill"], shape.get("stroke", "none")]:
            assert paint == "none" or paint.startswith("#") or paint in art["gradients"]
    outside = set()
    hull = [1024.0, 1024.0, 0.0, 0.0]
    cases = itertools.product([-0.4, 0, 0.4], [-1.8, 0, 1.8], [-1.8, 0, 1.8], [-1.5, 0, 1.5])
    for body_angle, head_angle, wing_angle, offset in cases:
        for shape in art["shapes"]:
            margin = shape.get("strokeWidth", 0) / 2
            group = shape["group"]
            for command in shape["path"]:
                for index in range(0, len(command["v"]), 2):
                    point = command["v"][index:index + 2]
                    if group in {"leftWing", "rightWing"}:
                        point = rotate(point, art["pivots"][group], wing_angle)
                    elif group in {"head", "halo"}:
                        if group == "halo":
                            point[1] += 3.072 if offset > 0 else -3.072
                            point = rotate(point, art["pivots"][group], 0.35 if offset > 0 else -0.35)
                        point[1] += 2 if offset > 0 else -2
                        point = rotate(point, art["pivots"]["head"], head_angle)
                    point[1] += offset
                    point = rotate(point, art["pivots"]["body"], body_angle)
                    hull = [min(hull[0], point[0] - margin), min(hull[1], point[1] - margin),
                            max(hull[2], point[0] + margin), max(hull[3], point[1] + margin)]
                    if any(value < margin or value > 1024 - margin for value in point):
                        outside.add(shape["id"])
    assert not outside, "Motion may clip authored shapes: " + ", ".join(sorted(outside))
    print(json.dumps({"passed": True, "sourceSHA256": digest, "shapeCount": len(art["shapes"]),
                      "motionControlHull": hull, "imageEditing": False, "nativeRenderingVerified": False}, indent=2))


if __name__ == "__main__":
    main()
