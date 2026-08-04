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

/// Reads the same UserDefaults keys the preference objects write, from
/// nonisolated style structs that can't (and shouldn't) hold an
/// @EnvironmentObject. Registered defaults make the reads safe on a fresh
/// install.
private enum StylePrefs {
    static var highContrast: Bool {
        UserDefaults.standard.bool(forKey: "kade.appearance.highContrast")
    }
    static var forceReduceMotion: Bool {
        UserDefaults.standard.bool(forKey: "kade.feedback.reduceMotion")
    }
}

// MARK: - Home tile label

/// Lays a Label out as an iOS-Settings-style row: a white SF Symbol on a
/// small rounded tint tile, the title, then a trailing chevron. The tile and
/// chevron are hidden from VoiceOver; the title Text is the only accessible
/// content, exactly like the stock label style it replaces.
struct KadeTileLabelStyle: LabelStyle {
    var tint: Color
    @ScaledMetric(relativeTo: .body) private var tileSide: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: tileSide * 0.24, style: .continuous)
                    .fill(tileFill)
                configuration.icon
                    .font(.system(size: tileSide * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: tileSide, height: tileSide)
            .accessibilityHidden(true)

            configuration.title
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    private var tileFill: some ShapeStyle {
        if StylePrefs.highContrast {
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
    var tint: Color
    @ScaledMetric(relativeTo: .body) private var tileSide: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: tileSide * 0.24, style: .continuous)
                    .fill(tileFill)
                configuration.icon
                    .font(.system(size: tileSide * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: tileSide, height: tileSide)
            .accessibilityHidden(true)

            configuration.title
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var tileFill: some ShapeStyle {
        if StylePrefs.highContrast {
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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let reduce = systemReduceMotion || StylePrefs.forceReduceMotion
        let pressed = configuration.isPressed
        return configuration.label
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        StylePrefs.highContrast ? Color.primary.opacity(0.55) : Color.primary.opacity(0.06),
                        lineWidth: StylePrefs.highContrast ? 1.5 : 1
                    )
            )
            .opacity(pressed ? 0.75 : 1.0)
            .scaleEffect((pressed && !reduce) ? 0.975 : 1.0)
            .animation(reduce ? nil : .spring(response: 0.28, dampingFraction: 0.7), value: pressed)
    }
}

// MARK: - Hero button style (the Spotter call button)

/// The one deliberately loud button in the app: a full-width gradient card
/// with white type. High contrast swaps the gradient for a solid accent fill
/// plus border; reduced motion stills the press spring, same as the cards.
struct KadeHeroButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let reduce = systemReduceMotion || StylePrefs.forceReduceMotion
        let pressed = configuration.isPressed
        return configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 16)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(heroFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        StylePrefs.highContrast ? Color.white.opacity(0.85) : .clear,
                        lineWidth: StylePrefs.highContrast ? 1.5 : 0
                    )
            )
            .opacity(pressed ? 0.85 : 1.0)
            .scaleEffect((pressed && !reduce) ? 0.98 : 1.0)
            .animation(reduce ? nil : .spring(response: 0.28, dampingFraction: 0.7), value: pressed)
    }

    private var heroFill: some ShapeStyle {
        if StylePrefs.highContrast {
            return AnyShapeStyle(Color.accentColor)
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [Color.indigo, Color.blue],
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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var animating = false

    /// Resting scale for each bar -- staggered so the static (reduced-motion
    /// or idle) state still looks like a waveform, not a flat line.
    private let rest: [CGFloat] = [0.45, 0.8, 0.6, 0.9, 0.5]

    var body: some View {
        let reduce = systemReduceMotion || StylePrefs.forceReduceMotion
        HStack(spacing: 5) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(tint)
                    .frame(width: 4, height: 26)
                    .scaleEffect(y: barScale(i, reduce: reduce), anchor: .center)
                    .animation(
                        (active && !reduce)
                            ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(i) * 0.09)
                            : .default,
                        value: animating
                    )
            }
        }
        .frame(height: 30)
        .onAppear { if active && !reduce { animating = true } }
        .onChange(of: active) { _, now in
            animating = now && !(systemReduceMotion || StylePrefs.forceReduceMotion)
        }
        .accessibilityHidden(true)
    }

    private func barScale(_ i: Int, reduce: Bool) -> CGFloat {
        guard active, !reduce else { return rest[i] }
        return animating ? 1.0 : rest[i]
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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var breathing = false
    @State private var rippling = false

    private var reduceMotion: Bool { systemReduceMotion || StylePrefs.forceReduceMotion }

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
        ZStack {
            if statusKey == "speaking" && !reduceMotion {
                ForEach(0..<2, id: \.self) { ring in
                    Circle()
                        .stroke(fill.opacity(0.35), lineWidth: 2)
                        .scaleEffect(rippling ? 1.9 : 1.0)
                        .opacity(rippling ? 0.0 : 0.8)
                        .animation(
                            .easeOut(duration: 1.6)
                                .repeatForever(autoreverses: false)
                                .delay(Double(ring) * 0.8),
                            value: rippling
                        )
                }
            }
            Circle()
                .fill(
                    RadialGradient(
                        colors: [fill.opacity(0.85), fill.opacity(0.4)],
                        center: .center,
                        startRadius: 8,
                        endRadius: 70
                    )
                )
                .scaleEffect(!reduceMotion && breathing ? 1.06 : 1.0)
                .animation(
                    reduceMotion
                        ? nil
                        : .easeInOut(duration: breathDuration).repeatForever(autoreverses: true),
                    value: breathing
                )
        }
        .frame(width: 132, height: 132)
        .accessibilityHidden(true)
        // New identity per state: restarts the breath at that state's own
        // rhythm and re-arms the ripples cleanly -- changing a
        // repeatForever's duration mid-flight is undefined-feeling
        // territory; a fresh subtree is deterministic.
        .id(statusKey)
        .onAppear {
            breathing = true
            rippling = true
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
        .accessibilityHidden(true)
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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

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
        let reduce = systemReduceMotion || StylePrefs.forceReduceMotion
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
