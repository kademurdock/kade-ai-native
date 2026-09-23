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

/// A painted banner across the top of a tab page. The pictures are Kade's to
/// make (ChatGPT, the way the face sheets were made); until an image named
/// `imageName` is in the asset catalog, a soft gradient with the page's symbol
/// stands in, so the page never has a hole in it. Always decorative.
struct KadePaintedHeader: View {
    let imageName: String
    var symbol: String = "sparkles"
    var tint: Color = .indigo
    var height: CGFloat = 120
    @KadeContrastPolicy private var highContrast: Bool

    var body: some View {
        Group {
            if let picture = UIImage(named: imageName) {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: highContrast
                            ? [tint, tint]
                            : [tint.opacity(0.85), tint.opacity(0.45)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: symbol)
                        .font(.system(size: height * 0.42, weight: .semibold))
                        .foregroundStyle(.white.opacity(highContrast ? 1 : 0.85))
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityHidden(true)
        .allowsHitTesting(false)
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
