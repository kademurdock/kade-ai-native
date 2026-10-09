import Foundation

/// The established woman librarian's face, wire glasses and pinned hair all
/// come from her unchanged neutral atlas panel, with existing facial patches.
enum CharacterWitherspoonBustGeometry {
    static let artwork = CharacterBustArtwork(
        bodyAsset: "CharacterWitherspoonBustBody", maskAsset: nil,
        bodyX: 0, bodyY: -75, bodyWidth: 1024, bodyHeight: 1536,
        cropX: 202, cropY: 90, cropSide: 620,
        panelX: 202, panelY: 90, panelSide: 620,
        neckX: 512, neckY: 540, waistX: 512, waistY: 1025,
        faceCore: nil, headOutline: .witherspoonHead, accessoryOutlines: [],
        motionLimits: CharacterBustMotionLimits(headDegrees: 1, bodyDegrees: 0,
            headOffsetPixels: 0.6, bodyOffsetPixels: 0))
}

#if canImport(SwiftUI) && !CHARACTER_MODEL_TESTS
import SwiftUI

extension CharacterWitherspoonBustGeometry {
    /// Coordinates are in the unchanged top-left 414-pixel panel, not the
    /// generated body. Keep the close crop: her atlas already crops the crown.
    /// The lower neck includes a narrow original blouse overlap at the V.
    static var headPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 205, y: 0))
        path.addLine(to: CGPoint(x: 262, y: 0))
        path.addCurve(to: CGPoint(x: 290, y: 21),
            control1: CGPoint(x: 276, y: 3), control2: CGPoint(x: 285, y: 10))
        path.addCurve(to: CGPoint(x: 309, y: 60),
            control1: CGPoint(x: 298, y: 30), control2: CGPoint(x: 306, y: 44))
        path.addCurve(to: CGPoint(x: 316, y: 104),
            control1: CGPoint(x: 313, y: 75), control2: CGPoint(x: 313, y: 87))
        path.addCurve(to: CGPoint(x: 316, y: 139),
            control1: CGPoint(x: 320, y: 117), control2: CGPoint(x: 321, y: 129))
        path.addCurve(to: CGPoint(x: 309, y: 171),
            control1: CGPoint(x: 312, y: 151), control2: CGPoint(x: 309, y: 158))
        path.addCurve(to: CGPoint(x: 315, y: 211),
            control1: CGPoint(x: 310, y: 184), control2: CGPoint(x: 316, y: 197))
        path.addCurve(to: CGPoint(x: 309, y: 254),
            control1: CGPoint(x: 316, y: 228), control2: CGPoint(x: 313, y: 241))
        path.addCurve(to: CGPoint(x: 300, y: 282),
            control1: CGPoint(x: 306, y: 266), control2: CGPoint(x: 303, y: 278))
        path.addQuadCurve(to: CGPoint(x: 281, y: 278),
            control: CGPoint(x: 289, y: 289))
        path.addLine(to: CGPoint(x: 275, y: 270))
        path.addCurve(to: CGPoint(x: 266, y: 318),
            control1: CGPoint(x: 276, y: 286), control2: CGPoint(x: 271, y: 304))
        path.addCurve(to: CGPoint(x: 246, y: 364),
            control1: CGPoint(x: 260, y: 335), control2: CGPoint(x: 252, y: 352))
        path.addQuadCurve(to: CGPoint(x: 219, y: 414),
            control: CGPoint(x: 228, y: 395))
        path.addLine(to: CGPoint(x: 205, y: 414))
        path.addQuadCurve(to: CGPoint(x: 176, y: 369),
            control: CGPoint(x: 192, y: 392))
        path.addCurve(to: CGPoint(x: 155, y: 316),
            control1: CGPoint(x: 166, y: 351), control2: CGPoint(x: 159, y: 333))
        path.addQuadCurve(to: CGPoint(x: 148, y: 272),
            control: CGPoint(x: 149, y: 292))
        path.addLine(to: CGPoint(x: 142, y: 280))
        path.addQuadCurve(to: CGPoint(x: 126, y: 286),
            control: CGPoint(x: 133, y: 289))
        path.addCurve(to: CGPoint(x: 109, y: 260),
            control1: CGPoint(x: 121, y: 280), control2: CGPoint(x: 116, y: 269))
        path.addCurve(to: CGPoint(x: 94, y: 225),
            control1: CGPoint(x: 102, y: 250), control2: CGPoint(x: 96, y: 237))
        path.addCurve(to: CGPoint(x: 89, y: 188),
            control1: CGPoint(x: 92, y: 212), control2: CGPoint(x: 87, y: 199))
        path.addCurve(to: CGPoint(x: 92, y: 151),
            control1: CGPoint(x: 86, y: 175), control2: CGPoint(x: 90, y: 162))
        path.addCurve(to: CGPoint(x: 99, y: 110),
            control1: CGPoint(x: 91, y: 136), control2: CGPoint(x: 94, y: 120))
        path.addCurve(to: CGPoint(x: 119, y: 70),
            control1: CGPoint(x: 101, y: 95), control2: CGPoint(x: 110, y: 80))
        path.addCurve(to: CGPoint(x: 150, y: 36),
            control1: CGPoint(x: 127, y: 57), control2: CGPoint(x: 138, y: 43))
        path.addCurve(to: CGPoint(x: 179, y: 13),
            control1: CGPoint(x: 160, y: 28), control2: CGPoint(x: 168, y: 20))
        path.addQuadCurve(to: CGPoint(x: 205, y: 0),
            control: CGPoint(x: 190, y: 4))
        path.closeSubpath()
        return path
    }
}
#endif
