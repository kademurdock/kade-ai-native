import Foundation

/// Offline-only candidate framing. The approved 414-pixel head and its alpha
/// registration stay unchanged; a taller viewport exposes the original palms
/// in one headless master without shrinking Della's face on a phone.
enum CharacterDellaArticulatedGeometry {
    static let masterAsset = "CharacterDellaArticulatedReview"
    static let torsoAsset = "CharacterDellaBustBody"
    static let sourceSide = 1254.0
    static let sourceScale = 0.54
    static let bodyX = -132.0
    static let bodyY = -1.0
    static let bodySide = 677.16
    static let cropWidth = 414.0
    static let cropHeight = 620.0
    static let viewerLeftShoulder = [330.0, 455.0]
    static let viewerRightShoulder = [940.0, 455.0]
    static let requiredAssets = [masterAsset, torsoAsset, "CharacterDellaBustMask"]

    static func eligible(enabled: Bool, stage: Bool, side: Double,
                         agentID: String?, avatarPath: String?, resourcesPresent: Bool) -> Bool {
        enabled && stage && side.isFinite && side >= 160 && resourcesPresent
            && agentID == CharacterMotion.dellaID
            && CharacterMotion.prepared(id: agentID, path: avatarPath)
    }

    static func stageHeight(side: Double) -> Double {
        let ratio = cropHeight / cropWidth
        guard side.isFinite, side > 0, side <= Double.greatestFiniteMagnitude / ratio else { return 0 }
        return side * ratio
    }

    /// Translate a common master point into the unchanged bust world.
    static func worldPoint(_ source: [Double]) -> [Double] {
        [bodyX + source[0] * sourceScale, bodyY + source[1] * sourceScale]
    }
}

#if DEBUG && targetEnvironment(simulator) && canImport(SwiftUI) && !CHARACTER_MODEL_TESTS
import SwiftUI

extension CharacterDellaArticulatedGeometry {
    // Keep editable authored paths below for source-coordinate QA, but compile
    // each only once for the native timeline's repeated clipping operations.
    static let cachedTorsoPath = torsoPath
    static let cachedLowerCardiganPath = lowerCardiganPath
    static let cachedViewerLeftArmPath = viewerLeftArmPath
    static let cachedViewerRightArmPath = viewerRightArmPath

    /// Lower cardigan only from the untouched gesture master. The accepted
    /// short-sleeve plate has transparent clefts beneath its old cuffs; these
    /// two static underpaint patches restore real cloth below the moving arms.
    /// Their upper edges follow below the cuffs and palms, excluding anatomy,
    /// the original central blouse, and every collar/neck pixel.
    static var lowerCardiganPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 355, y: 985))
        path.addQuadCurve(to: CGPoint(x: 260, y: 1035), control: CGPoint(x: 310, y: 1015))
        path.addLine(to: CGPoint(x: 175, y: 1254))
        path.addLine(to: CGPoint(x: 420, y: 1254))
        path.addLine(to: CGPoint(x: 420, y: 985))
        path.closeSubpath()
        path.move(to: CGPoint(x: 815, y: 1090))
        path.addLine(to: CGPoint(x: 965, y: 1090))
        path.addQuadCurve(to: CGPoint(x: 1040, y: 1100), control: CGPoint(x: 1015, y: 1102))
        path.addLine(to: CGPoint(x: 1100, y: 1254))
        path.addLine(to: CGPoint(x: 815, y: 1254))
        path.closeSubpath()
        return path
    }

    /// Original torso pixels only. The narrow central plate omits its fused
    /// short sleeves; moving sleeve caps overlap this underpaint at shoulders.
    /// This path is editable source geometry, never a generated extraction.
    static var torsoPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 480, y: 285))
        path.addCurve(to: CGPoint(x: 320, y: 450), control1: CGPoint(x: 390, y: 320), control2: CGPoint(x: 340, y: 382))
        // The underpaint extends beneath the moving inner sleeve by at least
        // forty source pixels. A narrow plate exposes a background slit as
        // soon as the elbow rotates away from its neutral shoulder.
        path.addLine(to: CGPoint(x: 260, y: 690))
        path.addQuadCurve(to: CGPoint(x: 245, y: 935), control: CGPoint(x: 235, y: 790))
        // The original lower cardigan widens below its old cuffs. Preserve
        // that opaque silhouette rather than trimming a straight waist notch.
        // Its under-cuff alpha clefts remain source transparency, not a cut.
        path.addLine(to: CGPoint(x: 180, y: 1254))
        path.addLine(to: CGPoint(x: 1090, y: 1254))
        path.addLine(to: CGPoint(x: 1010, y: 935))
        path.addQuadCurve(to: CGPoint(x: 995, y: 690), control: CGPoint(x: 1020, y: 790))
        path.addLine(to: CGPoint(x: 930, y: 450))
        path.addCurve(to: CGPoint(x: 790, y: 285), control1: CGPoint(x: 915, y: 382), control2: CGPoint(x: 850, y: 320))
        path.closeSubpath()
        return path
    }

    /// Viewer-left complete bent sleeve, cuff and open palm remain attached.
    /// At the fingers the cut follows the actual hand instead of retaining
    /// the cream blouse or a strip of cardigan behind the moving anatomy.
    static var viewerLeftArmPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 328, y: 420))
        path.addCurve(to: CGPoint(x: 100, y: 695), control1: CGPoint(x: 235, y: 445), control2: CGPoint(x: 144, y: 574))
        path.addCurve(to: CGPoint(x: 153, y: 1002), control1: CGPoint(x: 32, y: 797), control2: CGPoint(x: 20, y: 947))
        path.addQuadCurve(to: CGPoint(x: 275, y: 1025), control: CGPoint(x: 207, y: 1030))
        path.addQuadCurve(to: CGPoint(x: 294, y: 950), control: CGPoint(x: 290, y: 987))
        path.addQuadCurve(to: CGPoint(x: 367, y: 943), control: CGPoint(x: 330, y: 922))
        path.addCurve(to: CGPoint(x: 454, y: 969), control1: CGPoint(x: 393, y: 964), control2: CGPoint(x: 425, y: 970))
        path.addQuadCurve(to: CGPoint(x: 530, y: 937), control: CGPoint(x: 494, y: 968))
        path.addQuadCurve(to: CGPoint(x: 565, y: 903), control: CGPoint(x: 558, y: 922))
        path.addQuadCurve(to: CGPoint(x: 548, y: 882), control: CGPoint(x: 567, y: 884))
        path.addQuadCurve(to: CGPoint(x: 544, y: 870), control: CGPoint(x: 547, y: 875))
        path.addQuadCurve(to: CGPoint(x: 524, y: 865), control: CGPoint(x: 535, y: 861))
        // The real notch is near x488,y877. The old broader arch retained a
        // plum cardigan triangle between these two fingers when the arm moved.
        path.addQuadCurve(to: CGPoint(x: 488, y: 877), control: CGPoint(x: 505, y: 866))
        path.addQuadCurve(to: CGPoint(x: 489, y: 865), control: CGPoint(x: 491, y: 870))
        path.addQuadCurve(to: CGPoint(x: 475, y: 851), control: CGPoint(x: 486, y: 854))
        path.addQuadCurve(to: CGPoint(x: 450, y: 852), control: CGPoint(x: 462, y: 847))
        path.addQuadCurve(to: CGPoint(x: 405, y: 852), control: CGPoint(x: 430, y: 857))
        path.addQuadCurve(to: CGPoint(x: 390, y: 841), control: CGPoint(x: 394, y: 852))
        path.addQuadCurve(to: CGPoint(x: 384, y: 816), control: CGPoint(x: 386, y: 827))
        path.addQuadCurve(to: CGPoint(x: 372, y: 784), control: CGPoint(x: 385, y: 799))
        path.addQuadCurve(to: CGPoint(x: 370, y: 771), control: CGPoint(x: 368, y: 779))
        path.addQuadCurve(to: CGPoint(x: 376, y: 752), control: CGPoint(x: 376, y: 762))
        path.addQuadCurve(to: CGPoint(x: 371, y: 732), control: CGPoint(x: 376, y: 741))
        path.addQuadCurve(to: CGPoint(x: 355, y: 715), control: CGPoint(x: 365, y: 719))
        path.addQuadCurve(to: CGPoint(x: 346, y: 718), control: CGPoint(x: 349, y: 713))
        path.addQuadCurve(to: CGPoint(x: 339, y: 739), control: CGPoint(x: 337, y: 723))
        path.addQuadCurve(to: CGPoint(x: 333, y: 752), control: CGPoint(x: 340, y: 747))
        path.addQuadCurve(to: CGPoint(x: 313, y: 776), control: CGPoint(x: 323, y: 765))
        path.addQuadCurve(to: CGPoint(x: 290, y: 778), control: CGPoint(x: 302, y: 794))
        path.addQuadCurve(to: CGPoint(x: 283, y: 800), control: CGPoint(x: 286, y: 793))
        path.addQuadCurve(to: CGPoint(x: 319, y: 605), control: CGPoint(x: 299, y: 686))
        path.addQuadCurve(to: CGPoint(x: 391, y: 475), control: CGPoint(x: 350, y: 514))
        path.addQuadCurve(to: CGPoint(x: 395, y: 418), control: CGPoint(x: 410, y: 445))
        path.closeSubpath()
        return path
    }

    /// Viewer-right sleeve and palm use the same untouched master coordinates.
    /// The contour follows the outside of its fingers and thumb and retains
    /// cuff overlap; no independently translated hand can expose a wrist gap.
    static var viewerRightArmPath: Path {
        var path = Path()
        path.move(to: CGPoint(x: 860, y: 418))
        path.addQuadCurve(to: CGPoint(x: 935, y: 420), control: CGPoint(x: 897, y: 401))
        path.addCurve(to: CGPoint(x: 1160, y: 695), control1: CGPoint(x: 1020, y: 445), control2: CGPoint(x: 1111, y: 574))
        path.addCurve(to: CGPoint(x: 1104, y: 1060), control1: CGPoint(x: 1226, y: 797), control2: CGPoint(x: 1240, y: 1006))
        path.addQuadCurve(to: CGPoint(x: 989, y: 1089), control: CGPoint(x: 1046, y: 1101))
        path.addQuadCurve(to: CGPoint(x: 947, y: 1032), control: CGPoint(x: 951, y: 1080))
        path.addQuadCurve(to: CGPoint(x: 886, y: 1055), control: CGPoint(x: 915, y: 1057))
        path.addQuadCurve(to: CGPoint(x: 809, y: 1072), control: CGPoint(x: 847, y: 1071))
        path.addQuadCurve(to: CGPoint(x: 750, y: 1046), control: CGPoint(x: 774, y: 1067))
        path.addQuadCurve(to: CGPoint(x: 715, y: 1013), control: CGPoint(x: 723, y: 1032))
        path.addQuadCurve(to: CGPoint(x: 717, y: 990), control: CGPoint(x: 702, y: 997))
        path.addQuadCurve(to: CGPoint(x: 707, y: 970), control: CGPoint(x: 702, y: 979))
        path.addQuadCurve(to: CGPoint(x: 748, y: 954), control: CGPoint(x: 711, y: 945))
        path.addQuadCurve(to: CGPoint(x: 790, y: 943), control: CGPoint(x: 743, y: 926))
        path.addQuadCurve(to: CGPoint(x: 847, y: 945), control: CGPoint(x: 818, y: 951))
        path.addQuadCurve(to: CGPoint(x: 859, y: 918), control: CGPoint(x: 862, y: 939))
        // Follow the real thumb and thumbnail. The old broad arch carried a
        // plum crescent onto the blouse when this palm rotated inward.
        path.addQuadCurve(to: CGPoint(x: 861, y: 902), control: CGPoint(x: 858, y: 907))
        path.addQuadCurve(to: CGPoint(x: 859, y: 895), control: CGPoint(x: 861, y: 899))
        path.addQuadCurve(to: CGPoint(x: 851, y: 890), control: CGPoint(x: 855, y: 892))
        path.addQuadCurve(to: CGPoint(x: 845, y: 886), control: CGPoint(x: 848, y: 888))
        path.addQuadCurve(to: CGPoint(x: 832, y: 861), control: CGPoint(x: 832, y: 877))
        path.addQuadCurve(to: CGPoint(x: 837, y: 842), control: CGPoint(x: 831, y: 849))
        path.addQuadCurve(to: CGPoint(x: 846, y: 839), control: CGPoint(x: 841, y: 837))
        path.addQuadCurve(to: CGPoint(x: 863, y: 852), control: CGPoint(x: 852, y: 842))
        path.addQuadCurve(to: CGPoint(x: 888, y: 861), control: CGPoint(x: 875, y: 859))
        path.addQuadCurve(to: CGPoint(x: 910, y: 865), control: CGPoint(x: 900, y: 864))
        path.addQuadCurve(to: CGPoint(x: 960, y: 891), control: CGPoint(x: 936, y: 878))
        path.addQuadCurve(to: CGPoint(x: 956, y: 797), control: CGPoint(x: 955, y: 856))
        path.addQuadCurve(to: CGPoint(x: 928, y: 605), control: CGPoint(x: 950, y: 686))
        path.addQuadCurve(to: CGPoint(x: 865, y: 475), control: CGPoint(x: 900, y: 514))
        path.closeSubpath()
        return path
    }
}
#endif
