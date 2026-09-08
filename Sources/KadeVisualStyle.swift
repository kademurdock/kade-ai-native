import SwiftUI

// MARK: - Session 22 visual layer
//
// Kade: "Make it look more pretty without effecting vo, or make it more
// tactile or auditory without effecting vision... Maybe some visual
// animations?" This file is the PRETTY half: reusable styles that give the
// home screen (and friends) some visual identity for sighted family members
// glancing at the phone, while being provably inert for VoiceOver:
//
//   - Every decorative element (icon tiles, chevrons, waveform bars) is
//     `.accessibilityHidden(true)` -- VoiceOver's tree is IDENTICAL to the
//     plain-button version it replaces. Button names still come from the
//     visible title Text; every `.accessibilityLabel`/`.accessibilityHint`
//     set at the call site is untouched.
//   - Every animation collapses to a static state under reduced motion --
//     the system switch OR the in-app Feedback override, same rule as
//     KadePulseDot (see KadeFeedback.swift).
//   - High contrast (AppearancePreferences) swaps soft tints for solid
//     fills and adds real borders, so "prettier" never means "muddier"
//     for low vision. Styles re-evaluate when that pref flips because the
//     app root already re-renders everything on its change.

// MARK: - Home tile label

/// Lays a Label out as an iOS-Settings-style row: a white SF Symbol on a
/// small rounded tint tile, the title, then a trailing chevron. The tile and
/// chevron are hidden from VoiceOver; the title Text is the only accessible
/// content, exactly like the stock label style it replaces.
struct KadeTileLabelStyle: LabelStyle {
    @KadeContrastPolicy private var highContrast: Bool
    var tint: Color
    @ScaledMetric(relativeTo: .body) private var tileSide: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: tileSide * 0.24, style: .continuous)
                    .fill(tileFill)
                configuration.icon
                    .font(.system(size: min(tileSide, 48) * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: min(tileSide, 48), height: min(tileSide, 48))
            .accessibilityHidden(true)

            configuration.title
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    private var tileFill: some ShapeStyle {
        if highContrast {
            // Solid, no gradient: maximum figure/ground separation.
            return AnyShapeStyle(tint)
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [tint.opacity(0.95), tint.opacity(0.7)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
    }
}

/// Session 25 (Kade approved the audit list, "All four"): vertical tile for
/// the home Tools GRID -- icon block on top, short centered title beneath,
/// no chevron (a grid tile reads as a tile, not a row). Same tint /
/// gradient / high-contrast rules as `KadeTileLabelStyle` above; same
/// ScaledMetric so Dynamic Type grows the icon block too.
struct KadeGridTileLabelStyle: LabelStyle {
    @KadeContrastPolicy private var highContrast: Bool
    var tint: Color
    @ScaledMetric(relativeTo: .body) private var tileSide: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: tileSide * 0.24, style: .continuous)
                    .fill(tileFill)
                configuration.icon
                    .font(.system(size: min(tileSide, 48) * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: min(tileSide, 48), height: min(tileSide, 48))
            .accessibilityHidden(true)

            configuration.title
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var tileFill: some ShapeStyle {
        if highContrast {
            return AnyShapeStyle(tint)
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [tint.opacity(0.95), tint.opacity(0.7)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
    }
}

// MARK: - Card button style

/// A soft card behind each home row: rounded rect, subtle press-down spring.
/// Under reduced motion the press still registers (opacity dip -- a state
/// change, not motion) but nothing scales or springs. Under high contrast
/// the card gains a real border instead of relying on background contrast.
struct KadeCardButtonStyle: ButtonStyle {
    @KadeContrastPolicy private var highContrast: Bool
    @KadeMotionPolicy private var motionAllowed: Bool

    func makeBody(configuration: Configuration) -> some View {
        let reduce = !motionAllowed
        let pressed = configuration.isPressed
        return configuration.label
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        highContrast ? Color.primary.opacity(0.65) : Color.primary.opacity(0.14),
                        lineWidth: highContrast ? 1.5 : 1
                    )
            )
            .opacity(pressed ? 0.75 : 1.0)
            .scaleEffect((pressed && !reduce) ? 0.975 : 1.0)
            .animation(reduce ? nil : .spring(response: 0.28, dampingFraction: 0.7), value: pressed)
    }
}

/// Eager layout keeps the same controls and reading order as text size changes.
struct KadeToolRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let layout = dynamicTypeSize >= .xxxLarge
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout { content }
    }
}

// MARK: - Hero button style (the Spotter call button)

/// The one deliberately loud button in the app: a full-width gradient card
/// with white type. High contrast swaps the gradient for a solid accent fill
/// plus border; reduced motion stills the press spring, same as the cards.
struct KadeHeroButtonStyle: ButtonStyle {
    @KadeContrastPolicy private var highContrast: Bool
    @KadeMotionPolicy private var motionAllowed: Bool

    func makeBody(configuration: Configuration) -> some View {
        let reduce = !motionAllowed
        let pressed = configuration.isPressed
        return configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 16)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(heroFill)
                    if !highContrast {
                        KadeOrbitDecoration()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        highContrast ? Color.white.opacity(0.85) : .clear,
                        lineWidth: highContrast ? 1.5 : 0
                    )
            )
            .opacity(pressed ? 0.85 : 1.0)
            .scaleEffect((pressed && !reduce) ? 0.98 : 1.0)
            .animation(reduce ? nil : .spring(response: 0.28, dampingFraction: 0.7), value: pressed)
    }

    private var heroFill: some ShapeStyle {
        if highContrast {
            // AccentColor becomes light blue in dark appearance; with the
            // hero's white text that is not a suitable filled-button color.
            return AnyShapeStyle(Color(red: 29.0 / 255, green: 78.0 / 255, blue: 216.0 / 255))
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [Color(red: 67.0 / 255, green: 56.0 / 255, blue: 202.0 / 255),
                         Color(red: 29.0 / 255, green: 78.0 / 255, blue: 216.0 / 255)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
    }
}

// MARK: - Recording waveform (decorative)

/// Five little capsules that dance while recording -- purely a sighted-glance
/// "yes, the mic is live" cue. VoiceOver never sees it (the record button
/// already announces state), and under reduced motion it renders as calm
/// static bars of varied height, which still reads as "waveform" at a glance
/// without any movement.
struct KadeWaveformBars: View {
    var active: Bool
    var tint: Color = .red
    @KadeMotionPolicy private var motionAllowed: Bool
    private let rest: [CGFloat] = [0.45, 0.8, 0.6, 0.9, 0.5]

    var body: some View {
        Group {
            if active && motionAllowed {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                    bars(at: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                bars(at: nil)
            }
        }
        .frame(height: 30)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func bars(at time: TimeInterval?) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<5, id: \.self) { i in
                let scale = time.map { 0.4 + 0.6 * (sin($0 * 6 + Double(i) * 1.2) + 1) / 2 } ?? Double(rest[i])
                Capsule().fill(tint).frame(width: 4, height: 26)
                    .scaleEffect(y: CGFloat(scale), anchor: .center)
            }
        }
    }
}

// MARK: - Session 27: visual delight for sighted riders
// (Kade: "Anything visual I wouldn't know about because I'm totally blind
// that would make it easier for those folks or more interesting." Everything
// below is DECORATIVE: accessibilityHidden, no VoiceOver change of any kind,
// and every animation is double-gated on system Reduce Motion + the in-app
// override, same rules as every visual in this file.)

/// The call screen's state, visible at a glance: a soft breathing orb that
/// wears the call's color — calm teal while listening, warm amber while
/// thinking (the visual twin of the typing sound), green with outward
/// ripples while the agent speaks, blue while connecting, gray otherwise.
/// Under Reduce Motion the colors still change (state, not motion) but
/// nothing breathes or ripples.
struct KadeCallStateOrb: View {
    let status: StreamingCallService.Status
    @KadeMotionPolicy private var motionAllowed: Bool

    private var fill: Color {
        switch status {
        case .listening: return .teal
        case .thinking: return .orange
        case .speaking: return .green
        case .connecting: return .blue
        default: return .gray
        }
    }

    private var breathDuration: Double {
        switch status {
        case .thinking: return 0.85   // matches the typing tick's urgency
        case .speaking: return 1.2
        default: return 2.4           // calm listening breath
        }
    }

    private var statusKey: String {
        switch status {
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .speaking: return "speaking"
        case .connecting: return "connecting"
        default: return "other"
        }
    }

    var body: some View {
        Group {
            if motionAllowed && statusKey != "other" {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                    orb(at: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                orb(at: nil)
            }
        }
        .frame(width: 132, height: 132)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func orb(at time: TimeInterval?) -> some View {
        ZStack {
            if statusKey == "speaking", let time {
                ForEach(0..<2, id: \.self) { ring in
                    let phase = (time / 1.6 + Double(ring) * 0.5).truncatingRemainder(dividingBy: 1)
                    Circle().stroke(fill.opacity(0.35), lineWidth: 2)
                        .scaleEffect(1 + phase * 0.9)
                        .opacity(0.8 * (1 - phase))
                }
            }
            Circle()
                .fill(RadialGradient(colors: [fill.opacity(0.85), fill.opacity(0.4)],
                    center: .center, startRadius: 8, endRadius: 70))
                .scaleEffect(time.map { 1.0 + 0.03 * (1 + sin($0 * .pi / breathDuration)) } ?? 1.0)
        }
    }
}

/// A small colored initial circle beside an agent reply -- speaker identity
/// at a glance in group-ish conversations (Debate Room mints, Spotter
/// handoffs, agent switches mid-chat). Deterministic hue from the name so
/// Kiana is always Kiana's color on every screen, no stored config. The
/// user's own messages deliberately get none (their side of the chat stays
/// clean, iMessage-style).
struct KadeSpeakerMonogram: View {
    let name: String
    var speaking: Bool = false

    private var initialLetter: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    private var hue: Double {
        var h = 5381
        for scalar in name.unicodeScalars {
            h = (h &* 33) &+ Int(scalar.value)
        }
        return Double(abs(h % 360)) / 360.0
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hue: hue, saturation: 0.55, brightness: 0.82))
            Text(initialLetter)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
        }
        .frame(width: 26, height: 26)
        .overlay {
            if speaking {
                KadePlaybackHalo(tint: Color(hue: hue, saturation: 0.65, brightness: 0.75))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Decorative layers have no hit targets, layout footprint, or accessibility nodes.
private struct KadeOrbitDecoration: View {
    @KadeMotionPolicy private var motionAllowed: Bool


    var body: some View {
        Group {
            if motionAllowed {
                TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { context in
                    orbits(at: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                orbits(at: 0)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func orbits(at time: TimeInterval) -> some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width * 0.91, y: size.height * 0.5)
            for i in 0..<3 {
                let radius = size.height * (0.45 + Double(i) * 0.38)
                let circle = CGRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)
                context.stroke(Path(ellipseIn: circle), with: .color(.white.opacity(0.08)), lineWidth: 1)
                let angle = time * (0.16 + Double(i) * 0.025) + Double(i) * 2.1
                let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                let dot = CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
                context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.12)))
            }
        }
    }
}

private struct KadePlaybackHalo: View {
    @KadeContrastPolicy private var highContrast: Bool
    let tint: Color
    @KadeMotionPolicy private var motionAllowed: Bool

    var body: some View {
        Group {
            if motionAllowed {
                TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { context in
                    ring(scale: 1.18 + 0.07 * sin(context.date.timeIntervalSinceReferenceDate * 3))
                }
            } else {
                ring(scale: 1.2)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func ring(scale: Double) -> some View {
        Circle()
            .strokeBorder(tint, lineWidth: highContrast ? 2 : 1.5)
            .scaleEffect(scale)
    }
}


// MARK: - Thinking bubbles (Aug 4 2026)

/// Kade: "some kind of hypnotic bubbles visually to match the bubbling
/// thoughts sound effect when waiting for them to finish thinking."
/// Native twin of the web's ThinkingBubbles.tsx -- the SAME seven
/// hand-tuned bubbles (left offset, size, delay, duration copied verbatim)
/// rising and fading on loop during the pure waiting beat, so both
/// surfaces breathe alike. Decorative ONLY: accessibilityHidden (the
/// bubbling SOUND plus the replying row's label carry the non-visual cue),
/// and it holds perfectly still as a faint static row under system Reduce
/// Motion or the in-app motion override -- the same double gate as every
/// other animation in this file. TimelineView computes each frame from the
/// clock directly: no @State, nothing to cancel, nothing to leak when the
/// row disappears.
struct KadeThinkingBubbles: View {
    @KadeMotionPolicy private var motionAllowed: Bool
    // The shared policy also stops this timeline in the background and in
    // Low Power Mode, preserving the original VoiceOver CPU safeguard.

    /// (left, size, delay, duration) -- hand-tuned on web so the drift
    /// feels organic rather than a marching row; keep the two lists in
    /// sync if either side is ever retuned.
    private static let bubbles: [(left: CGFloat, size: CGFloat, delay: Double, dur: Double)] = [
        (2, 6, 0.0, 2.4),
        (12, 4, 0.5, 2.0),
        (20, 7, 0.9, 2.7),
        (30, 5, 0.2, 2.2),
        (40, 4, 1.1, 2.5),
        (48, 6, 0.7, 2.1),
        (56, 4, 1.4, 2.6),
    ]

    var body: some View {
        let reduce = !motionAllowed
        Group {
            if reduce {
                bubbleRow(at: nil)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    bubbleRow(at: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: 64, height: 22, alignment: .bottomLeading)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// One frame. `t == nil` is the Reduce Motion branch: every bubble
    /// sits still at its resting spot at the web's own reduced-motion
    /// opacity (0.22), exactly like the CSS `prefers-reduced-motion` rule.
    private func bubbleRow(at t: TimeInterval?) -> some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(0..<Self.bubbles.count, id: \.self) { i in
                let b = Self.bubbles[i]
                let phase: Double? = t.map { time in
                    let raw = (time - b.delay).truncatingRemainder(dividingBy: b.dur)
                    return (raw < 0 ? raw + b.dur : raw) / b.dur
                }
                let size = b.size * (phase.map { 0.6 + 0.4 * $0 } ?? 1.0)
                Circle()
                    .fill(Color.secondary.opacity(phase.map(Self.opacity(for:)) ?? 0.22))
                    .frame(width: size, height: size)
                    .offset(x: b.left, y: phase.map { 4 - 18 * $0 } ?? -4)
            }
        }
    }

    /// The web keyframes, piecewise: 0% -> 0, 25% -> 0.32, 60% -> 0.18,
    /// 100% -> 0.
    private static func opacity(for phase: Double) -> Double {
        if phase < 0.25 { return 0.32 * (phase / 0.25) }
        if phase < 0.60 { return 0.32 - 0.14 * ((phase - 0.25) / 0.35) }
        return 0.18 * (1.0 - (phase - 0.60) / 0.40)
    }
}
