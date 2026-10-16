#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Oct 16 2026: DEBUG simulator gallery for CI screenshots
/// (dev/puppet-gallery.sh): each painted character's old sliced portrait
/// beside the living painting, state by state, then the real stage portrait.
/// Launch with -KadeLivingGallery and -KadeLivingGalleryPage 0...18: pages
/// 0-6 are Della's (5 and 6 her real stage, square and tall); then three
/// pages each for Kiana, Harley, Lilly and Mrs. Witherspoon (pairs, square
/// stage, tall stage). Never reachable in a release build.
struct LivingPaintingGalleryView: View {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-KadeLivingGallery") }
    static let pageCount = 7 + 3 * 4
    @EnvironmentObject private var agents: AgentsService
    static var requestedPage: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-KadeLivingGalleryPage"), index + 1 < arguments.count,
              let page = Int(arguments[index + 1]) else { return 0 }
        return min(pageCount - 1, max(0, page))
    }

    struct Member {
        let id: String
        let name: String
        let rig: String
        let file: String
    }
    static let cast = [
        Member(id: CharacterMotion.dellaID, name: "Della", rig: "LivingPaintingDella", file: CharacterMotion.dellaFile),
        Member(id: CharacterMotion.kianaID, name: "Kiana", rig: "LivingPaintingKiana", file: CharacterMotion.kianaFile),
        Member(id: CharacterMotion.harleyID, name: "Harley", rig: "LivingPaintingHarley", file: CharacterMotion.harleyFile),
        Member(id: CharacterMotion.lillyID, name: "Lilly", rig: "LivingPaintingLilly", file: CharacterMotion.lillyFile),
        Member(id: CharacterMotion.witherspoonID, name: "Mrs. Witherspoon", rig: "LivingPaintingWitherspoon",
               file: CharacterMotion.witherspoonFile),
    ]

    /// What one page shows: whose painting, and which kind of page.
    enum Kind {
        case pairs(Int)
        case stage(tall: Bool)
    }

    static func plan(_ page: Int) -> (member: Member, kind: Kind) {
        if page < 5 { return (cast[0], .pairs(page)) }
        if page < 7 { return (cast[0], .stage(tall: page == 6)) }
        let k = (page - 7) / 3, step = (page - 7) % 3
        let member = cast[min(cast.count - 1, 1 + k)]
        return (member, step == 0 ? .pairs(0) : .stage(tall: step == 2))
    }

    struct Row: Identifiable {
        let id: Int
        let label: String
        let old: LivingPaintingState
        let new: LivingPaintingState
    }

    private let page = LivingPaintingGalleryView.requestedPage
    @State private var resources: LivingPaintingResources?
    @State private var report = "Loading the living painting"
    @State private var agentsReady = false

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

    /// A short stretch of the real engine speaking, sampled at fixed times,
    /// so a still page shows what motion looks like over time.
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

    private func rows(_ pairsPage: Int, member: Member) -> [Row] {
        if member.id != CharacterMotion.dellaID {
            // One page per character: a blink, a glance, an expression
            // half-way in and a speaking mouth.
            return [
                Self.pair(20, "blink, half", ["eye.blink": 0.5]),
                Self.pair(21, "glance and head turn", ["head.yaw": 0.7, "gaze.x": 0.8, "head.roll": 0.4, "hair.swing": -0.6]),
                Self.pair(22, "smile, half-way in", [:], face: .smile, blend: 0.5),
                Self.pair(23, "talking: oh", ["mouth.open": 0.7, "mouth.round": 0.7], viseme: 3),
            ]
        }
        switch pairsPage {
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
                Self.pair(3, "brows lift on a stressed word", ["brow.raise": 0.45, "gaze.y": -0.2]),
            ]
        }
    }

    var body: some View {
        let plan = Self.plan(page)
        return VStack(spacing: 4) {
            switch plan.kind {
            case .stage(let tall):
                Text("Living painting, page \(page + 1) of \(Self.pageCount): \(plan.member.name), the real \(tall ? "tall" : "square") stage portrait, speaking warmly. Top: sliced. Bottom: living painting.")
                    .font(.caption2)
                    .lineLimit(3)
                    .padding(.horizontal, 8)
                if agentsReady {
                    stagePortrait(plan.member, tall: tall, living: false)
                    Text("sliced (as shipped)").font(.caption2)
                    stagePortrait(plan.member, tall: tall, living: true)
                    Text("living painting").font(.caption2)
                }
            case .pairs(let pairsPage):
                Text("Living painting, page \(page + 1) of \(Self.pageCount): \(plan.member.name). Left: old sliced portrait. Right: living painting. \(report)")
                    .font(.caption2)
                    .lineLimit(3)
                    .padding(.horizontal, 8)
                ForEach(rows(pairsPage, member: plan.member)) { row in
                    HStack(spacing: 8) {
                        tile(row.old, member: plan.member)
                        tile(row.new, member: plan.member)
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
        .task { await load(plan.member) }
        .task {
            agents.seedCharacterAudit()
            agentsReady = true
        }
    }

    /// The production portrait (square bust, or the tall host layout with
    /// arms), driven by a speaking presentation.
    private func stagePortrait(_ member: Member, tall: Bool, living: Bool) -> some View {
        CharacterPortraitView(agentID: member.id, name: member.name, playing: true,
            level: { 0.06 + 0.05 * sin(Date().timeIntervalSinceReferenceDate * 9) },
            presentation: { CharacterPresentation(activity: .speaking, expression: .warm) },
            stage: true, side: tall ? 160 : 170,
            dellaArticulatedReview: tall, livingPainting: living)
    }

    /// Della's body plate exactly as the bust portrait places it, with the
    /// head drawn over it; the others' cut-out heads over a plain backdrop.
    @ViewBuilder private func tile(_ state: LivingPaintingState, member: Member) -> some View {
        let side = 160.0
        let unit = side / 414
        ZStack(alignment: .topLeading) {
            Color(red: 0.16, green: 0.45, blue: 0.48)
            if member.id == CharacterMotion.dellaID {
                Image("CharacterDellaBustBody").resizable().interpolation(.high)
                    .frame(width: 677.16 * unit, height: 677.16 * unit)
                    .offset(x: -132 * unit, y: (-1 + state.offsetY) * unit)
                    .frame(width: side, height: side, alignment: .topLeading)
            }
            if let resources {
                LivingPaintingCanvas(resources: resources, state: state)
                    .frame(width: side, height: side)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func load(_ member: Member) async {
        guard resources == nil else { return }
        let started = Date()
        // The bust's own head cut, as the stage portrait uses it.
        let outline = CharacterBustArtwork.approved(stage: true, side: 208, agentID: member.id,
            avatarPath: "/images/" + member.file).map { CharacterBustOutlinePanel.bust($0) }
        let rig = member.rig
        let made: Result<LivingPaintingResources, Error> = await Task.detached(priority: .userInitiated) {
            Result { try LivingPaintingResources.shared(rigName: rig, cutKey: "bust", outline: outline) }
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
