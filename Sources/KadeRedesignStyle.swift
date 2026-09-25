import SwiftUI
import UIKit

// MARK: - Sep 23 2026 redesign: shared visual pieces
//
// Same contract as KadeVisualStyle.swift: everything here is decoration.
// Hidden from VoiceOver, no hit targets of its own, still under Reduce Motion,
// solid under Reduce Transparency and high contrast. Nothing here costs money
// to run.

// MARK: - Glass (C6)

/// Liquid Glass on iOS 26 for the app's floating bars (Now Playing, composer,
/// tab-page cards), a material on older iOS, and a SOLID fill with a real
/// border under Reduce Transparency or high contrast — see-through is exactly
/// what low vision does not need.
struct KadeGlassBackground<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @KadeContrastPolicy private var highContrast: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency || highContrast {
            content
                .background(Color(.secondarySystemBackground), in: shape)
                .overlay(
                    shape.stroke(Color.primary.opacity(highContrast ? 0.65 : 0.18), lineWidth: highContrast ? 1.5 : 1)
                )
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    /// See `KadeGlassBackground`.
    func kadeGlass<S: Shape>(in shape: S) -> some View {
        modifier(KadeGlassBackground(shape: shape))
    }
}

// MARK: - Painted headers (C4)

/// A painted banner across the top of a page. The pictures are Kade's to make
/// (ChatGPT, then Gemini, every one described blind); until an image named
/// `imageName` is in the asset catalog, a soft gradient with the page's symbol
/// stands in, so the page never has a hole in it.
///
/// Part 292 (Sep 25 2026): silent by default. With `described: true` and words
/// in KadeArtWords, the banner is ONE VoiceOver picture element sorted after
/// the rest of the screen (the screen's stack must carry
/// `.accessibilityElement(children: .contain)` for the sort to hold), so it is
/// never ahead of the first control. High contrast, the "Painted pictures"
/// switch and a missing file all give plain colour, and then it is silent.
/// Accessibility text sizes and landscape shrink it to 60 points.
struct KadePaintedHeader: View {
    let imageName: String
    var symbol: String = "sparkles"
    var tint: Color = .indigo
    var height: CGFloat = 120
    var described: Bool = false
    @KadeContrastPolicy private var highContrast: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage(KadeArt.showKey) private var showPictures = true
    @AppStorage(KadeArt.describeKey) private var describePictures = true

    private var picture: UIImage? {
        guard showPictures, !highContrast else { return nil }
        return UIImage(named: imageName)
    }

    /// Big text and landscape leave the screen to the task (the plan's rule 27).
    private var shownHeight: CGFloat {
        typeSize.isAccessibilitySize || verticalSizeClass == .compact ? min(height, 60) : height
    }

    private var spokenWords: String? {
        guard described, describePictures, picture != nil else { return nil }
        return KadeArt.words(for: imageName)
    }

    /// The size comes from the empty frame; the picture is an overlay on it,
    /// so a scaled-to-fill image can never widen the screen it sits on.
    var body: some View {
        if let words = spokenWords {
            banner
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(words)
                .accessibilityAddTraits(.isImage)
                .accessibilitySortPriority(-1)
        } else {
            banner
                .accessibilityHidden(true)
        }
    }

    private var banner: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: shownHeight)
            .overlay { artwork }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var artwork: some View {
        if let picture {
            Image(uiImage: picture)
                .resizable()
                .scaledToFill()
                .accessibilityIgnoresInvertColors(true)
        } else {
            ZStack {
                LinearGradient(
                    colors: highContrast
                        ? [tint, tint]
                        : [tint.opacity(0.85), tint.opacity(0.45)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Image(systemName: symbol)
                    .font(.system(size: shownHeight * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(highContrast ? 1 : 0.85))
            }
        }
    }
}

// MARK: - Captioned tiles and rows (B1)

/// B1, "every tile says what it does, on screen". The home tiles' fun names
/// (The Parlor, Kade's Clubhouse, Matchmaker…) explained themselves only in
/// VoiceOver hints, so a sighted newcomer saw names and no meaning. This is the
/// two-up grid tile with a short plain caption under the title. The caption is
/// HIDDEN from VoiceOver on purpose: every tile's hint already says the same
/// thing, and hearing it twice would make the grid slower by ear, not clearer.
struct KadeCaptionedTileLabelStyle: LabelStyle {
    @KadeContrastPolicy private var highContrast: Bool
    var tint: Color
    var caption: String
    @ScaledMetric(relativeTo: .body) private var tileSide: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: tileSide * 0.24, style: .continuous)
                    .fill(highContrast ? AnyShapeStyle(tint) : AnyShapeStyle(LinearGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)))
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

            Text(caption)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

/// The full-width row version: icon tile, title with an optional caption under
/// it, an optional "2 new" badge, and the chevron. Caption, badge, tile and
/// chevron are all decorative; the Button's own label (set at the call site)
/// carries the words, including the count.
struct KadeRowLabelStyle: LabelStyle {
    @KadeContrastPolicy private var highContrast: Bool
    var tint: Color
    var caption: String? = nil
    var badge: Int = 0
    @ScaledMetric(relativeTo: .body) private var tileSide: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: tileSide * 0.24, style: .continuous)
                    .fill(highContrast ? AnyShapeStyle(tint) : AnyShapeStyle(LinearGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)))
                configuration.icon
                    .font(.system(size: min(tileSide, 48) * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: min(tileSide, 48), height: min(tileSide, 48))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                configuration.title
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
            }

            Spacer(minLength: 0)

            KadeNewBadge(count: badge)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Unread badge (B11)

/// "2 new" as a small capsule. Decorative: the row that shows it must also put
/// the count in its own accessibility label ("Announcements, 2 new").
struct KadeNewBadge: View {
    let count: Int
    @KadeContrastPolicy private var highContrast: Bool

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+ new" : "\(count) new")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(highContrast ? Color(red: 0.75, green: 0.1, blue: 0.1) : Color.red))
                .accessibilityHidden(true)
        }
    }
}
