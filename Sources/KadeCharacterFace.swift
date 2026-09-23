import SwiftUI

/// Sep 23 2026 redesign (B3, "faces wherever you choose or find a character").
/// A STILL face at row size. The four characters with drawn faces show a panel
/// of their own expression sheet (the same art the chat's face stage moves);
/// everyone else shows their avatar; a name with no picture gets a coloured
/// initial.
///
/// DECORATIVE, like every picture in this app: hidden from VoiceOver, never
/// hit-tested, and always a fixed square, so a picture that arrives late can
/// never move a row (the freeze-era rule). Rows that show a face must still
/// say the character's name in their own label.
struct KadeCharacterFace: View {
    let agentID: String?
    let name: String
    var size: CGFloat = 44
    /// Drawn characters only: which face to show. `.neutral` is the resting one.
    var face: CharacterFace = .neutral
    @EnvironmentObject private var agents: AgentsService

    private var avatarPath: String? {
        guard let agentID else { return nil }
        return agents.agents.first { $0.id == agentID }?.avatar?.filepath
    }

    /// The drawn sheet is shown for the four known ids unless the roster says
    /// the avatar has changed (then the sheet no longer matches the picture).
    private var drawn: KadeCharacterFaceSheet? {
        guard let sheet = KadeCharacterFaceSheet.forAgent(agentID) else { return nil }
        if let path = avatarPath, !CharacterMotion.prepared(id: agentID, path: path) { return nil }
        return sheet
    }

    private var avatarURL: URL? {
        guard let path = avatarPath, !path.isEmpty else { return nil }
        return URL(string: path.hasPrefix("/") ? "https://kademurdock.com" + path : path)
    }

    var body: some View {
        ZStack {
            content
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var content: some View {
        if let drawn {
            drawn.panel(face, side: size)
        } else if let avatarURL {
            AsyncImage(url: avatarURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    monogram
                }
            }
        } else {
            monogram
        }
    }

    /// A coloured initial, or, when the name isn't known (a removed character,
    /// the roster still loading), a plain grey chat bubble instead of a blank
    /// coloured tile.
    @ViewBuilder private var monogram: some View {
        let initial = String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        if initial.isEmpty {
            ZStack {
                Color(.systemGray4)
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
        } else {
            ZStack {
                Color(hue: KadeCharacterFace.hue(for: name), saturation: 0.5, brightness: 0.78)
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    /// Same deterministic hue as `KadeSpeakerMonogram`, so a name keeps its
    /// colour on every screen.
    static func hue(for name: String) -> Double {
        var h = 5381
        for scalar in name.unicodeScalars {
            h = (h &* 33) &+ Int(scalar.value)
        }
        return Double(abs(h % 360)) / 360.0
    }
}

/// Where a drawn character's sheets live in the asset catalog. The faces sheet
/// holds panels 0-8 (`CharacterFace` neutral…closed); the nuance sheet holds the
/// later faces (curious…delighted) at `rawValue - 8`. 1254 px sheets, 414 px
/// panels on a 420 px pitch — the same cut `CharacterPortraitView.panel` makes.
struct KadeCharacterFaceSheet {
    let faces: String
    let nuance: String

    static func forAgent(_ id: String?) -> KadeCharacterFaceSheet? {
        switch id {
        case CharacterMotion.kianaID: return KadeCharacterFaceSheet(faces: "CharacterKianaFaces", nuance: "CharacterKianaNuance")
        case CharacterMotion.dellaID: return KadeCharacterFaceSheet(faces: "CharacterDellaFaces", nuance: "CharacterDellaNuance")
        case CharacterMotion.lillyID: return KadeCharacterFaceSheet(faces: "CharacterLillyFaces", nuance: "CharacterLillyNuance")
        case CharacterMotion.harleyID: return KadeCharacterFaceSheet(faces: "CharacterHarleyFaces", nuance: "CharacterHarleyNuance")
        default: return nil
        }
    }

    func panel(_ face: CharacterFace, side: CGFloat) -> some View {
        let raw = face.rawValue
        let image = raw < 9 ? faces : nuance
        let index = raw < 9 ? raw : raw - 8
        let sheetSide = side * 1254.0 / 414.0
        let pitch = side * 420.0 / 414.0
        return Image(image)
            .resizable()
            .frame(width: sheetSide, height: sheetSide)
            .offset(x: -CGFloat(index % 3) * pitch, y: -CGFloat(index / 3) * pitch)
            .frame(width: side, height: side, alignment: .topLeading)
            .clipped()
    }
}
