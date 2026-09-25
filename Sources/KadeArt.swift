import SwiftUI
import UIKit
import MediaPlayer

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
        KadeArtStop(place: "The Library's shelves, under Browse", pictures: [
            ("Books", "ArtShelfBooks"), ("Audiobooks", "ArtShelfAudiobooks"),
            ("Cassettes", "ArtShelfCassettes"), ("Radio", "ArtShelfRadio"),
            ("Music", "ArtShelfMusic"), ("Movies", "ArtShelfMovies"),
            ("Home movies", "ArtShelfFamily"), ("Missouri and the Ozarks", "ArtShelfMissouri"),
        ]),
        KadeArtStop(place: "The Library's Springfield and Ozarks shelves", pictures: [
            ("Local news", "ArtOzarksNews"), ("Weather", "ArtOzarksWeather"),
            ("Local sports", "ArtOzarksSports"), ("Local commercials and breaks", "ArtOzarksCommercials"),
            ("Station IDs and sign-offs", "ArtOzarksStationIDs"), ("Promos", "ArtOzarksPromos"),
            ("Around the Ozarks", "ArtOzarksRiver"), ("Local radio", "ArtOzarksRadio"),
        ]),
        KadeArtStop(place: "The Library: an item with no picture of its own", pictures: [
            ("Books", "ArtJacketBook"), ("Audiobooks", "ArtJacketAudiobook"),
            ("Movies", "ArtJacketMovie"), ("TV and home video", "ArtJacketTV"),
            ("Commercials", "ArtJacketCommercials"), ("Radio", "ArtJacketRadio"), ("Music", "ArtJacketMusic"),
        ]),
        KadeArtStop(place: "The Library player: a tape with the title written on its label", pictures: [
            ("Cassettes", "ArtTapeCassette"), ("Television, movies and commercials", "ArtTapeVHS"),
            ("Radio", "ArtTapeReel"),
        ]),
        KadeArtStop(place: "The Library: empty shelves, searches and waits", pictures: [
            ("Nothing on your shelf yet", "ArtEmptyShelf"), ("A search that found nothing", "ArtEmptySearch"),
            ("Uploading, or waiting for recordings", "ArtBookCart"),
        ]),
        KadeArtStop(place: "Library radio on the lock screen", pictures: [("The glowing radio", "ArtNowPlayingRadio")]),
        KadeArtStop(place: "Making a described video", pictures: [("The projection booth", "ArtDescriberBooth")]),
        KadeArtStop(place: "Kade's Clubhouse", pictures: [
            ("Choosing a room", "ArtClubhouseLounge"), ("The Porch", "ArtClubhousePorch"),
            ("Game Night", "ArtClubhouseGameNight"), ("Music Night", "ArtClubhouseMusicNight"),
            ("Hotel rooms", "ArtClubhouseHotel"), ("When no rooms are open", "ArtEmptyFireside"),
        ]),
        KadeArtStop(place: "The Parlor", pictures: [("Game night", "ArtClubhouseGameNight")]),
        KadeArtStop(place: "Settings", pictures: [("The mudroom", "ArtSettingsMudroom")]),
        KadeArtStop(place: "Help", pictures: [("The front porch", "ArtHelpPorch")]),
        KadeArtStop(place: "Help, beside some section headings", pictures: [
            ("Chatting", "ArtCardTalk"), ("The Library", "ArtCardLibrary"), ("Described video", "ArtCardWatch"),
            ("My Creations", "ArtCardBooth"), ("Games", "ArtCardReverie"), ("Kade's Clubhouse", "ArtCardClubhouse"),
        ]),
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

// MARK: - The Library (Part 292, second batch)
//
// Same rules as everything above. Every Library picture is silent: the shelf
// bands are List rows with nothing in them for VoiceOver (like the reading
// alcove), jackets sit inside rows whose one label is unchanged, the tape
// repeats a title already on the screen, and the lock-screen picture is not
// on a screen at all. Help's "What the app looks like" carries their words.

/// True while painted pictures may show: the "Painted pictures" switch is on
/// and neither high-contrast setting is. For call sites that must leave a
/// picture out entirely (a List row, or a spot where nothing stood before)
/// rather than draw a stand-in.
@propertyWrapper
struct KadeArtShown: DynamicProperty {
    @KadeContrastPolicy private var highContrast: Bool
    @AppStorage(KadeArt.showKey) private var showPictures = true

    var wrappedValue: Bool { showPictures && !highContrast }
}

extension KadeArt {
    /// The painted shelf over an archive folder, found by the words in its
    /// path. The archive files by medium, then shelf, then decade ("Audio/
    /// Radio Airchecks/1970s", "Video/Ozarks (Springfield Area)/Local News/
    /// 1980s"), so the shelf is the second part. Nil for a folder nobody
    /// painted: it simply has no picture.
    static func shelfPicture(forArchivePath path: String) -> String? {
        let parts: [String] = path.split(separator: "/").map { $0.lowercased() }
        guard let medium = parts.first else { return nil }
        // Springfield and the Ozarks first: her own local trees (Video and
        // Audio) and Missouri's "Springfield & Ozarks" branch.
        if let root = parts.firstIndex(where: { isOzarksFolder($0) }) {
            if medium == "audio" { return "ArtOzarksRadio" }
            guard root + 1 < parts.count else { return "ArtShelfMissouri" }
            return ozarksPicture(forKind: parts[root + 1])
        }
        if medium == "books" { return "ArtShelfBooks" }
        guard parts.count > 1 else { return nil }
        let shelf = folderWords(parts[1])
        if shelf.contains("missouri") { return "ArtShelfMissouri" }
        if shelf.contains("audiobook") || shelf.contains("audiobooks") { return "ArtShelfAudiobooks" }
        if shelf.contains("cassette") || shelf.contains("cassettes") { return "ArtShelfCassettes" }
        if shelf.contains("radio") { return "ArtShelfRadio" }
        if shelf.contains("music") { return "ArtShelfMusic" }
        if shelf.contains("family") || (parts.count > 2 && parts[2] == "home movies") { return "ArtShelfFamily" }
        if shelf.contains("movies") || shelf.contains("movie") { return "ArtShelfMovies" }
        return nil
    }

    /// Springfield's local shelves, the kinds between the Ozarks root and the
    /// decade (Local News, Weather, Local Sports, Local Commercials,
    /// Commercial Breaks, Station IDs & Sign-offs, Show Promos, Promo Reels,
    /// Around the Ozarks), by keyword. A kind nobody painted gets no picture.
    static func ozarksPicture(forKind kind: String) -> String? {
        let k = kind.lowercased()
        let w = folderWords(k)
        if w.contains("news") { return "ArtOzarksNews" }
        if w.contains("weather") { return "ArtOzarksWeather" }
        if k.contains("sport") { return "ArtOzarksSports" }
        if k.contains("commercial") || w.contains("ads") { return "ArtOzarksCommercials" }
        if k.contains("station id") || k.contains("sign-off") || k.contains("sign-on") { return "ArtOzarksStationIDs" }
        if k.contains("promo") { return "ArtOzarksPromos" }
        if k.contains("around the ozarks") { return "ArtOzarksRiver" }
        return nil
    }

    /// The painted jacket for a Library item with no picture of its own, by
    /// what it is (the server's categories). Cassettes and "other" recordings
    /// have none and keep the drawn jacket.
    static func jacket(kind: String, category: String) -> String? {
        if kind == "text" { return "ArtJacketBook" }
        switch category {
        case "audiobook": return "ArtJacketAudiobook"
        case "movie": return "ArtJacketMovie"
        case "tv", "vhs": return "ArtJacketTV"
        case "commercials", "psa": return "ArtJacketCommercials"
        case "radio": return "ArtJacketRadio"
        case "music": return "ArtJacketMusic"
        default: return kind == "video" ? "ArtJacketTV" : nil
        }
    }

    /// The tape a recording came on, for the player: cassettes on a cassette,
    /// radio in a reel-to-reel box, television, movies, home video and
    /// commercials on a videotape. Audiobooks, music and the rest have none
    /// (their jacket sits beside the title instead).
    static func tape(category: String) -> String? {
        switch category {
        case "cassette": return "ArtTapeCassette"
        case "radio": return "ArtTapeReel"
        case "movie", "tv", "vhs", "commercials", "psa": return "ArtTapeVHS"
        default: return nil
        }
    }

    /// The lock screen's picture for a Library item: the glowing old radio
    /// for radio, the item's jacket for everything else.
    static func lockScreenPicture(kind: String, category: String) -> String? {
        category == "radio" ? "ArtNowPlayingRadio" : jacket(kind: kind, category: category)
    }

    /// Lock-screen artwork that loads its picture only when the system asks
    /// for it, so the title and position never wait on it. Made here, off
    /// the main actor, because MediaPlayer calls the closure on its own
    /// queue (UIImage(named:) is safe there). The sizes are the pictures'
    /// own (dev/make-art.py): the radio is 800 square, the jackets 400 by 600.
    static func lockScreenArtwork(named name: String) -> MPMediaItemArtwork {
        let bounds = name == "ArtNowPlayingRadio" ? CGSize(width: 800, height: 800) : CGSize(width: 400, height: 600)
        return MPMediaItemArtwork(boundsSize: bounds) { _ in
            UIImage(named: name) ?? UIImage()
        }
    }

    private static func isOzarksFolder(_ folder: String) -> Bool {
        folder.hasPrefix("ozarks") || (folder.contains("springfield") && folder.contains("ozarks"))
    }

    /// "Radio Airchecks" gives radio and airchecks, so "Radiology" is not radio.
    private static func folderWords(_ folder: String) -> Set<String> {
        let pieces = folder.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return Set(pieces.map { String($0) })
    }
}

/// A small painted picture filling a rounded frame: an item's jacket beside
/// its title. The frame is fixed before anything loads, so nothing moves.
/// Silent and untouchable; the call site decides whether pictures show.
struct KadeArtThumb: View {
    let imageName: String
    var width: CGFloat = 48
    var height: CGFloat = 72

    var body: some View {
        Color.clear
            .frame(width: width, height: height)
            .overlay {
                if let picture = UIImage(named: imageName) {
                    Image(uiImage: picture)
                        .resizable()
                        .scaledToFill()
                        .accessibilityIgnoresInvertColors(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// A tape cut-out (a cassette, a videotape, a reel-to-reel box) with a title
/// written by code on its blank label, as if by hand. Silent and untouchable:
/// the same title is on the screen as text, and VoiceOver reads it there. The
/// ink stays dark on the cream label in dark mode and under Smart Invert. The
/// call site decides whether pictures show.
struct KadeTapeLabel: View {
    let imageName: String
    let title: String

    /// Each picture's blank label as fractions of the picture, measured from
    /// the PNGs (the pale rectangle, pulled in a little from its edges): the
    /// cassette's writing strip above its window, the videotape's centre
    /// label clear of its peeling corner, and the card on the reel box.
    private var labelArea: CGRect {
        switch imageName {
        case "ArtTapeCassette": return CGRect(x: 0.18, y: 0.205, width: 0.64, height: 0.16)
        case "ArtTapeVHS": return CGRect(x: 0.335, y: 0.41, width: 0.31, height: 0.27)
        default: return CGRect(x: 0.30, y: 0.42, width: 0.40, height: 0.24)
        }
    }

    /// The reel box is square, so it stands a little taller than the others.
    private var height: CGFloat { imageName == "ArtTapeReel" ? 190 : 160 }

    var body: some View {
        if let picture = UIImage(named: imageName) {
            tape(picture)
                .accessibilityIgnoresInvertColors(true)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }

    private func tape(_ picture: UIImage) -> some View {
        let aspect: CGFloat = picture.size.height > 0 ? picture.size.width / picture.size.height : 1
        return Image(uiImage: picture)
            .resizable()
            .scaledToFit()
            .frame(width: height * aspect, height: height)
            .overlay {
                GeometryReader { geo in
                    writing(in: geo.size)
                }
            }
    }

    private func writing(in size: CGSize) -> some View {
        let area = labelArea
        let boxWidth = size.width * area.width
        let boxHeight = size.height * area.height
        return Text(title)
            .font(.custom("Noteworthy-Bold", fixedSize: min(16, boxHeight * 0.45)))
            .foregroundStyle(Color(red: 0.13, green: 0.15, blue: 0.33))
            .multilineTextAlignment(.center)
            .lineLimit(imageName == "ArtTapeCassette" ? 2 : 3)
            .minimumScaleFactor(0.5)
            .frame(width: boxWidth, height: boxHeight)
            .position(x: size.width * area.midX, y: size.height * area.midY)
    }
}
