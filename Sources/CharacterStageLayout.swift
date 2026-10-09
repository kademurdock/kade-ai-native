import Foundation

/// Portrait sizes leave room for the surrounding controls. The call uses its
/// actual window, while chat's pinned inset uses text and size-class signals
/// without adding another measuring pass to its sensitive composer layout.
enum CharacterStageLayout {
    static func callSide(width: Double, height: Double, accessibilityText: Bool) -> Double {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return 104 }
        let preferred = accessibilityText ? 104.0 : (height < 700 ? 132.0 : (height < 860 ? 160.0 : 208.0))
        // 32 points of page padding plus the portrait's 40-point frame.
        return max(0, min(preferred, width - 72))
    }

    static func chatSide(height: Double, keyboard: Bool, compactHeight: Bool,
                         accessibilityText: Bool) -> Double {
        if keyboard || compactHeight { return 84 }
        if accessibilityText { return 104 }
        guard height.isFinite, height > 0 else { return 132 }
        return height < 700 ? 132 : (height < 860 ? 176 : 208)
    }
}
