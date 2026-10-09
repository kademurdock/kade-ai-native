import Foundation

/// Della's original 414-pixel portrait panel remains the only source of face RGB.
/// The independently registered generated extraction contributes alpha only.
enum CharacterDellaBustGeometry {
    static let artwork = CharacterBustArtwork(
        bodyAsset: "CharacterDellaBustBody", maskAsset: "CharacterDellaBustMask",
        bodyX: -132, bodyY: -1, bodyWidth: 677.16, bodyHeight: 677.16,
        cropX: 0, cropY: 0, cropSide: 414,
        panelX: 0, panelY: 0, panelSide: 414,
        neckX: 219, neckY: 306, waistX: 207, waistY: 454,
        faceCore: CharacterBustFaceCore(x: 219, y: 193, radiusX: 73, radiusY: 91),
        headOutline: .dellaHead, accessoryOutlines: [],
        motionLimits: CharacterBustMotionLimits(headDegrees: 1.55, bodyDegrees: 0.16,
            headOffsetPixels: 0.65, bodyOffsetPixels: 0),
        maskPlacement: CharacterBustMaskPlacement(x: 35, y: 0, side: 350))
}

#if canImport(SwiftUI) && !CHARACTER_MODEL_TESTS
import SwiftUI

extension CharacterDellaBustGeometry {
    /// The matte already isolates her curls, earrings and neck. A second traced
    /// silhouette would remove original detail without improving registration.
    static var headPath: Path {
        Path(CGRect(x: 0, y: 0, width: 414, height: 414))
    }
}
#endif
