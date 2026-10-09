import Foundation
#if canImport(SwiftUI) && !CHARACTER_MODEL_TESTS
import SwiftUI
#endif

/// Conservative exact-atlas study. The original head, locs and shoulders move
/// together; the existing concept supplies only the lower torso below y600.
/// Source RGB and all native facial patch coordinates remain unchanged.
enum CharacterKianaBustGeometry {
    static let bodyClipMinY = 600.0

    static let artwork: CharacterBustArtwork = {
        var value = CharacterBustArtwork(
            bodyAsset: "CharacterKianaBustBody", maskAsset: nil,
            bodyX: 0, bodyY: 0, bodyWidth: 1024, bodyHeight: 1228.8,
            cropX: 155, cropY: 0, cropSide: 740,
            panelX: 205, panelY: -5, panelSide: 640,
            neckX: 576, neckY: 445, waistX: 512, waistY: 1050,
            faceCore: nil, headOutline: .kianaHead, accessoryOutlines: [],
            // The35px overlap exceeds the worst bottom-edge displacement
            // (less than5px) at these restrained production motion bounds.
            motionLimits: CharacterBustMotionLimits(headDegrees: 0.60, bodyDegrees: 0,
                headOffsetPixels: 0.60, bodyOffsetPixels: 0))
        // Mandatory: this resource still contains the old generated concept
        // head. It must never be drawn above the torso-only world boundary.
        value.bodyClipMinY = bodyClipMinY
        return value
    }()

    #if canImport(SwiftUI) && !CHARACTER_MODEL_TESTS
    /// In the unchanged 414x414 neutral atlas panel. This is a close bust,
    /// intentionally preserving the crown's original crop at the top edge.
    static var headPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 145, y: 0))
        path.addLine(to: CGPoint(x: 279, y: 0))
        path.addCurve(to: CGPoint(x: 309, y: 24), control1: CGPoint(x: 291, y: 5), control2: CGPoint(x: 302, y: 13))
        path.addLine(to: CGPoint(x: 319, y: 34))
        path.addLine(to: CGPoint(x: 326, y: 56))
        path.addCurve(to: CGPoint(x: 344, y: 106), control1: CGPoint(x: 339, y: 75), control2: CGPoint(x: 341, y: 88))
        path.addLine(to: CGPoint(x: 346, y: 133))
        path.addLine(to: CGPoint(x: 355, y: 156))
        path.addLine(to: CGPoint(x: 354, y: 175))
        path.addLine(to: CGPoint(x: 365, y: 197))
        path.addLine(to: CGPoint(x: 373, y: 216))
        path.addLine(to: CGPoint(x: 376, y: 239))
        path.addCurve(to: CGPoint(x: 399, y: 280), control1: CGPoint(x: 385, y: 251), control2: CGPoint(x: 392, y: 269))
        path.addLine(to: CGPoint(x: 414, y: 297))
        path.addLine(to: CGPoint(x: 414, y: 414))
        path.addLine(to: CGPoint(x: 0, y: 414))
        path.addLine(to: CGPoint(x: 0, y: 332))
        path.addCurve(to: CGPoint(x: 26, y: 278), control1: CGPoint(x: 5, y: 312), control2: CGPoint(x: 17, y: 293))
        path.addLine(to: CGPoint(x: 35, y: 256))
        path.addLine(to: CGPoint(x: 44, y: 243))
        path.addLine(to: CGPoint(x: 52, y: 217))
        path.addLine(to: CGPoint(x: 60, y: 198))
        path.addLine(to: CGPoint(x: 64, y: 174))
        path.addLine(to: CGPoint(x: 70, y: 151))
        path.addLine(to: CGPoint(x: 72, y: 130))
        path.addLine(to: CGPoint(x: 79, y: 107))
        path.addLine(to: CGPoint(x: 82, y: 90))
        path.addCurve(to: CGPoint(x: 113, y: 34), control1: CGPoint(x: 90, y: 68), control2: CGPoint(x: 101, y: 48))
        path.addLine(to: CGPoint(x: 135, y: 14))
        path.addLine(to: CGPoint(x: 145, y: 0))
        path.closeSubpath()
        return path
    }
    #endif
}
