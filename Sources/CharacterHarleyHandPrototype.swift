import Foundation

/// Two isolated studies using the identical source image and silhouette.
/// Neither is registered as production art.
enum CharacterHarleyHandPrototypeVariant: String, CaseIterable {
    case smallRight, largeLeft

    var placement: CharacterHarleyHandPrototypePlacement {
        switch self {
        case .smallRight:
            return CharacterHarleyHandPrototypePlacement(imageX: 628, imageY: 359,
                imageWidth: 194.56, imageHeight: 291.84,
                elbowX: 728, elbowY: 638, mirrored: false)
        case .largeLeft:
            return CharacterHarleyHandPrototypePlacement(imageX: 180, imageY: 325,
                imageWidth: 291.84, imageHeight: 437.76,
                elbowX: 321.36, elbowY: 743, mirrored: true)
        }
    }
}

struct CharacterHarleyHandPrototypePlacement {
    let imageX: Double
    let imageY: Double
    let imageWidth: Double
    let imageHeight: Double
    let elbowX: Double
    let elbowY: Double
    let mirrored: Bool
}

/// An isolated review study, not an approved figure pack or production gesture.
/// The caller chooses one elapsed sample for one gesture. Feeding every speech
/// clip's elapsed clock here would repeat the greeting and is not a turn policy.
struct CharacterHarleyHandPrototypePose {
    let visible: Bool
    let angle: Double

    static let hidden = CharacterHarleyHandPrototypePose(visible: false, angle: 72)
}

enum CharacterHarleyHandPrototypeMotion {
    static let duration = 2.0

    /// Disabled motion has no additional hand at all. `active` must already
    /// include the app/system motion, low-power, scene and visibility gates.
    static func pose(elapsed: Double, active: Bool) -> CharacterHarleyHandPrototypePose {
        guard active, elapsed.isFinite, elapsed > 0, elapsed < duration else { return .hidden }
        func smooth(_ value: Double) -> Double {
            let bounded = min(1, max(0, value))
            return bounded * bounded * (3 - 2 * bounded)
        }
        let angle: Double
        if elapsed < 0.5 {
            angle = 72 * (1 - smooth(elapsed / 0.5))
        } else if elapsed < 1.5 {
            // Two small swings, with zero angle at both ends. The visible pose
            // remains within the reviewed corner rather than crossing the face.
            angle = sin((elapsed - 0.5) * 4 * .pi) * 2
        } else {
            angle = 72 * smooth((elapsed - 1.5) / 0.5)
        }
        return CharacterHarleyHandPrototypePose(visible: true, angle: angle)
    }
}

#if DEBUG && targetEnvironment(simulator) && canImport(SwiftUI) && !CHARACTER_MODEL_TESTS
import SwiftUI

/// Foreground-only study over the existing 540-pixel close crop. No face,
/// collar, torso, call control or atlas is replaced. It is intentionally not
/// registered with CharacterFigureArtwork or CharacterBustArtwork.
struct CharacterHarleyHandPrototype: View {
    let side: Double
    let sampleElapsed: Double
    let active: Bool
    var variant: CharacterHarleyHandPrototypeVariant = .smallRight

    private var pose: CharacterHarleyHandPrototypePose {
        CharacterHarleyHandPrototypeMotion.pose(elapsed: sampleElapsed, active: active)
    }

    private let cropX = 242.0
    private let cropSide = 540.0

    @ViewBuilder var body: some View {
        if pose.visible && side.isFinite && side > 0 && pose.angle.isFinite {
            let unit = side / cropSide
            let placement = variant.placement
            let angle = min(72, max(-2, pose.angle))
            Image("CharacterHarleyGreetingHandPrototype")
                .resizable()
                .interpolation(.high)
                .frame(width: placement.imageWidth * unit, height: placement.imageHeight * unit)
                // The generated source has diffuse alpha outside the anatomy.
                // This authored path discards it without changing source RGB.
                .clipShape(CharacterHarleyHandPrototypeCut())
                // Mirror the already-cut foreground, including its outline.
                // The reference head and all atlas patches remain unchanged.
                .scaleEffect(x: placement.mirrored ? -1 : 1, y: 1)
                .offset(x: (placement.imageX - cropX) * unit, y: placement.imageY * unit)
                .frame(width: side, height: side, alignment: .topLeading)
                .rotationEffect(.degrees(placement.mirrored ? -angle : angle),
                    anchor: UnitPoint(x: CGFloat((placement.elbowX - cropX) / cropSide),
                        y: CGFloat(placement.elbowY / cropSide)))
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}

/// Coordinates follow the generated 1024x1536 anatomy. The curve deliberately
/// stays just inside its soft outer boundary, excluding the background halo.
private struct CharacterHarleyHandPrototypeCut: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 266, y: 282))
        path.addCurve(to: CGPoint(x: 277, y: 268), control1: CGPoint(x: 260, y: 271), control2: CGPoint(x: 265, y: 268))
        path.addCurve(to: CGPoint(x: 315, y: 296), control1: CGPoint(x: 292, y: 269), control2: CGPoint(x: 306, y: 282))
        path.addCurve(to: CGPoint(x: 376, y: 376), control1: CGPoint(x: 337, y: 324), control2: CGPoint(x: 358, y: 354))
        path.addCurve(to: CGPoint(x: 394, y: 382), control1: CGPoint(x: 385, y: 383), control2: CGPoint(x: 390, y: 385))
        path.addCurve(to: CGPoint(x: 425, y: 321), control1: CGPoint(x: 409, y: 368), control2: CGPoint(x: 419, y: 338))
        path.addCurve(to: CGPoint(x: 444, y: 214), control1: CGPoint(x: 435, y: 286), control2: CGPoint(x: 440, y: 248))
        path.addCurve(to: CGPoint(x: 459, y: 104), control1: CGPoint(x: 446, y: 173), control2: CGPoint(x: 452, y: 131))
        path.addCurve(to: CGPoint(x: 484, y: 67), control1: CGPoint(x: 464, y: 81), control2: CGPoint(x: 473, y: 67))
        path.addCurve(to: CGPoint(x: 508, y: 89), control1: CGPoint(x: 497, y: 66), control2: CGPoint(x: 506, y: 74))
        path.addCurve(to: CGPoint(x: 505, y: 149), control1: CGPoint(x: 511, y: 106), control2: CGPoint(x: 508, y: 127))
        path.addCurve(to: CGPoint(x: 499, y: 267), control1: CGPoint(x: 501, y: 190), control2: CGPoint(x: 500, y: 238))
        path.addCurve(to: CGPoint(x: 513, y: 272), control1: CGPoint(x: 500, y: 272), control2: CGPoint(x: 507, y: 273))
        path.addCurve(to: CGPoint(x: 541, y: 145), control1: CGPoint(x: 523, y: 231), control2: CGPoint(x: 533, y: 181))
        path.addCurve(to: CGPoint(x: 565, y: 68), control1: CGPoint(x: 549, y: 113), control2: CGPoint(x: 556, y: 83))
        path.addCurve(to: CGPoint(x: 589, y: 53), control1: CGPoint(x: 571, y: 55), control2: CGPoint(x: 579, y: 51))
        path.addCurve(to: CGPoint(x: 608, y: 81), control1: CGPoint(x: 603, y: 54), control2: CGPoint(x: 611, y: 65))
        path.addCurve(to: CGPoint(x: 584, y: 206), control1: CGPoint(x: 604, y: 119), control2: CGPoint(x: 591, y: 171))
        path.addCurve(to: CGPoint(x: 574, y: 280), control1: CGPoint(x: 579, y: 235), control2: CGPoint(x: 574, y: 262))
        path.addCurve(to: CGPoint(x: 590, y: 289), control1: CGPoint(x: 576, y: 286), control2: CGPoint(x: 584, y: 290))
        path.addCurve(to: CGPoint(x: 622, y: 153), control1: CGPoint(x: 604, y: 246), control2: CGPoint(x: 615, y: 190))
        path.addCurve(to: CGPoint(x: 648, y: 106), control1: CGPoint(x: 630, y: 121), control2: CGPoint(x: 638, y: 106))
        path.addCurve(to: CGPoint(x: 672, y: 126), control1: CGPoint(x: 662, y: 101), control2: CGPoint(x: 672, y: 112))
        path.addCurve(to: CGPoint(x: 652, y: 211), control1: CGPoint(x: 672, y: 149), control2: CGPoint(x: 661, y: 183))
        path.addCurve(to: CGPoint(x: 626, y: 305), control1: CGPoint(x: 644, y: 242), control2: CGPoint(x: 631, y: 282))
        path.addCurve(to: CGPoint(x: 629, y: 328), control1: CGPoint(x: 625, y: 315), control2: CGPoint(x: 624, y: 323))
        path.addCurve(to: CGPoint(x: 695, y: 214), control1: CGPoint(x: 649, y: 291), control2: CGPoint(x: 679, y: 239))
        path.addCurve(to: CGPoint(x: 717, y: 196), control1: CGPoint(x: 704, y: 200), control2: CGPoint(x: 710, y: 196))
        path.addCurve(to: CGPoint(x: 739, y: 215), control1: CGPoint(x: 729, y: 195), control2: CGPoint(x: 737, y: 203))
        path.addCurve(to: CGPoint(x: 723, y: 262), control1: CGPoint(x: 742, y: 229), control2: CGPoint(x: 732, y: 248))
        path.addCurve(to: CGPoint(x: 680, y: 353), control1: CGPoint(x: 708, y: 291), control2: CGPoint(x: 689, y: 327))
        path.addCurve(to: CGPoint(x: 655, y: 464), control1: CGPoint(x: 667, y: 386), control2: CGPoint(x: 666, y: 427))
        path.addCurve(to: CGPoint(x: 614, y: 570), control1: CGPoint(x: 644, y: 504), control2: CGPoint(x: 624, y: 544))
        path.addCurve(to: CGPoint(x: 618, y: 652), control1: CGPoint(x: 609, y: 597), control2: CGPoint(x: 613, y: 626))
        path.addCurve(to: CGPoint(x: 646, y: 783), control1: CGPoint(x: 625, y: 697), control2: CGPoint(x: 635, y: 744))
        path.addCurve(to: CGPoint(x: 693, y: 948), control1: CGPoint(x: 661, y: 839), control2: CGPoint(x: 681, y: 907))
        path.addCurve(to: CGPoint(x: 697, y: 982), control1: CGPoint(x: 696, y: 960), control2: CGPoint(x: 697, y: 974))
        path.addCurve(to: CGPoint(x: 730, y: 1008), control1: CGPoint(x: 708, y: 984), control2: CGPoint(x: 725, y: 996))
        path.addCurve(to: CGPoint(x: 715, y: 1111), control1: CGPoint(x: 738, y: 1031), control2: CGPoint(x: 725, y: 1081))
        path.addLine(to: CGPoint(x: 699, y: 1127))
        path.addCurve(to: CGPoint(x: 689, y: 1316), control1: CGPoint(x: 697, y: 1194), control2: CGPoint(x: 698, y: 1262))
        path.addCurve(to: CGPoint(x: 662, y: 1413), control1: CGPoint(x: 682, y: 1358), control2: CGPoint(x: 674, y: 1396))
        path.addCurve(to: CGPoint(x: 584, y: 1475), control1: CGPoint(x: 644, y: 1446), control2: CGPoint(x: 615, y: 1468))
        path.addCurve(to: CGPoint(x: 472, y: 1460), control1: CGPoint(x: 548, y: 1487), control2: CGPoint(x: 509, y: 1476))
        path.addCurve(to: CGPoint(x: 398, y: 1405), control1: CGPoint(x: 443, y: 1448), control2: CGPoint(x: 416, y: 1432))
        path.addCurve(to: CGPoint(x: 365, y: 1280), control1: CGPoint(x: 374, y: 1367), control2: CGPoint(x: 358, y: 1320))
        path.addCurve(to: CGPoint(x: 383, y: 1232), control1: CGPoint(x: 367, y: 1260), control2: CGPoint(x: 375, y: 1241))
        path.addCurve(to: CGPoint(x: 377, y: 1177), control1: CGPoint(x: 388, y: 1218), control2: CGPoint(x: 375, y: 1194))
        path.addCurve(to: CGPoint(x: 377, y: 1089), control1: CGPoint(x: 377, y: 1150), control2: CGPoint(x: 370, y: 1127))
        path.addCurve(to: CGPoint(x: 376, y: 1018), control1: CGPoint(x: 381, y: 1063), control2: CGPoint(x: 372, y: 1037))
        path.addCurve(to: CGPoint(x: 402, y: 916), control1: CGPoint(x: 379, y: 975), control2: CGPoint(x: 389, y: 935))
        path.addLine(to: CGPoint(x: 424, y: 891))
        path.addCurve(to: CGPoint(x: 427, y: 736), control1: CGPoint(x: 429, y: 850), control2: CGPoint(x: 426, y: 787))
        path.addCurve(to: CGPoint(x: 422, y: 606), control1: CGPoint(x: 428, y: 690), control2: CGPoint(x: 426, y: 647))
        path.addCurve(to: CGPoint(x: 414, y: 553), control1: CGPoint(x: 421, y: 584), control2: CGPoint(x: 419, y: 566))
        path.addCurve(to: CGPoint(x: 368, y: 494), control1: CGPoint(x: 404, y: 537), control2: CGPoint(x: 385, y: 515))
        path.addCurve(to: CGPoint(x: 320, y: 415), control1: CGPoint(x: 350, y: 468), control2: CGPoint(x: 333, y: 438))
        path.addCurve(to: CGPoint(x: 283, y: 333), control1: CGPoint(x: 305, y: 388), control2: CGPoint(x: 290, y: 353))
        path.addCurve(to: CGPoint(x: 266, y: 282), control1: CGPoint(x: 276, y: 313), control2: CGPoint(x: 268, y: 292))
        path.closeSubpath()
        return path.applying(CGAffineTransform(a: rect.width / 1024, b: 0, c: 0,
            d: rect.height / 1536, tx: rect.minX, ty: rect.minY))
    }
}
#endif
