import SwiftUI
#if DEBUG && targetEnvironment(simulator)
import UIKit
#endif

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
    /// Used only by the offline simulator review. Release always ignores it.
    var reviewBust = false
    /// A local preview may pause decoration; this never overrides system policy.
    var motionPaused = false
    @EnvironmentObject private var agents: AgentsService
    @Environment(\.scenePhase) private var scenePhase
    @KadeMotionPolicy(permitsVoiceOver: true) private var motionAllowed: Bool
    @AppStorage("kadeVoicePortraits") private var enabled = true
    @State private var visible = false

    private var path: String? { agents.agents.first { $0.id == agentID }?.avatar?.filepath }
    private var prepared: Bool { CharacterMotion.prepared(id: agentID, path: path) }
    private var figureArtwork: CharacterFigureArtwork? {
        stage ? CharacterFigureArtwork.approved(agentID: agentID, avatarPath: path) : nil
    }
    private var bustArtwork: CharacterBustArtwork? {
        #if DEBUG && targetEnvironment(simulator)
        guard let artwork = CharacterBustArtwork.review(enabled: reviewBust, stage: stage,
                side: side, agentID: agentID, avatarPath: path),
              UIImage(named: artwork.bodyAsset) != nil,
              UIImage(named: artwork.maskAsset) != nil else { return nil }
        return artwork
        #else
        return nil
        #endif
    }
    private var active: Bool { enabled && !motionPaused && motionAllowed && scenePhase == .active && visible && (playing || listening || stage) }
    private var url: URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: path.hasPrefix("/") ? "https://kademurdock.com" + path : path)
    }
    var body: some View {
        if enabled {
            TimelineView(.animation(minimumInterval: 1.0 / (playing ? 24.0 : 12.0), paused: !active)) { timeline in
                let performance = active ? presentation() : .idle
                let time = timeline.date.timeIntervalSinceReferenceDate
                let outputLevel = active && playing ? level() : 0
                let pose = CharacterMotion.pose(id: agentID ?? "unknown",
                    time: time, level: outputLevel, active: active, presentation: performance)
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
                    if let artwork = bustArtwork {
                        layeredBust(artwork, pose: pose, face: performance.face,
                            motion: CharacterBustMotion.pose(CharacterFigureMotion.pose(
                                id: agentID ?? "unknown", time: time, level: outputLevel,
                                active: active, presentation: performance)))
                    } else if let artwork = figureArtwork, let sheet {
                        layeredFigure(artwork, sheet: sheet, pose: pose, face: performance.face,
                            body: CharacterFigureMotion.pose(id: agentID ?? "unknown",
                                time: time, level: outputLevel, active: active, presentation: performance))
                    } else {
                        portrait(pose, face: performance.face)
                            .frame(width: side, height: side)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .scaleEffect(active ? pose.scale : 1)
                            .rotationEffect(.degrees(pose.tilt * reach))
                            .offset(y: pose.lift * reach)
                    }
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
    /// Skylee's Lilly wears the public Lilly's sheets (CharacterMotion.rigID).
    private var rig: String? { CharacterMotion.rigID(agentID) }
    private var nuanceAsset: String {
        switch rig {
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
        if rig == CharacterMotion.lillyID {
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

    /// The full original atlas panel supplies the neutral head as well as its
    /// speaking and expression patches. Mask and cut path move with that whole
    /// composite, so a gesture cannot slide a mouth across an unmoving face.
    private func layeredBust(_ artwork: CharacterBustArtwork, pose: CharacterPose,
                            face: CharacterFace, motion: CharacterBustPose) -> some View {
        let unit = side / artwork.cropSide
        let neck = UnitPoint(x: CGFloat((artwork.neckX - artwork.cropX) / artwork.cropSide),
                             y: CGFloat((artwork.neckY - artwork.cropY) / artwork.cropSide))
        let waist = UnitPoint(x: CGFloat((artwork.waistX - artwork.cropX) / artwork.cropSide),
                              y: CGFloat((artwork.waistY - artwork.cropY) / artwork.cropSide))
        return ZStack(alignment: .topLeading) {
            Image(artwork.bodyAsset).resizable().interpolation(.high)
                .frame(width: artwork.bodyWidth * unit, height: artwork.bodyHeight * unit)
                .offset(x: -artwork.cropX * unit, y: -artwork.cropY * unit)
                .frame(width: side, height: side, alignment: .topLeading)
                .rotationEffect(.degrees(motion.bodyAngle), anchor: waist)
                .offset(y: motion.bodyOffsetY * unit)
            portrait(pose, face: face)
                .frame(width: side, height: side)
                .scaleEffect(artwork.panelSide / artwork.cropSide, anchor: .topLeading)
                .offset(x: (artwork.panelX - artwork.cropX) * unit,
                        y: (artwork.panelY - artwork.cropY) * unit)
                .frame(width: side, height: side, alignment: .topLeading)
                .mask(alignment: .topLeading) { bustMask(artwork, unit: unit) }
                .clipShape(CharacterBustHeadCut(artwork: artwork))
                .rotationEffect(.degrees(motion.headAngle), anchor: neck)
                .offset(y: motion.headOffsetY * unit)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private func bustMask(_ artwork: CharacterBustArtwork, unit: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Image(artwork.maskAsset).resizable().interpolation(.high)
                .frame(width: artwork.panelSide * unit, height: artwork.panelSide * unit)
                .offset(x: (artwork.panelX - artwork.cropX) * unit,
                        y: (artwork.panelY - artwork.cropY) * unit)
            // Exact opaque face core from the existing study: the source mask
            // feathers the hair boundary without making facial patches ghost.
            Ellipse().fill(.white)
                .frame(width: artwork.coreRadiusX * 2 * unit,
                       height: artwork.coreRadiusY * 2 * unit)
                .offset(x: (artwork.coreX - artwork.coreRadiusX - artwork.cropX) * unit,
                        y: (artwork.coreY - artwork.coreRadiusY - artwork.cropY) * unit)
        }
        .frame(width: side, height: side, alignment: .topLeading)
    }

    /// The authored head cutout and these atlas patches share one neck transform.
    /// The original photo portrait above keeps its established composition.
    private func faceDetails(_ pose: CharacterPose, face: CharacterFace, sheet: Sheet) -> some View {
        let basicOnly = agentID == CharacterMotion.witherspoonID
        let shownFace = basicOnly ? face.basicSheetFace : face
        return ZStack(alignment: .topLeading) {
            // Every drawn face sits ready at zero opacity so a change dissolves.
            ForEach(CharacterFace.allCases.filter { $0 != .neutral && $0 != .closed && (!basicOnly || $0.rawValue < 9) }, id: \.rawValue) { drawnFace in
                let index = drawnFace.rawValue
                feathered(panel(index < 9 ? sheet.faces : nuanceAsset, index < 9 ? index : index - 8), region: sheet.face, inner: 0.72)
                    .opacity(shownFace.rawValue == index ? 1 : 0)
            }
            .animation(active ? .easeInOut(duration: 0.45) : nil, value: face)
            // A laugh keeps its own open mouth; every other face uses shapes.
            if pose.viseme > 0 && pose.viseme < 9 && shownFace != .laugh {
                feathered(panel(sheet.mouths, pose.viseme), region: sheet.mouth, inner: 0.5)
            }
            feathered(panel(sheet.faces, CharacterFace.closed.rawValue), region: sheet.eyes, inner: 0.6)
                .opacity(CharacterMotion.blend(pose.blink))
        }
        .frame(width: side, height: side)
    }

    private func figureLayer(_ image: String) -> some View {
        Image(image).resizable().interpolation(.high)
            .frame(width: side, height: side)
    }

    private func figureFaceDetails(_ pose: CharacterPose, face: CharacterFace,
                                   sheet: Sheet, artwork: CharacterFigureArtwork) -> some View {
        // Each atlas panel is a full square. Scaling that square preserves the
        // face, mouth, and blink regions' authored positions inside it.
        let scale = artwork.faceRect.width
        return faceDetails(pose, face: face, sheet: sheet)
            .scaleEffect(x: scale, y: scale, anchor: .topLeading)
            .offset(x: artwork.faceRect.minX * CGFloat(side),
                    y: artwork.faceRect.minY * CGFloat(side))
    }

    private func layeredFigure(_ artwork: CharacterFigureArtwork, sheet: Sheet,
                               pose: CharacterPose, face: CharacterFace,
                               body: CharacterFigurePose) -> some View {
        ZStack(alignment: .topLeading) {
            if let backHair = artwork.backHair {
                figureLayer(backHair)
                    .rotationEffect(.degrees(body.headAngle), anchor: artwork.neck.anchor)
                    .offset(y: body.headNod * side)
            }
            figureLayer(artwork.farArm)
                .rotationEffect(.degrees(body.farArmAngle), anchor: artwork.farShoulder.anchor)
            figureLayer(artwork.torso)
            ZStack(alignment: .topLeading) {
                figureLayer(artwork.head)
                figureFaceDetails(pose, face: face, sheet: sheet, artwork: artwork)
            }
            .frame(width: side, height: side)
            .rotationEffect(.degrees(body.headAngle), anchor: artwork.neck.anchor)
            .offset(y: body.headNod * side)
            figureLayer(artwork.nearArm)
                .rotationEffect(.degrees(body.nearArmAngle), anchor: artwork.nearShoulder.anchor)
            if let frontHair = artwork.frontHair {
                figureLayer(frontHair)
                    .rotationEffect(.degrees(body.headAngle), anchor: artwork.neck.anchor)
                    .offset(y: body.headNod * side)
            }
        }
        .frame(width: side, height: side)
        .rotationEffect(.degrees(body.torsoAngle), anchor: artwork.waist.anchor)
        .offset(y: -body.torsoLift * side)
        .clipShape(RoundedRectangle(cornerRadius: 22))
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

/// Unchanged cubic outline from the Harley exact-atlas study, transformed from
/// its 1024-pixel world into the close crop. This clips both mask and face.
private struct CharacterBustHeadCut: Shape {
    let artwork: CharacterBustArtwork

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 406, y: 46))
        path.addCurve(to: CGPoint(x: 493, y: 17), control1: CGPoint(x: 426, y: 20), control2: CGPoint(x: 461, y: 17))
        path.addCurve(to: CGPoint(x: 578, y: 30), control1: CGPoint(x: 527, y: 7), control2: CGPoint(x: 556, y: 21))
        path.addCurve(to: CGPoint(x: 645, y: 82), control1: CGPoint(x: 609, y: 30), control2: CGPoint(x: 632, y: 55))
        path.addCurve(to: CGPoint(x: 667, y: 158), control1: CGPoint(x: 663, y: 98), control2: CGPoint(x: 669, y: 130))
        path.addCurve(to: CGPoint(x: 663, y: 212), control1: CGPoint(x: 675, y: 178), control2: CGPoint(x: 671, y: 195))
        path.addCurve(to: CGPoint(x: 665, y: 275), control1: CGPoint(x: 674, y: 235), control2: CGPoint(x: 674, y: 256))
        path.addCurve(to: CGPoint(x: 647, y: 341), control1: CGPoint(x: 669, y: 301), control2: CGPoint(x: 661, y: 322))
        path.addCurve(to: CGPoint(x: 610, y: 402), control1: CGPoint(x: 639, y: 367), control2: CGPoint(x: 625, y: 385))
        path.addCurve(to: CGPoint(x: 600, y: 472), control1: CGPoint(x: 601, y: 420), control2: CGPoint(x: 598, y: 437))
        path.addCurve(to: CGPoint(x: 447, y: 472), control1: CGPoint(x: 571, y: 489), control2: CGPoint(x: 488, y: 493))
        path.addCurve(to: CGPoint(x: 432, y: 411), control1: CGPoint(x: 453, y: 445), control2: CGPoint(x: 448, y: 428))
        path.addCurve(to: CGPoint(x: 397, y: 346), control1: CGPoint(x: 414, y: 390), control2: CGPoint(x: 403, y: 370))
        path.addCurve(to: CGPoint(x: 381, y: 291), control1: CGPoint(x: 383, y: 332), control2: CGPoint(x: 379, y: 310))
        path.addCurve(to: CGPoint(x: 376, y: 234), control1: CGPoint(x: 370, y: 274), control2: CGPoint(x: 369, y: 255))
        path.addCurve(to: CGPoint(x: 378, y: 179), control1: CGPoint(x: 366, y: 215), control2: CGPoint(x: 368, y: 193))
        path.addCurve(to: CGPoint(x: 384, y: 102), control1: CGPoint(x: 369, y: 149), control2: CGPoint(x: 376, y: 117))
        path.addCurve(to: CGPoint(x: 406, y: 46), control1: CGPoint(x: 385, y: 76), control2: CGPoint(x: 391, y: 59))
        path.closeSubpath()
        let unit = rect.width / CGFloat(artwork.cropSide)
        return path.applying(CGAffineTransform(a: unit, b: 0, c: 0, d: unit,
            tx: rect.minX - CGFloat(artwork.cropX) * unit,
            ty: rect.minY - CGFloat(artwork.cropY) * unit))
    }
}
