import SwiftUI
import UIKit

// MARK: - Family history: a picture drawn whole (Sep 29 2026)
//
// FamilyPhoto (FamilyImages.swift) draws a square: a face, a thumbnail. This
// draws a picture at its own shape, across the width it is given and at most
// `height` high: the reel's cards, Home's featured card and portrait, a
// person's header, the slideshow. While it loads, or if it cannot be had,
// its words stay on a soft panel (never an empty frame). Always hidden from
// VoiceOver: the card or element it sits in carries the alt text. Smart
// Invert leaves it alone.
//
// `panning` gives a person's header its slow pan-and-zoom drift, only while
// motion is allowed (@KadeMotionPolicy covers Reduce Motion, VoiceOver, Low
// Power and an inactive app); otherwise the picture stands still.

struct FamilyWidePhoto: View {
    let image: FHImage?
    var size: FHSize = .s
    let height: CGFloat
    /// The longest side it may be drawn at, in points (decoded to that many
    /// pixels, never the whole file).
    var longSide: CGFloat = 700
    /// Fill the box (cropping), rather than fit inside it.
    var fill: Bool = false
    var panning: Bool = false

    @Environment(\.displayScale) private var displayScale
    @KadeMotionPolicy private var motionAllowed: Bool
    @State private var loaded: Loaded?

    private struct Loaded {
        let key: String
        let picture: UIImage
    }

    private var pixels: Int {
        let scaled: CGFloat = longSide * max(1, displayScale)
        return max(64, Int(scaled.rounded(.up)))
    }

    private var chosen: FHSize { image?.best(size) ?? size }

    private var key: String { "\(image?.id ?? "").\(chosen.rawValue).\(pixels)" }

    var body: some View {
        let mine: UIImage? = loaded?.key == key ? loaded?.picture : nil
        let picture: UIImage? = mine ?? cachedPicture
        framed(picture)
            .accessibilityHidden(true)
            .accessibilityIgnoresInvertColors(true)
            .task(id: key) {
                await load(already: picture != nil)
            }
    }

    @MainActor
    private var cachedPicture: UIImage? {
        guard let image else { return nil }
        return FamilyImageLoader.shared.cached(image, size: chosen, pixels: pixels)
    }

    private func framed(_ picture: UIImage?) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay { content(picture) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func content(_ picture: UIImage?) -> some View {
        if let picture {
            if panning && motionAllowed {
                FamilyPanningImage(picture: picture, fill: fill)
            } else {
                Image(uiImage: picture)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            }
        } else {
            FamilyPictureWords(words: image?.short ?? image?.caption ?? "")
        }
    }

    @MainActor
    private func load(already: Bool) async {
        if already { return }
        guard let image, !image.id.isEmpty else { return }
        let wanted = key
        let picture = await FamilyImageLoader.shared.image(for: image, size: chosen, pixels: pixels)
        if Task.isCancelled { return }
        if let picture { loaded = Loaded(key: wanted, picture: picture) }
    }
}

/// The slow drift: its own view, so turning motion off removes it whole
/// (a repeating animation cannot linger on a view that is gone).
struct FamilyPanningImage: View {
    let picture: UIImage
    let fill: Bool
    @State private var drifted = false

    var body: some View {
        Image(uiImage: picture)
            .resizable()
            .aspectRatio(contentMode: fill ? .fill : .fit)
            .scaleEffect(drifted ? 1.08 : 1.0)
            .offset(x: drifted ? 8 : -8)
            .task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) {
                    drifted = true
                }
            }
    }
}

/// A picture's words on a soft panel, while it loads or when it cannot be had.
struct FamilyPictureWords: View {
    let words: String

    var body: some View {
        ZStack {
            Rectangle().fill(Color(.secondarySystemBackground))
            VStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                if !words.isEmpty {
                    Text(words)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 12)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
