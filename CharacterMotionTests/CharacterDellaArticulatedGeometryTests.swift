import Foundation

func runCharacterDellaArticulatedGeometryChecks(_ check: (Bool, String) -> Void) {
    let geometry = CharacterDellaArticulatedGeometry.self
    let avatar = "/images/" + CharacterMotion.dellaFile
    func eligible(enabled: Bool = true, stage: Bool = true, side: Double = 208,
                  id: String? = CharacterMotion.dellaID, path: String? = nil,
                  resources: Bool = true) -> Bool {
        geometry.eligible(enabled: enabled, stage: stage, side: side,
            agentID: id, avatarPath: path ?? avatar, resourcesPresent: resources)
    }
    check(eligible(), "An explicitly enabled complete Della study resolves at the ordinary large stage")
    check(eligible(side: 160), "The Della study preserves the readable minimum bust width")
    check(!eligible(enabled: false), "Preparing an optional resource alone never activates articulated Della")
    check(!eligible(stage: false), "A compact portrait row cannot become a tall body study")
    check(!eligible(id: CharacterMotion.kianaID), "A different character cannot borrow Della's body")
    check(!eligible(id: nil), "Missing identity cannot activate the body study")
    check(!eligible(path: "/images/changed-avatar.png"), "A changed Della avatar retains its usual portrait path")
    check(!eligible(resources: false), "A missing master or accepted torso/matte falls back to the accepted bust")
    for side in [Double.nan, .infinity, -.infinity, -1, 0, 84, 104, 132, 159.999] {
        check(!eligible(side: side), "Compact or invalid stage geometry never opts into the tall candidate")
    }

    // Tall framing adds vertical room; it never scales the face to fit height.
    check(abs(geometry.stageHeight(side: 208) - 311.4975845410628) < 0.000001,
        "A 208-point study exposes palms in a 311.5-point body viewport")
    check(abs(geometry.stageHeight(side: 160) - 239.6135265700483) < 0.000001,
        "The minimum readable candidate keeps the same rectangular aspect")
    for side in [Double.nan, .infinity, -.infinity, -1, 0, Double.greatestFiniteMagnitude] {
        check(geometry.stageHeight(side: side) == 0, "Invalid or overflowing tall frame sizes remain inert")
    }
    let head = CharacterDellaBustGeometry.artwork
    check(geometry.cropWidth == head.cropSide && head.panelSide == 414
        && head.panelX == 0 && head.panelY == 0 && head.cropX == 0 && head.cropY == 0,
        "The full unchanged original 414-pixel facial panel retains its accepted mobile width and origin")
    check(head.maskPlacement?.x == 35 && head.maskPlacement?.y == 0 && head.maskPlacement?.side == 350,
        "Articulated framing does not reinterpret Della's independently registered alpha-only head mask")
    check(head.neckX == 219 && head.neckY == 306 && head.waistX == 207 && head.waistY == 454,
        "Head and torso retain the accepted neck and waist articulation points")

    func pointMatches(_ point: [Double], _ x: Double, _ y: Double) -> Bool {
        abs(point[0] - x) < 0.000001 && abs(point[1] - y) < 0.000001
    }
    check(geometry.sourceSide == 1254 && abs(geometry.bodySide / geometry.sourceSide - geometry.sourceScale) < 0.000001,
        "Both original source canvases share one uniform source-to-bust mapping")
    check(geometry.bodyX == head.bodyX && geometry.bodyY == head.bodyY && geometry.bodySide == head.bodyWidth,
        "The new arm master aligns to the accepted torso placement rather than a separately resized extraction")
    check(pointMatches(geometry.worldPoint([0, 0]), -132, -1)
        && pointMatches(geometry.worldPoint([1254, 1254]), 545.16, 676.16),
        "Source edges map to explicit body offsets without stretching or moving the collar")
    check(pointMatches(geometry.worldPoint(geometry.viewerLeftShoulder), 46.2, 244.7)
        && pointMatches(geometry.worldPoint(geometry.viewerRightShoulder), 375.6, 244.7),
        "The full sleeve and palm rotate at the authored source shoulder positions")
    check(Set(geometry.requiredAssets) == Set(["CharacterDellaArticulatedReview", "CharacterDellaBustBody", "CharacterDellaBustMask"]),
        "The optional study requires its unchanged master and both accepted torso/head resources")
}
