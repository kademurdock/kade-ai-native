import SwiftUI

/// Shared by saved replies and the streaming reply. Only this small decorative
/// subtree updates; transcript text and VoiceOver focus never update per frame.
struct CharacterPortraitView: View {
    let agentID: String?
    let name: String
    let playing: Bool
    let level: () -> Double
    var listening = false
    var presentation: () -> CharacterPresentation = { .idle }
    /// Sep 20 2026 (Kade: her mom "barely notices a profile pic", "I want the
    /// animations to be very very apparent"): the stage is the always-on face at
    /// the top of a conversation. It keeps blinking and swaying while nobody is
    /// talking, and its movement is drawn several times larger than a row's.
    var stage = false
    var side = 160.0
    @EnvironmentObject private var agents: AgentsService
    @Environment(\.scenePhase) private var scenePhase
    @KadeMotionPolicy(permitsVoiceOver: true) private var motionAllowed: Bool
    @AppStorage("kadeVoicePortraits") private var enabled = true
    @State private var visible = false

    private var path: String? { agents.agents.first { $0.id == agentID }?.avatar?.filepath }
    private var prepared: Bool { CharacterMotion.prepared(id: agentID, path: path) }
    private var active: Bool { enabled && motionAllowed && scenePhase == .active && visible && (playing || listening || stage) }
    private var url: URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: path.hasPrefix("/") ? "https://kademurdock.com" + path : path)
    }
    var body: some View {
        if enabled {
            TimelineView(.animation(minimumInterval: 1.0 / (playing ? 24.0 : 12.0), paused: !active)) { timeline in
                let performance = active ? presentation() : .idle
                let pose = CharacterMotion.pose(id: agentID ?? "unknown",
                    time: timeline.date.timeIntervalSinceReferenceDate,
                    level: active && playing ? level() : 0, active: active, presentation: performance)
                // Facial expression and individual gestures carry the performance;
                // the larger stage adds a little reach without amplifying it sixfold.
                let reach = stage ? 1.6 : 1.0
                let voice = active && playing ? pose.mouth : 0
                ZStack {
                    RoundedRectangle(cornerRadius: 24).fill(Color.accentColor.opacity(0.08))
                    if stage {
                        RoundedRectangle(cornerRadius: 26)
                            .stroke(Color.accentColor.opacity(playing ? 0.45 + voice * 0.55 : 0.2), lineWidth: playing ? 4 + voice * 9 : 2)
                            .shadow(color: Color.accentColor.opacity(voice), radius: 4 + voice * 14)
                    }
                    portrait(pose, face: performance.face)
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .scaleEffect(active ? pose.scale : 1)
                        .rotationEffect(.degrees(pose.tilt * reach))
                        .offset(y: pose.lift * reach)
                }
                .frame(width: side + 12, height: side + 12)
                .padding(stage ? 14 : 0)
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .task { await agents.loadIfNeeded() }
        }
    }
    /// Sep 19 2026: expression sheets (art by Kade through ChatGPT image
    /// generation). Each character has two 3 by 3 sheets made as ONE image each,
    /// so all nine panels share a pose: nine faces and nine mouth shapes, 1254 px
    /// with 414 px panels on a 420 px pitch. The sheet's own resting panel is the
    /// base; only feathered regions are laid over it (the brow-to-chin oval of
    /// the face the direction calls for, a mouth shape while talking, the eye
    /// region of the closed-eyes panel for a blink), so hair, jewelry and the
    /// room never shimmer. Same regions as the web's portrait-rig.mjs SHEETS.
    private struct Sheet {
        let faces: String, mouths: String
        let face: CGRect, mouth: CGRect, eyes: CGRect
    }
    private var nuanceAsset: String {
        switch agentID {
        case CharacterMotion.kianaID: return "CharacterKianaNuance"
        case CharacterMotion.dellaID: return "CharacterDellaNuance"
        case CharacterMotion.lillyID: return "CharacterLillyNuance"
        default: return "CharacterHarleyNuance"
        }
    }
    private var sheet: Sheet? {
        guard prepared else { return nil }
        if agentID == CharacterMotion.witherspoonID {
            return Sheet(faces: "CharacterWitherspoonFaces", mouths: "CharacterWitherspoonMouths",
                face: CGRect(x: 0.29, y: 0.23, width: 0.44, height: 0.49), mouth: CGRect(x: 0.38, y: 0.50, width: 0.26, height: 0.19), eyes: CGRect(x: 0.30, y: 0.32, width: 0.41, height: 0.15))
        }
        if agentID == CharacterMotion.kianaID {
            return Sheet(faces: "CharacterKianaFaces", mouths: "CharacterKianaMouths",
                face: CGRect(x: 0.34, y: 0.17, width: 0.5, height: 0.56), mouth: CGRect(x: 0.43, y: 0.46, width: 0.31, height: 0.2), eyes: CGRect(x: 0.36, y: 0.27, width: 0.44, height: 0.15))
        }
        if agentID == CharacterMotion.dellaID {
            return Sheet(faces: "CharacterDellaFaces", mouths: "CharacterDellaMouths",
                face: CGRect(x: 0.3, y: 0.2, width: 0.46, height: 0.56), mouth: CGRect(x: 0.38, y: 0.46, width: 0.3, height: 0.19), eyes: CGRect(x: 0.34, y: 0.29, width: 0.38, height: 0.14))
        }
        // Sep 20 2026: Harley. His two sheets were re-cut to this grid with every
        // panel moved onto the resting head (the mouth sheet sat 22 px right).
        if agentID == CharacterMotion.harleyID {
            return Sheet(faces: "CharacterHarleyFaces", mouths: "CharacterHarleyMouths",
                face: CGRect(x: 0.28, y: 0.24, width: 0.52, height: 0.5), mouth: CGRect(x: 0.41, y: 0.47, width: 0.27, height: 0.22), eyes: CGRect(x: 0.34, y: 0.31, width: 0.42, height: 0.13))
        }
        if agentID == CharacterMotion.lillyID {
            return Sheet(faces: "CharacterLillyFaces", mouths: "CharacterLillyMouths",
                face: CGRect(x: 0.38, y: 0.2, width: 0.46, height: 0.5), mouth: CGRect(x: 0.48, y: 0.48, width: 0.28, height: 0.2), eyes: CGRect(x: 0.4, y: 0.3, width: 0.42, height: 0.18))
        }
        return nil
    }
    @ViewBuilder private func portrait(_ pose: CharacterPose, face: CharacterFace) -> some View {
        if let sheet {
            let basicOnly = agentID == CharacterMotion.witherspoonID
            let shownFace = basicOnly ? face.basicSheetFace : face
            ZStack(alignment: .topLeading) {
                panel(sheet.faces, CharacterFace.neutral.rawValue)
                // Every drawn face sits ready at zero opacity so a change is a dissolve.
                ForEach(CharacterFace.allCases.filter { $0 != .neutral && $0 != .closed && (!basicOnly || $0.rawValue < 9) }, id: \.rawValue) { drawnFace in
                    let index = drawnFace.rawValue
                    feathered(panel(index < 9 ? sheet.faces : nuanceAsset, index < 9 ? index : index - 8), region: sheet.face, inner: 0.72)
                        .opacity(shownFace.rawValue == index ? 1 : 0)
                }
                .animation(active ? .easeInOut(duration: 0.45) : nil, value: face)
                // A laugh keeps its own open mouth; every other face talks with shapes.
                if pose.viseme > 0 && pose.viseme < 9 && shownFace != .laugh {
                    feathered(panel(sheet.mouths, pose.viseme), region: sheet.mouth, inner: 0.5)
                }
                feathered(panel(sheet.faces, CharacterFace.closed.rawValue), region: sheet.eyes, inner: 0.6)
                    .opacity(CharacterMotion.blend(pose.blink))
            }
        } else if let url {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { fallback }
            }
        } else { fallback }
    }
    /// One panel cut from a 3 by 3 sheet.
    private func panel(_ image: String, _ index: Int) -> some View {
        let sheetSide = side * 1254.0 / 414.0, pitch = side * 420.0 / 414.0
        return Image(image).resizable()
            .frame(width: sheetSide, height: sheetSide)
            .offset(x: -Double(index % 3) * pitch, y: -Double(index / 3) * pitch)
            .frame(width: side, height: side, alignment: .topLeading)
            .clipped()
    }
    /// Keeps only `region` of a panel, fading out toward the region's edge. The
    /// fade is drawn round at the region's height and stretched to its width.
    private func feathered<Content: View>(_ content: Content, region: CGRect, inner: Double) -> some View {
        let width = region.width * side, height = region.height * side
        return content.mask(alignment: .topLeading) {
            Circle().fill(RadialGradient(stops: [.init(color: .black, location: inner), .init(color: .clear, location: 1)],
                    center: .center, startRadius: 0, endRadius: height / 2))
                .frame(width: height, height: height)
                .scaleEffect(x: width / height, y: 1, anchor: .center)
                .frame(width: width, height: height)
                .offset(x: region.minX * side, y: region.minY * side)
        }
    }
    private var fallback: some View {
        ZStack {
            Color.accentColor.opacity(0.16)
            Text(String(name.prefix(1))).font(.system(size: side * 0.35, weight: .medium)).foregroundStyle(Color.accentColor)
        }
    }
}
