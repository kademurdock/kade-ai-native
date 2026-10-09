import SwiftUI
import UIKit

/// The actual conversation stage, shared with its offline layout fixture.
/// Transcript, composer and accessible conversation controls stay outside it.
struct CharacterConversationStage: View {
    let agentID: String?
    let name: String
    let playing: Bool
    let side: Double
    let level: () -> Double
    let presentation: () -> CharacterPresentation

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            CharacterPortraitView(agentID: agentID, name: name, playing: playing,
                level: level, presentation: presentation, stage: true, side: side)
            Spacer(minLength: 0)
        }
        .frame(height: side + 40)
        .background(StageMoodLight(mood: StageMood(presentation())))
        .background(Color(.systemBackground))
        .accessibilityHidden(true)
    }
}

/// C5 (Sep 23 2026 redesign) — the mood light's colour families, read from
/// the same `CharacterPresentation` the face stage performs: warm for a
/// smile, a laugh, delight, play and tenderness; cool while a reply is being
/// thought; soft violet for worry, sadness and seriousness; the accent,
/// faint, the rest of the time.
private enum StageMood: CaseIterable {
    case idle, warm, thinking, low

    init(_ presentation: CharacterPresentation) {
        if case .thinking = presentation.activity {
            self = .thinking
            return
        }
        switch presentation.face {
        case .smile, .laugh, .delighted, .playful, .tender: self = .warm
        case .worried, .sad, .serious: self = .low
        default: self = .idle
        }
    }

    /// System colours, so light and dark appearance each get their own shade.
    var center: Color {
        switch self {
        case .idle: return .accentColor
        case .warm: return .orange
        case .thinking: return .teal
        case .low: return .purple
        }
    }

    var edge: Color {
        switch self {
        case .idle: return .accentColor
        case .warm: return .pink
        case .thinking: return .blue
        case .low: return .gray
        }
    }

    /// How strong the middle of the glow is; idle is the faint one.
    var strength: Double {
        switch self {
        case .idle: return 0.12
        case .warm: return 0.34
        case .thinking: return 0.3
        case .low: return 0.26
        }
    }
}

/// C5: the glow itself, drawn as the face stage's BACKGROUND so it can never
/// change the stage's size or layout. Decorative: hidden, never hit-tested.
/// One layer per mood sits ready at zero opacity (the same dissolve the
/// portrait uses for its faces), so a mood change is a cross-fade: animated,
/// easeInOut 0.6 s, only when the motion policy allows, and instant
/// otherwise. The ellipse fades out exactly at the stage's edges, so it
/// never ends in a hard line above the transcript. High contrast gets no
/// glow at all.
private struct StageMoodLight: View {
    let mood: StageMood
    @KadeMotionPolicy(permitsVoiceOver: true) private var motionAllowed: Bool
    @KadeContrastPolicy private var highContrast: Bool

    var body: some View {
        if !highContrast {
            ZStack {
                ForEach(StageMood.allCases, id: \.self) { layer in
                    EllipticalGradient(
                        gradient: Gradient(stops: [
                            .init(color: layer.center.opacity(layer.strength), location: 0),
                            .init(color: layer.edge.opacity(layer.strength * 0.55), location: 0.55),
                            .init(color: layer.edge.opacity(0), location: 1)
                        ]),
                        center: .center,
                        startRadiusFraction: 0,
                        endRadiusFraction: 0.5
                    )
                    .opacity(layer == mood ? 1 : 0)
                }
            }
            .animation(motionAllowed ? .easeInOut(duration: 0.6) : nil, value: mood)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }
}
