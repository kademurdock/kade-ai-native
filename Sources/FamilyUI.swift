import SwiftUI
import UIKit

// MARK: - Family history: the pieces every family screen shares (Sep 29 2026)
//
// Words come from the server; these only draw them the same way everywhere:
// - the side colours (always a second cue: the side is written too);
// - a screen heading that takes VoiceOver focus about 550 ms after the push
//   (BARD's rule, as LibraryShelfScreen does it);
// - the Research pill with its proof words;
// - a focused, announced Try again (a pull is never the only way back);
// - one row for a server tile ({title, detail, spoken, hint, enabled, open});
// - the placeholder a screen shows until its own step of the build fills it.

// MARK: - Side colours

/// Mom's side, Dad's side, both, by marriage, research: each at 3:1 against
/// the background in light and dark, with a darker (lighter) variant for
/// Increase Contrast. Never the only cue: the side is always written.
enum FamilySideColor {
    static func color(_ side: FHSide, contrast: Bool) -> Color {
        let light: UInt32
        let dark: UInt32
        switch side {
        case .father:
            light = contrast ? 0x0A4FA8 : 0x1F6FD1
            dark = contrast ? 0x9CCBFF : 0x6AAEFF
        case .mother:
            light = contrast ? 0x9A3A0C : 0xC2521B
            dark = contrast ? 0xFFBF99 : 0xFF9A62
        case .both:
            light = 0x7A4FC9
            dark = 0xB99BFF
        case .marriage, .unknown:
            light = 0x6B7280
            dark = 0xA1A8B3
        case .research:
            light = 0x8A6D00
            dark = 0xE0C45A
        }
        return dynamic(light: light, dark: dark)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        let lightColor: UIColor = rgb(light)
        let darkColor: UIColor = rgb(dark)
        return Color(uiColor: UIColor(dynamicProvider: { (traits: UITraitCollection) -> UIColor in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        }))
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        let r: CGFloat = CGFloat((hex >> 16) & 0xFF) / 255
        let g: CGFloat = CGFloat((hex >> 8) & 0xFF) / 255
        let b: CGFloat = CGFloat(hex & 0xFF) / 255
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
}

// MARK: - Headings

/// A heading at its level (the Headings rotor walks screen, section,
/// generation, decade). With `focusOnArrival`, VoiceOver starts on it about
/// 550 ms after the push, once.
struct FamilyHeading: View {
    let text: String
    var level: AccessibilityHeadingLevel = .h2
    var focusOnArrival = false

    @AccessibilityFocusState private var focused: Bool
    @State private var arrived = false

    var body: some View {
        Text(text)
            .font(font)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHeading(level)
            .accessibilityFocused($focused)
            .task {
                guard focusOnArrival, !arrived else { return }
                arrived = true
                try? await Task.sleep(nanoseconds: 550_000_000)
                if Task.isCancelled { return }
                focused = true
            }
    }

    private var font: Font {
        switch level {
        case .h1: return .title2.bold()
        case .h2: return .title3.bold()
        default: return .headline
        }
    }
}

// MARK: - Research and proof

/// The magnifying glass and "Research", beside anything that is a research
/// finding rather than proven by records. The proof words themselves are in
/// the element's label (the server's `spoken`), so the pill is silent.
struct FamilyResearchPill: View {
    @KadeContrastPolicy private var highContrast: Bool

    var body: some View {
        let tint: Color = FamilySideColor.color(.research, contrast: highContrast)
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
            Text("Research")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(Capsule().strokeBorder(tint, style: StrokeStyle(lineWidth: highContrast ? 2 : 1, dash: [3, 2])))
        .accessibilityHidden(true)
    }
}

// MARK: - Loading and trying again

/// "Loading", with a spinner for sight (VoiceOver hears the words).
struct FamilyLoadingLine: View {
    var text: String = "Loading"

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().accessibilityHidden(true)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// What went wrong, and a Try again button that is announced and focused
/// when it appears (a pull is never the only way to retry).
struct FamilyTryAgain: View {
    let message: String
    let action: () -> Void

    @AccessibilityFocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again", action: action)
                .buttonStyle(.bordered)
                .accessibilityFocused($focused)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: message) {
            UIAccessibility.post(notification: .announcement, argument: message)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if Task.isCancelled { return }
            focused = true
        }
    }
}

// MARK: - A server row

/// One tile or plain row from the server: `{key, title, detail, spoken,
/// hint, enabled, reason, open}`. ONE element: "{title}, {detail}" (or the
/// server's sentence) with its hint. A dimmed row says why (its `reason`).
/// Voice Control answers to the title.
struct FamilyTileRow: View {
    let tile: FHTile
    var icon: String = "chevron.right.circle"

    var body: some View {
        if tile.isEnabled, let route = tile.open?.route {
            NavigationLink(value: HomeRoute.library(.family(route))) {
                label
            }
            .accessibilityLabel(spoken)
            .accessibilityHint(tile.hint ?? "")
            .accessibilityInputLabels(inputLabels)
        } else {
            Button {} label: {
                label
            }
            .disabled(true)
            .accessibilityLabel(spoken)
            .accessibilityHint(tile.reason ?? tile.hint ?? "")
            .accessibilityInputLabels(inputLabels)
        }
    }

    private var title: String { tile.title ?? "" }

    private var detail: String? {
        if !tile.isEnabled, let reason = FamilyAccessRules.nonEmpty(tile.reason) { return reason }
        return FamilyAccessRules.nonEmpty(tile.detail)
    }

    private var spoken: String {
        if let said = FamilyAccessRules.nonEmpty(tile.spoken) { return said }
        guard let detail else { return title }
        return title + ", " + detail
    }

    private var inputLabels: [String] {
        title.isEmpty ? [] : [title]
    }

    private var label: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.brown)
                .frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Until a screen is built

/// What a family screen shows until its own step of the build fills it: its
/// title as the heading (focused on arrival) and one plain line. Nothing
/// here loads or keeps family data.
struct FamilyPlaceholderScreen: View {
    let title: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FamilyHeading(text: title, level: .h1, focusOnArrival: true)
                Text("This part of Family history is not in this version of the app yet.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
