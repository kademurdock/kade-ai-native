import SwiftUI

/// Shared by saved replies and the streaming reply. Only this small decorative
/// subtree updates; transcript text and VoiceOver focus never update per frame.
struct CharacterPortraitView: View {
    let agentID: String?
    let name: String
    let playing: Bool
    let level: () -> Double
    var listening = false
    @EnvironmentObject private var agents: AgentsService
    @Environment(\.scenePhase) private var scenePhase
    @KadeMotionPolicy(permitsVoiceOver: true) private var motionAllowed: Bool
    @AppStorage("kadeVoicePortraits") private var enabled = true
    @State private var visible = false

    private var path: String? { agents.agents.first { $0.id == agentID }?.avatar?.filepath }
    private var prepared: Bool { CharacterMotion.prepared(id: agentID, path: path) }
    private var active: Bool { enabled && motionAllowed && scenePhase == .active && visible && (playing || listening) }
    private var url: URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: path.hasPrefix("/") ? "https://kademurdock.com" + path : path)
    }
    var body: some View {
        if enabled {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !active)) { timeline in
                let pose = CharacterMotion.pose(id: agentID ?? "unknown",
                    time: timeline.date.timeIntervalSinceReferenceDate,
                    level: active && playing ? level() : 0, active: active)
                ZStack {
                    RoundedRectangle(cornerRadius: 24).fill(Color.accentColor.opacity(0.08))
                    portrait(pose)
                        .frame(width: 160, height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .rotationEffect(.degrees(pose.tilt))
                        .offset(y: pose.lift)
                }
                .frame(width: 172, height: 172)
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .onAppear { visible = true }
            .onDisappear { visible = false }
        }
    }
    @ViewBuilder private func portrait(_ pose: CharacterPose) -> some View {
        if prepared {
            let della = agentID == CharacterMotion.dellaID
            let base = della ? "CharacterDellaPortrait" : "CharacterKianaPortrait"
            let mouth = della ? "CharacterDellaFace" : "CharacterKianaMouth"
            let eyes = della ? "CharacterDellaFace" : "CharacterKianaEyes"
            let lips = della ? CGRect(x: 0.400, y: 0.462, width: 0.195, height: 0.115) : CGRect(x: 0.457, y: 0.376, width: 0.175, height: 0.122)
            let left = della ? CGRect(x: 0.364, y: 0.295, width: 0.117, height: 0.082) : CGRect(x: 0.355, y: 0.265, width: 0.125, height: 0.09)
            let right = della ? CGRect(x: 0.535, y: 0.295, width: 0.11, height: 0.082) : CGRect(x: 0.518, y: 0.219, width: 0.125, height: 0.08)
            ZStack(alignment: .topLeading) {
                Image(base).resizable().scaledToFill()
                patch(mouth, from: della ? lips : CGRect(x: 0.764, y: 0.217, width: 0.097, height: 0.064), to: lips)
                    .opacity(CharacterMotion.blend(pose.mouth))
                let browLeft = della ? CGRect(x: 0.35, y: 0.221, width: 0.132, height: 0.073) : CGRect(x: 0.357, y: 0.235, width: 0.13, height: 0.066)
                let browRight = della ? CGRect(x: 0.53, y: 0.215, width: 0.13, height: 0.071) : CGRect(x: 0.505, y: 0.151, width: 0.143, height: 0.086)
                patch(della ? "CharacterDellaExpression" : "CharacterKianaExpression", from: browLeft, to: browLeft).opacity(CharacterMotion.blend(pose.brow))
                patch(della ? "CharacterDellaExpression" : "CharacterKianaExpression", from: browRight, to: browRight).opacity(CharacterMotion.blend(pose.brow))
                patch(eyes, from: left, to: left).opacity(CharacterMotion.blend(pose.blink))
                patch(eyes, from: right, to: right).opacity(CharacterMotion.blend(pose.blink))
            }
        } else if let url {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { fallback }
            }
        } else { fallback }
    }
    private var fallback: some View {
        ZStack {
            Color.accentColor.opacity(0.16)
            Text(String(name.prefix(1))).font(.system(size: 56, weight: .medium)).foregroundStyle(Color.accentColor)
        }
    }
    private func patch(_ image: String, from: CGRect, to: CGRect) -> some View {
        let width = to.width * 160, height = to.height * 160
        return Image(image).resizable()
            .frame(width: width / from.width, height: height / from.height)
            .offset(x: -from.minX * width / from.width, y: -from.minY * height / from.height)
            .frame(width: width, height: height, alignment: .topLeading)
            .clipped()
            .mask {
                Circle().fill(RadialGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)],
                    center: .center, startRadius: 0, endRadius: 0.5 * max(width, height)))
                    .frame(width: width, height: height)
            }
            .offset(x: to.minX * 160, y: to.minY * 160)
    }
}
