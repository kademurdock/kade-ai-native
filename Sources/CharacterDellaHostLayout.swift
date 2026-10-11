import Foundation

/// One resolved stage size is shared by the host and portrait renderer. The
/// existing square framing remains the fallback for every unapproved candidate.
struct CharacterDellaHostStage: Equatable {
    let side: Double
    let portraitHeight: Double
    let articulated: Bool

    /// CharacterPortraitView already supplies the complete 40-point chrome.
    var frameHeight: Double { portraitHeight + 40 }
}

/// Optional decoration and voice settings yield to the native editor when
/// accessibility text and limited vertical space coincide. This decision uses
/// stable window/focus inputs, never measured composer geometry.
struct CharacterDellaChatChrome: Equatable {
    let portraitVisible: Bool
    let controlsInTranscript: Bool
}

/// Stable host inputs only: no speech energy, elapsed time, interpolation or
/// composer measurement can resize the transcript's reserved portrait space.
enum CharacterDellaHostLayout {
    static func chatChrome(availableHeight: Double, accessibilityText: Bool,
                           editing: Bool, keyboardVisible: Bool) -> CharacterDellaChatChrome {
        let shortWindow = valid(availableHeight) && availableHeight < 700
        let constrained = accessibilityText && (shortWindow || editing || keyboardVisible)
        return CharacterDellaChatChrome(portraitVisible: !constrained,
                                        controlsInTranscript: constrained)
    }

    static func chat(preferredSide: Double, availableHeight: Double,
                     keyboard: Bool, editing: Bool, compactHeight: Bool,
                     accessibilityText: Bool, competingControls: Bool,
                     candidateEligible: Bool) -> CharacterDellaHostStage {
        let fallback = square(preferredSide)
        guard valid(preferredSide), valid(availableHeight), candidateEligible else { return fallback }
        if keyboard || editing || compactHeight { return square(84) }
        if accessibilityText || competingControls { return square(104) }
        return tall(preferredSide, availableHeight: availableHeight, minimumHeight: 860)
    }

    static func call(preferredSide: Double, availableHeight: Double,
                     camera: Bool, accessibilityText: Bool,
                     candidateEligible: Bool) -> CharacterDellaHostStage {
        let fallback = square(preferredSide)
        guard valid(preferredSide), valid(availableHeight), candidateEligible else { return fallback }
        if camera || accessibilityText { return square(104) }
        return tall(preferredSide, availableHeight: availableHeight, minimumHeight: 740)
    }

    private static func valid(_ value: Double) -> Bool { value.isFinite && value > 0 }

    private static func square(_ preferredSide: Double) -> CharacterDellaHostStage {
        let side = valid(preferredSide) ? preferredSide : 104
        return CharacterDellaHostStage(side: side, portraitHeight: side, articulated: false)
    }

    private static func tall(_ side: Double, availableHeight: Double,
                             minimumHeight: Double) -> CharacterDellaHostStage {
        guard side >= 160, availableHeight >= minimumHeight else { return square(side) }
        let height = CharacterDellaArticulatedGeometry.stageHeight(side: side)
        guard valid(height) else { return square(side) }
        return CharacterDellaHostStage(side: side, portraitHeight: height, articulated: true)
    }
}
