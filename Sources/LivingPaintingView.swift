import MetalKit
import SwiftUI

/// Oct 16 2026: a living painting's head, drawn by the GPU over whatever body
/// the portrait already composes. Decorative like every portrait: hidden from
/// VoiceOver and never hit-tested; the character is described in words
/// elsewhere. Its frame is the head's 414-pixel panel frame (side x side).
struct LivingPaintingCanvas: UIViewRepresentable {
    let resources: LivingPaintingResources
    let state: LivingPaintingState

    func makeCoordinator() -> LivingPaintingDrawer { LivingPaintingDrawer(resources: resources) }

    /// Draws again whenever it is laid out, so the first frame appears as
    /// soon as the view has a size.
    final class Surface: MTKView {
        override func layoutSubviews() {
            super.layoutSubviews()
            setNeedsDisplay()
        }
    }

    func makeUIView(context: Context) -> MTKView {
        let view = Surface(frame: .zero, device: resources.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isOpaque = false
        view.layer.isOpaque = false
        view.backgroundColor = .clear
        view.framebufferOnly = true
        // Drawn only when SwiftUI hands over a new frame: the portrait's own
        // budgeted clock (Low Power, thermal, Reduce Motion) stays in charge.
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.delegate = context.coordinator
        context.coordinator.state = state
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.state = state
        view.setNeedsDisplay()
    }
}

/// Loads a character's living-painting resources off the main thread and
/// draws them; until they are ready (or if this phone cannot), `fallback`
/// (the sliced portrait) stays on screen.
struct LivingPaintingHead<Fallback: View>: View {
    let rigName: String
    let state: LivingPaintingState
    @ViewBuilder var fallback: () -> Fallback
    @State private var resources: LivingPaintingResources?

    var body: some View {
        Group {
            if let resources {
                LivingPaintingCanvas(resources: resources, state: state)
            } else {
                fallback()
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .task(id: rigName) {
            let name = rigName
            resources = await Task.detached(priority: .userInitiated) {
                try? LivingPaintingResources.shared(rigName: name)
            }.value
        }
    }
}

/// Which painted characters have a living-painting rig in this build.
/// Della first (Oct 16 2026); the rest of the cast waits for Kade's review.
enum LivingPaintingCast {
    private static var bundled: [String: Bool] = [:]

    static func rigName(agentID: String?) -> String? {
        guard agentID == CharacterMotion.dellaID else { return nil }
        return available("LivingPaintingDella") ? "LivingPaintingDella" : nil
    }

    static func available(_ name: String) -> Bool {
        if let known = bundled[name] { return known }
        let found = Bundle.main.url(forResource: name, withExtension: "json") != nil
        bundled[name] = found
        return found
    }
}

/// The living painting's own motion: PuppetMotion with a painted face, so the
/// painted panels carry each expression while the engine supplies breathing,
/// glances, blinks, the speaking mouth and the head's turns.
final class LivingPaintingClock {
    private var motion: PuppetMotion?
    private var identity: String?
    private var expression = ""
    private var lastTime: Double?
    private var last = [Double](repeating: 0, count: PuppetChannel.count)

    static let options: PuppetMotion.Options = {
        var options = PuppetMotion.Options()
        options.energy = "steady"
        options.expressiveness = 0.7
        options.baseSmile = 0
        options.artFace = true
        return options
    }()

    func reset() {
        motion = nil
        lastTime = nil
    }

    func pause() { lastTime = nil }

    func channels(identity current: String, time: Double, input: PuppetMotion.Input, expression: String) -> [Double] {
        if motion == nil || identity != current {
            motion = PuppetMotion(seed: PuppetMotion.hashSeed(current), options: Self.options)
            identity = current
            self.expression = ""
            lastTime = nil
        }
        guard let motion else { return last }
        if expression != self.expression {
            motion.setExpression(expression, strength: 1, holdSeconds: PuppetMotion.holdSeconds(for: expression))
            self.expression = expression
        }
        guard time.isFinite else { return last }
        let dt = lastTime.map { time - $0 } ?? 0
        if lastTime == nil || dt > 0 {
            last = motion.update(dt: dt, input: input)
            lastTime = time
        }
        return last
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Oct 16 2026: DEBUG simulator gallery for CI screenshots
/// (dev/puppet-gallery.sh): Della's old sliced portrait beside the living
/// painting, state by state. Launch with -KadeLivingGallery and
/// -KadeLivingGalleryPage 0...6; pages 6 and 7 are the real stage portrait,
/// sliced and living, moving. Never reachable in a release build.
struct LivingPaintingGalleryView: View {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-KadeLivingGallery") }
    static let pageCount = 7
    @EnvironmentObject private var agents: AgentsService
    static var requestedPage: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-KadeLivingGalleryPage"), index + 1 < arguments.count,
              let page = Int(arguments[index + 1]) else { return 0 }
        return min(pageCount - 1, max(0, page))
    }

    struct Row: Identifiable {
        let id: Int
        let label: String
        let old: LivingPaintingState
        let new: LivingPaintingState
    }

    private let page = LivingPaintingGalleryView.requestedPage
    @State private var resources: LivingPaintingResources?
    @State private var report = "Loading Della's living painting"

    private static func state(_ named: [String: Double], face: CharacterFace = .neutral,
                              warp: Bool, viseme: Int = 0, roll: Double = 0, blend: Double = 1) -> LivingPaintingState {
        var state = LivingPaintingState()
        state.channels = PuppetChannel.values(named)
        state.face = LivingPaintingPanel(face: face)
        state.blend = blend
        state.warp = warp
        state.slicedViseme = viseme
        state.rollDegrees = roll
        return state
    }

    /// The same moment drawn both ways: the old rig shows a painted panel or
    /// patch; the living painting reaches it by moving the face. A blend
    /// below 1 is an expression half-way in, as during a change.
    private static func pair(_ id: Int, _ label: String, _ named: [String: Double],
                             face: CharacterFace = .neutral, viseme: Int = 0, roll: Double = 0,
                             blend: Double = 1) -> Row {
        var oldNamed: [String: Double] = [:]
        if let blink = named["eye.blink"] { oldNamed["eye.blink"] = blink }
        if let turn = named["head.roll"] { oldNamed["head.roll"] = turn }
        return Row(id: id, label: label,
            old: state(oldNamed, face: face, warp: false, viseme: viseme, roll: roll, blend: blend),
            new: state(named, face: face, warp: true, roll: roll, blend: blend))
    }

    /// Oct 16 2026: a short stretch of the real engine speaking, sampled at
    /// fixed times, so a still page shows what motion looks like over time.
    private static func filmstrip() -> [Row] {
        let clock = LivingPaintingClock()
        var rows: [Row] = []
        var time = 0.0
        let samples: Set<Int> = [18, 22, 26, 30]
        for step in 0...30 {
            let level = 0.5 + 0.45 * sin(Double(step) * 1.7)
            let channels = clock.channels(identity: "gallery-della", time: time,
                input: PuppetMotion.Input(speaking: true, level: level), expression: "warm")
            if samples.contains(step) {
                var state = LivingPaintingState()
                state.channels = channels
                state.face = LivingPaintingPanel(face: .smile)
                var old = state
                old.warp = false
                old.channels = PuppetChannel.values(["eye.blink": channels[PuppetChannel.eyeBlink.rawValue]])
                old.slicedViseme = level > 0.55 ? 3 : (level > 0.25 ? 2 : 1)
                rows.append(Row(id: 100 + step, label: String(format: "speaking, t %.1f s", time), old: old, new: state))
            }
            time += 1.0 / 15
        }
        return rows
    }

    private var rows: [Row] {
        switch page {
        case 1:
            return [
                Self.pair(4, "smile, half-way in", [:], face: .smile, blend: 0.5),
                Self.pair(5, "smile", [:], face: .smile),
                Self.pair(6, "surprised, half-way in", [:], face: .surprised, blend: 0.5),
                Self.pair(7, "surprised", [:], face: .surprised),
            ]
        case 2:
            return [
                Self.pair(12, "sad", ["head.pitch": 0.4, "gaze.y": 0.4], face: .sad),
                Self.pair(13, "angry", [:], face: .angry),
                Self.pair(14, "worried", ["gaze.x": -0.5], face: .worried),
                Self.pair(15, "laughing", ["head.roll": 0.4, "head.pitch": -0.3], face: .laugh),
            ]
        case 3:
            return [
                Self.pair(8, "talking: opening toward oh", ["mouth.open": 0.35, "mouth.round": 0.35], viseme: 1),
                Self.pair(9, "talking: oh", ["mouth.open": 0.7, "mouth.round": 0.7], viseme: 3),
                Self.pair(10, "talking: ee", ["mouth.open": 0.35, "mouth.wide": 0.9], viseme: 5),
                Self.pair(11, "talking: ah", ["mouth.open": 1, "mouth.wide": 0.4], viseme: 8),
            ]
        case 4:
            return Self.filmstrip()
        default:
            return [
                Self.pair(0, "resting", [:]),
                Self.pair(1, "blink, half", ["eye.blink": 0.5]),
                Self.pair(2, "glance and head turn", ["head.yaw": 0.7, "gaze.x": 0.8, "head.roll": 0.4, "hair.swing": -0.6]),
                Self.pair(3, "brows up, eyes wide", ["brow.raise": 1, "eye.wide": 1]),
            ]
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            if page >= 5 {
                Text("Living painting, page \(page + 1) of \(Self.pageCount). The real stage portrait, speaking warmly. Top: sliced. Bottom: living painting.")
                    .font(.caption2)
                    .lineLimit(3)
                    .padding(.horizontal, 8)
                if agentsReady {
                    stagePortrait(living: false)
                    Text("sliced (as shipped)").font(.caption2)
                    stagePortrait(living: true)
                    Text("living painting").font(.caption2)
                }
            } else {
                Text("Living painting, page \(page + 1) of \(Self.pageCount). Left: old sliced portrait. Right: living painting. \(report)")
                    .font(.caption2)
                    .lineLimit(3)
                    .padding(.horizontal, 8)
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        tile(row.old)
                        tile(row.new)
                    }
                    Text(row.label).font(.caption2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 54)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .task { await load() }
        .task {
            guard page >= 5 else { return }
            agents.seedCharacterAudit()
            agentsReady = true
        }
    }

    @State private var agentsReady = false

    /// The production portrait (page 6: the square bust; page 7: the tall
    /// host layout with arms), driven by a speaking presentation.
    private func stagePortrait(living: Bool) -> some View {
        CharacterPortraitView(agentID: CharacterMotion.dellaID, name: "Della", playing: true,
            level: { 0.06 + 0.05 * sin(Date().timeIntervalSinceReferenceDate * 9) },
            presentation: { CharacterPresentation(activity: .speaking, expression: .warm) },
            stage: true, side: page == 6 ? 160 : 170,
            dellaArticulatedReview: page == 6, livingPainting: living)
    }

    /// Della's body plate exactly as the bust portrait places it, with the
    /// head drawn over it.
    @ViewBuilder private func tile(_ state: LivingPaintingState) -> some View {
        let side = 160.0
        let unit = side / 414
        ZStack(alignment: .topLeading) {
            Color(red: 0.16, green: 0.45, blue: 0.48)
            Image("CharacterDellaBustBody").resizable().interpolation(.high)
                .frame(width: 677.16 * unit, height: 677.16 * unit)
                .offset(x: -132 * unit, y: (-1 + state.offsetY) * unit)
                .frame(width: side, height: side, alignment: .topLeading)
            if let resources {
                LivingPaintingCanvas(resources: resources, state: state)
                    .frame(width: side, height: side)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func load() async {
        guard resources == nil else { return }
        let started = Date()
        let made: Result<LivingPaintingResources, Error> = await Task.detached(priority: .userInitiated) {
            Result { try LivingPaintingResources.shared(rigName: "LivingPaintingDella") }
        }.value
        switch made {
        case .success(let value):
            resources = value
            var grid = LivingPaintingState()
            grid.channels = PuppetChannel.values(["head.yaw": 0.5, "eye.blink": 0.5, "mouth.open": 0.6])
            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<20 { _ = value.rig.vertices(grid) }
            let each = (CFAbsoluteTimeGetCurrent() - start) * 1000 / 20
            report = String(format: "Loaded in %.2f s; %ld-point grid, %.2f ms per frame (debug build, simulator).",
                Date().timeIntervalSince(started), value.rig.vertexCount, each)
        case .failure(let error):
            report = "Could not load: \(error)"
        }
    }
}
#endif
