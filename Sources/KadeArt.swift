import SwiftUI
import UIKit

// MARK: - Part 292 (Sep 25 2026): Kade's painted pictures
//
// Her rule above every other: "DON'T MESS WITH BLIND ACCESS." So, for every
// picture drawn through this file:
// - It takes no touches and never holds anything focusable.
// - A picture that heads a screen may say its words (KadeArtWords, each one
//   written blind and checked against the finished picture) as ONE VoiceOver
//   element sorted after everything else on that screen: the first control is
//   still the first thing VoiceOver reaches, and no existing stop moves. The
//   screen's stack carries `.accessibilityElement(children: .contain)` so the
//   sort holds. Busy paths (the Talk tab, list rows, cards, empty states) keep
//   their pictures silent; Help's "What the app looks like" has every
//   picture's words in one place.
// - Settings, Accessibility: "Painted pictures" shows them, "Describe
//   pictures" lets VoiceOver find their words. Both start on.
// - High contrast (the app's own switch or iOS Increase Contrast) swaps every
//   picture for plain colour. Accessibility text sizes and landscape shrink
//   banners to 60 points so the task keeps the screen. Smart Invert leaves the
//   paintings alone.
// - Nothing here moves, so there is nothing for Reduce Motion to stop.
// - The pictures ship inside the app (about 10 MB, made by dev/make-art.py
//   from the originals in the project folder); nothing is downloaded.

enum KadeArt {
    static let showKey = "kade.art.show"
    static let describeKey = "kade.art.describe"

    /// The words for a picture, or nil when it has none (it then stays silent).
    static func words(for name: String) -> String? {
        KadeArtWords.all[name]
    }

    /// The house on the hill for today's season: autumn evening from the
    /// September equinox, winter night from the December solstice, a spring
    /// morning from late March and a summer night from late June.
    static func seasonalHouse(on date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        let monthDay = (parts.month ?? 1) * 100 + (parts.day ?? 1)
        switch monthDay {
        case 320..<621: return "ArtHouseSpring"
        case 621..<922: return "ArtHouseSummer"
        case 922..<1221: return "ArtHouseAutumn"
        default: return "ArtHouseWinter"
        }
    }

    /// A character's own room, for the first-chat welcome (silent there).
    /// Skylee's Lilly shares the public Lilly's room.
    static func home(for agentID: String?) -> String? {
        switch CharacterMotion.rigID(agentID) {
        case CharacterMotion.kianaID: return "ArtHomeKiana"
        case CharacterMotion.harleyID: return "ArtHomeHarley"
        case CharacterMotion.dellaID: return "ArtHomeDella"
        case CharacterMotion.lillyID: return "ArtHomeLilly"
        case CharacterMotion.witherspoonID: return "ArtHomeWitherspoon"
        default: return nil
        }
    }

    /// The small card beside some of Help's section headings (silent).
    static func helpCard(for section: String) -> String? {
        switch section {
        case "Chatting": return "ArtCardTalk"
        case "The Library": return "ArtCardLibrary"
        case "Described video": return "ArtCardWatch"
        case "My Creations and the Wall of Fame": return "ArtCardBooth"
        case "Games, Matchmaker, and Game Room": return "ArtCardReverie"
        case "Kade's Clubhouse": return "ArtCardClubhouse"
        default: return nil
        }
    }

    /// Where each picture appears, in the order Help reads them out ("What
    /// the app looks like"), each with a short name. Every name here has words.
    static let tour: [KadeArtStop] = [
        KadeArtStop(place: "Signing in: the house on the hill, which changes with the seasons", pictures: [
            ("Autumn", "ArtHouseAutumn"), ("Winter", "ArtHouseWinter"),
            ("Spring", "ArtHouseSpring"), ("Summer", "ArtHouseSummer"),
        ]),
        KadeArtStop(place: "The What's new card", pictures: [("The house at dusk", "ArtHouseAtDusk")]),
        KadeArtStop(place: "Talk, before your first conversation", pictures: [("The kitchen table", "ArtTalkKitchen")]),
        KadeArtStop(place: "A new chat, above Say hello: each character's own room", pictures: [
            ("Kiana", "ArtHomeKiana"), ("Harley", "ArtHomeHarley"), ("Della", "ArtHomeDella"),
            ("Lilly", "ArtHomeLilly"), ("Mrs. Witherspoon", "ArtHomeWitherspoon"),
        ]),
        KadeArtStop(place: "Choosing a character, above Characters with moving faces", pictures: [("The house of five lit windows", "ArtCastWindows")]),
        KadeArtStop(place: "Help, beside some section headings", pictures: [
            ("Chatting", "ArtCardTalk"), ("The Library", "ArtCardLibrary"), ("Described video", "ArtCardWatch"),
            ("My Creations", "ArtCardBooth"), ("Games", "ArtCardReverie"), ("Kade's Clubhouse", "ArtCardClubhouse"),
        ]),
        KadeArtStop(place: "Making a described video", pictures: [("The projection booth", "ArtDescriberBooth")]),
        KadeArtStop(place: "Kade's Clubhouse", pictures: [
            ("Choosing a room", "ArtClubhouseLounge"), ("In a room", "ArtClubhouseMusicNight"),
            ("Hotel rooms", "ArtClubhouseHotel"), ("When no rooms are open", "ArtEmptyFireside"),
        ]),
        KadeArtStop(place: "The Parlor", pictures: [("Game night", "ArtClubhouseGameNight")]),
        KadeArtStop(place: "Settings", pictures: [("The mudroom", "ArtSettingsMudroom")]),
        KadeArtStop(place: "Help", pictures: [("The front porch", "ArtHelpPorch")]),
        KadeArtStop(place: "App icons, in Settings", pictures: [("Brass braille K", "ArtIconBrailleK"), ("Lit windows", "ArtIconWindows")]),
    ]
}

/// One place in Help's "What the app looks like": where, and the pictures
/// there, each with a short name.
struct KadeArtStop: Identifiable {
    let place: String
    let pictures: [(label: String, name: String)]
    var id: String { place }
}

/// A picture in an empty state: a cut-out (the empty shelf, the card-catalog
/// drawer, the fireside) sits whole on the background; a room (`rounded`)
/// fills a rounded frame. Always silent: the words beside it already say what
/// the screen means. With pictures off, under high contrast or at
/// accessibility text sizes, the SF Symbol it replaced comes back at its old
/// size.
struct KadeArtSpot: View {
    let imageName: String
    /// nil: nothing at all when the picture steps aside.
    let fallbackSymbol: String?
    var width: CGFloat = 140
    var height: CGFloat = 140
    var rounded: Bool = false
    var fallbackSize: CGFloat = 52
    @KadeContrastPolicy private var highContrast: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(KadeArt.showKey) private var showPictures = true

    private var picture: UIImage? {
        guard showPictures, !highContrast, !typeSize.isAccessibilitySize else { return nil }
        return UIImage(named: imageName)
    }

    var body: some View {
        Group {
            if let picture {
                if rounded {
                    Color.clear
                        .frame(maxWidth: width)
                        .frame(height: height)
                        .overlay {
                            Image(uiImage: picture)
                                .resizable()
                                .scaledToFill()
                                .accessibilityIgnoresInvertColors(true)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFit()
                        .frame(width: width, height: height)
                        .accessibilityIgnoresInvertColors(true)
                }
            } else if let fallbackSymbol {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: fallbackSize))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
