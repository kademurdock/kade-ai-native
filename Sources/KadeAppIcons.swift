import Foundation

/// Sep 23 2026 redesign (C1, "pick your app icon"). The pictures a person can
/// put on their home screen for Kade-AI, chosen in Settings, App icon. Holly
/// can have Harley on her home screen.
///
/// Each character icon is its own app icon set in Assets.xcassets
/// (`AppIcon-Kiana.appiconset` and friends): the smile panel of that
/// character's face sheet, cropped square around the face, 1024 px, RGB with
/// no alpha. project.yml's ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS
/// makes Xcode compile every set and write CFBundleAlternateIcons itself, so
/// the set's name IS the name `UIApplication.setAlternateIconName` takes.
/// Classic is the primary icon (AppIcon), which iOS calls `nil`.
///
/// Adding a character icon = a new AppIcon-<Name>.appiconset + one case here.
///
/// Part 292 (Sep 25 2026): two painted icons join them, both the braille K
/// (dots 1 and 3 of the six-dot cell): brass dots pressed into navy leather,
/// and a dark house whose lit windows make the same two dots. The set's words
/// are in KadeArtWords under the thumbnail's name.
enum KadeAppIcon: String, CaseIterable, Identifiable {
    case classic, kiana, harley, della, lilly, brailleK, windows

    var id: String { rawValue }

    /// What the row shows, and says: "Kiana app icon".
    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .kiana: return "Kiana"
        case .harley: return "Harley"
        case .della: return "Della"
        case .lilly: return "Lilly"
        case .brailleK: return "Brass braille K"
        case .windows: return "Lit windows"
        }
    }

    /// The app icon set's name, which is the name iOS knows the icon by.
    /// `nil` is the primary icon (the classic K).
    var alternateIconName: String? {
        switch self {
        case .classic: return nil
        case .kiana: return "AppIcon-Kiana"
        case .harley: return "AppIcon-Harley"
        case .della: return "AppIcon-Della"
        case .lilly: return "AppIcon-Lilly"
        case .brailleK: return "AppIcon-BrailleK"
        case .windows: return "AppIcon-Windows"
        }
    }

    /// Whose face the icon shows, for the Settings row's thumbnail. `nil` for
    /// Classic.
    var agentID: String? {
        switch self {
        case .classic: return nil
        case .kiana: return CharacterMotion.kianaID
        case .harley: return CharacterMotion.harleyID
        case .della: return CharacterMotion.dellaID
        case .lilly: return CharacterMotion.lillyID
        case .brailleK, .windows: return nil
        }
    }

    /// The painted icons' Settings thumbnail (an image set in the app).
    var thumbnailName: String? {
        switch self {
        case .brailleK: return "ArtIconBrailleK"
        case .windows: return "ArtIconWindows"
        default: return nil
        }
    }

    /// What choosing it does, said as the row's hint.
    var hint: String {
        switch self {
        case .classic: return "Puts the classic K back on your home screen."
        case .brailleK: return "Puts the letter K in braille on your home screen: two brass dots, 1 and 3, pressed into navy leather."
        case .windows: return "Puts a house at night on your home screen, its two lit windows making the braille K, dots 1 and 3."
        default: return "Puts \(displayName)'s face on your home screen."
        }
    }

    /// The choice matching what iOS reports as the current icon
    /// (`UIApplication.shared.alternateIconName`). A name this list doesn't
    /// know reads as Classic.
    static func matching(alternateIconName name: String?) -> KadeAppIcon {
        allCases.first { $0.alternateIconName == name } ?? .classic
    }
}
