import SwiftUI

/// Upper-body articulation underneath the existing exact-atlas face compositor.
/// The parent owns the sole timeline, power policy and performance clock.
struct CharacterConversationBodyView<Head: View>: View {
    let artwork: CharacterConversationBodyArtwork
    let side: Double
    let active: Bool
    let presentation: CharacterPresentation
    let figurePose: CharacterFigurePose
    let elapsed: Double
    let outputLevel: Double
    let performance: CharacterBodyPerformanceSample?
    private let head: Head

    init(artwork: CharacterConversationBodyArtwork, side: Double, active: Bool,
         presentation: CharacterPresentation, figurePose: CharacterFigurePose,
         elapsed: Double, outputLevel: Double, performance: CharacterBodyPerformanceSample? = nil,
         @ViewBuilder head: () -> Head) {
        self.artwork = artwork; self.side = side; self.active = active
        self.presentation = presentation; self.figurePose = figurePose
        self.elapsed = elapsed; self.outputLevel = outputLevel
        self.performance = performance; self.head = head()
    }

    var body: some View {
        let height = artwork.stageHeight(side: side)
        let pose = CharacterConversationBodyGeometry.pose(artwork: artwork, active: active,
            presentation: presentation, figurePose: figurePose, elapsed: elapsed,
            outputLevel: outputLevel, performance: performance)
        let bust = artwork.existingBust
        let neck = UnitPoint(x: (bust.neckX - bust.cropX) / bust.cropSide,
                             y: (bust.neckY - bust.cropY) / bust.cropSide)
        // Oct 16 2026: a breath raises the shoulders by `rise` points. The
        // body stretches up from the stage's lower edge, which never moves, so
        // no cloth edge opens there; the head rides on the shoulders.
        let rise = pose.breathLift * side
        let shoulderSpan = max(1, height - side * 0.86)
        ZStack(alignment: .topLeading) {
            Group {
                CharacterConversationClothing(artwork: artwork, side: side, height: height).equatable()
                CharacterConversationArms(artwork: artwork, pose: pose, side: side, height: height).equatable()
            }
            .scaleEffect(x: 1, y: 1 + rise / shoulderSpan, anchor: .bottom)
            Group {
                if artwork.kind == .kiana {
                    // The compact Kiana head remains unchanged. Only this tall
                    // body softens its lower square into the original knitting.
                    head.mask(alignment: .topLeading) {
                        CharacterConversationKianaLowerCut().fill(.white)
                            .frame(width: side * 1.08, height: side * 1.08)
                            .mask(LinearGradient(stops: [.init(color: .white, location: 0),
                                .init(color: .white, location: 0.949), .init(color: .clear, location: 0.986),
                                .init(color: .clear, location: 1)],
                                startPoint: .top, endPoint: .bottom))
                            .offset(x: -side * 0.04, y: -side * 0.04)
                    }
                } else if artwork.kind == .lilly {
                    // The atlas neck is intact through y≈289. Blend the small
                    // remaining collar edge into the original bodyplate hood,
                    // before the extended cut becomes a second oval garment.
                    // Cats remain separate original foreground overlays.
                    head.mask(alignment: .topLeading) {
                        ZStack(alignment: .topLeading) {
                            LinearGradient(stops: [.init(color: .white, location: 0),
                                .init(color: .white, location: 0.675),
                                .init(color: .clear, location: 0.714),
                                .init(color: .clear, location: 1)],
                                startPoint: .top, endPoint: .bottom)
                            // The original right hair tail reaches below the
                            // neckline. Keep only that contour over the hood;
                            // the central garment still uses the same fade.
                            CharacterConversationLillyHairTailCut(artwork: bust)
                                .fill(.white)
                                .overlay {
                                    CharacterConversationLillyHairTailCut(artwork: bust)
                                        .stroke(.white.opacity(0.45),
                                            lineWidth: side * bust.panelSide / bust.cropSide / 414 * 2)
                                }
                        }.frame(width: side, height: side)
                    }
                } else { head }
            }
                .frame(width: side, height: side)
                .rotationEffect(.degrees(pose.headDegrees), anchor: neck)
                .offset(y: pose.headLift * side - rise)
        }
        .frame(width: side, height: height, alignment: .topLeading)
        .rotationEffect(.degrees(pose.bodyDegrees),
                        anchor: UnitPoint(x: 0.5, y: 1.32 * side / height))
        .offset(y: -pose.bodyLift * side)
        .frame(width: side, height: height, alignment: .topLeading)
        .clipped()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Cloth detail is unchanged between joint samples. Equality keeps its Canvas
/// drawing out of the speaking timeline while the parent transform still moves.
private struct CharacterConversationClothing: View, Equatable {
    let artwork: CharacterConversationBodyArtwork
    let side: Double
    let height: Double
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.artwork.kind == rhs.artwork.kind && lhs.side == rhs.side && lhs.height == rhs.height
    }
    var body: some View {
        let bust = artwork.existingBust
        ZStack(alignment: .topLeading) {
            Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
                context.scaleBy(x: side, y: side)
                CharacterConversationDrawing.torso(context: &context, artwork: artwork)
            }.frame(width: side, height: height)
            if let bodyAsset = artwork.bodyAsset {
                Image(bodyAsset).resizable().interpolation(.high)
                    .frame(width: bust.bodyWidth * side / bust.cropSide,
                           height: bust.bodyHeight * side / bust.cropSide)
                    .offset(x: (bust.bodyX - bust.cropX) * side / bust.cropSide,
                            y: (bust.bodyY - bust.cropY) * side / bust.cropSide)
                    .frame(width: side, height: height, alignment: .topLeading)
                    .mask(alignment: .topLeading) {
                        CharacterConversationTorsoCut(kind: artwork.kind).fill(.white)
                            .frame(width: side, height: height)
                            .mask(alignment: .topLeading) {
                                LinearGradient(stops: [.init(color: .clear, location: 0),
                                    .init(color: .white, location: 0.075), .init(color: .white, location: 0.925),
                                    .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: side * 0.46, height: height).offset(x: side * 0.27)
                            }
                            .mask(LinearGradient(stops: [.init(color: .white, location: 0),
                                .init(color: .white, location: artwork.kind == .lilly ? 0.71 : 0.78),
                                .init(color: artwork.kind == .harley ? .white : .clear,
                                      location: artwork.kind == .lilly ? 0.78 : 0.84),
                                .init(color: artwork.kind == .harley ? .white : .clear, location: 1)],
                                startPoint: .top, endPoint: .bottom))
                    }
            }
        }
        .frame(width: side, height: height)
    }
}

private struct CharacterConversationArms: View, Equatable {
    let artwork: CharacterConversationBodyArtwork
    let pose: CharacterConversationBodyPose
    let side: Double
    let height: Double
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.artwork.kind == rhs.artwork.kind && lhs.side == rhs.side && lhs.height == rhs.height
            && lhs.pose.viewerLeft == rhs.pose.viewerLeft && lhs.pose.viewerRight == rhs.pose.viewerRight
    }
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            context.scaleBy(x: side, y: side)
            let registration = CharacterConversationBodyGeometry.registration(artwork.kind)
            CharacterConversationDrawing.arm(context: &context, pose: pose.viewerLeft,
                registration: registration, artwork: artwork, viewerLeft: true)
            CharacterConversationDrawing.arm(context: &context, pose: pose.viewerRight,
                registration: registration, artwork: artwork, viewerLeft: false)
        }.frame(width: side, height: height)
    }
}

private struct CharacterConversationKianaLowerCut: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Keep the compact head's original overdraw around the cropped crown;
        // only its bottom edge changes, before the common head transform.
        path.move(to: CGPoint(x: -0.04, y: -0.04))
        path.addLine(to: CGPoint(x: 1.04, y: -0.04))
        path.addLine(to: CGPoint(x: 1, y: 0.945))
        path.addCurve(to: CGPoint(x: 0.79, y: 0.995),
            control1: CGPoint(x: 0.95, y: 0.95), control2: CGPoint(x: 0.87, y: 0.98))
        path.addCurve(to: CGPoint(x: 0.44, y: 1.02),
            control1: CGPoint(x: 0.68, y: 1.025), control2: CGPoint(x: 0.53, y: 1.025))
        path.addCurve(to: CGPoint(x: 0.13, y: 0.935),
            control1: CGPoint(x: 0.31, y: 1.02), control2: CGPoint(x: 0.24, y: 0.98))
        path.addQuadCurve(to: CGPoint(x: 0, y: 0.865), control: CGPoint(x: 0.04, y: 0.90))
        path.closeSubpath()
        let unit = rect.width / 1.08
        return path.applying(CGAffineTransform(a: unit, b: 0, c: 0, d: unit,
            tx: unit * 0.04, ty: unit * 0.04))
    }
}

/// Original atlas hair only, with a one-pixel outer feather supplied by the mask.
/// The central hood, face and separate cats are outside this lower-tail contour.
private struct CharacterConversationLillyHairTailCut: Shape {
    let artwork: CharacterBustArtwork
    private static let atlasPath: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 242, y: 283))
        p.addCurve(to: CGPoint(x: 304, y: 282),
            control1: CGPoint(x: 260, y: 280), control2: CGPoint(x: 290, y: 278))
        p.addCurve(to: CGPoint(x: 295, y: 315),
            control1: CGPoint(x: 302, y: 293), control2: CGPoint(x: 300, y: 306))
        p.addCurve(to: CGPoint(x: 281, y: 330),
            control1: CGPoint(x: 293, y: 321), control2: CGPoint(x: 286, y: 325))
        p.addCurve(to: CGPoint(x: 274, y: 324),
            control1: CGPoint(x: 278, y: 329), control2: CGPoint(x: 276, y: 327))
        p.addCurve(to: CGPoint(x: 259, y: 313),
            control1: CGPoint(x: 269, y: 317), control2: CGPoint(x: 263, y: 315))
        p.addCurve(to: CGPoint(x: 243, y: 298),
            control1: CGPoint(x: 249, y: 307), control2: CGPoint(x: 244, y: 306))
        p.addCurve(to: CGPoint(x: 242, y: 283),
            control1: CGPoint(x: 242, y: 292), control2: CGPoint(x: 242, y: 287))
        p.closeSubpath()
        return p
    }()
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / CGFloat(artwork.cropSide)
        let scale = unit * CGFloat(artwork.panelSide) / 414
        return Self.atlasPath.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: CGFloat(artwork.panelX - artwork.cropX) * unit,
            ty: CGFloat(artwork.panelY - artwork.cropY) * unit))
    }
}

/// Only the conversation head uses this extended original neck/hood contour.
/// Compact Lilly and the separate original cat cuts retain their existing paths.
struct CharacterConversationLillyHeadCut: Shape {
    let artwork: CharacterBustArtwork
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 222, y: 22))
        p.addCurve(to: CGPoint(x: 124, y: 108), control1: CGPoint(x: 177, y: 21), control2: CGPoint(x: 137, y: 53))
        p.addLine(to: CGPoint(x: 121, y: 120)); p.addLine(to: CGPoint(x: 125, y: 128))
        p.addLine(to: CGPoint(x: 119, y: 137))
        p.addCurve(to: CGPoint(x: 94, y: 181), control1: CGPoint(x: 100, y: 145), control2: CGPoint(x: 91, y: 161))
        p.addLine(to: CGPoint(x: 98, y: 197))
        p.addCurve(to: CGPoint(x: 58, y: 223), control1: CGPoint(x: 80, y: 205), control2: CGPoint(x: 66, y: 212))
        p.addCurve(to: CGPoint(x: 78, y: 250), control1: CGPoint(x: 56, y: 236), control2: CGPoint(x: 66, y: 246))
        p.addLine(to: CGPoint(x: 103, y: 253)); p.addLine(to: CGPoint(x: 126, y: 260))
        // Keep the actual original neckline and hood below the compact head cut.
        // Stay inside the two cat silhouettes; their exact static foreground
        // pixels are supplied once by the parent, never by this moving hood.
        p.addLine(to: CGPoint(x: 143, y: 280))
        p.addCurve(to: CGPoint(x: 155, y: 330), control1: CGPoint(x: 163, y: 291), control2: CGPoint(x: 149, y: 314))
        p.addCurve(to: CGPoint(x: 198, y: 382), control1: CGPoint(x: 158, y: 355), control2: CGPoint(x: 178, y: 369))
        p.addQuadCurve(to: CGPoint(x: 252, y: 378), control: CGPoint(x: 228, y: 397))
        p.addCurve(to: CGPoint(x: 294, y: 321), control1: CGPoint(x: 272, y: 361), control2: CGPoint(x: 284, y: 336))
        p.addLine(to: CGPoint(x: 305, y: 300)); p.addLine(to: CGPoint(x: 319, y: 278))
        p.addLine(to: CGPoint(x: 331, y: 257)); p.addLine(to: CGPoint(x: 351, y: 244))
        p.addCurve(to: CGPoint(x: 375, y: 203), control1: CGPoint(x: 369, y: 234), control2: CGPoint(x: 378, y: 221))
        p.addCurve(to: CGPoint(x: 353, y: 151), control1: CGPoint(x: 374, y: 186), control2: CGPoint(x: 357, y: 172))
        p.addCurve(to: CGPoint(x: 340, y: 83), control1: CGPoint(x: 355, y: 129), control2: CGPoint(x: 347, y: 107))
        p.addCurve(to: CGPoint(x: 296, y: 35), control1: CGPoint(x: 334, y: 59), control2: CGPoint(x: 315, y: 42))
        p.addLine(to: CGPoint(x: 279, y: 38))
        p.addCurve(to: CGPoint(x: 222, y: 22), control1: CGPoint(x: 261, y: 29), control2: CGPoint(x: 241, y: 23))
        p.closeSubpath()
        let unit = rect.width / CGFloat(artwork.cropSide)
        let scale = unit * CGFloat(artwork.panelSide) / 414
        return p.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: CGFloat(artwork.panelX - artwork.cropX) * unit, ty: CGFloat(artwork.panelY - artwork.cropY) * unit))
    }
}

private struct CharacterConversationTorsoCut: Shape {
    let kind: CharacterConversationBodyArtwork.Kind
    func path(in rect: CGRect) -> Path {
        (CharacterConversationDrawing.sourceTorsoPaths[kind] ?? Path())
            .applying(CGAffineTransform(scaleX: rect.width,
                y: rect.width))
    }
}

/// A few authored paths, gradients and seam strokes. No generated textures,
/// offscreen blur, pixel extraction or separate animation state is involved.
private enum CharacterConversationDrawing {
    typealias Point = CharacterConversationPoint
    typealias Kind = CharacterConversationBodyArtwork.Kind
    struct Palette {
        let cloth: Color
        let clothLight: Color
        let clothDark: Color
        let skin: Color
        let skinLight: Color
        let skinDark: Color
    }

    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    static func palette(_ kind: Kind) -> Palette {
        switch kind {
        case .kiana:
            return Palette(cloth: color(0xD8D0C9), clothLight: color(0xF0E8E1), clothDark: color(0xB3A399),
                skin: color(0xBA8062), skinLight: color(0xD59B7C), skinDark: color(0x925D43))
        case .harley:
            return Palette(cloth: color(0x5B7689), clothLight: color(0x8299A7), clothDark: color(0x344C60),
                skin: color(0xD7A17F), skinLight: color(0xECC1A0), skinDark: color(0xA36D50))
        case .lilly:
            return Palette(cloth: color(0xD979A3), clothLight: color(0xEEA7C4), clothDark: color(0xB65380),
                skin: color(0xE4AF93), skinLight: color(0xF1CBB1), skinDark: color(0xB98268))
        case .witherspoon:
            return Palette(cloth: color(0x354E41), clothLight: color(0x5B7361), clothDark: color(0x20372D),
                skin: color(0xD5A489), skinLight: color(0xEAC5AE), skinDark: color(0xA77B62))
        }
    }

    static func cg(_ point: Point) -> CGPoint { CGPoint(x: point.x, y: point.y) }
    static func normal(_ vector: Point) -> Point {
        let length = max(0.000001, vector.length)
        return Point(x: -vector.y / length, y: vector.x / length)
    }
    static func times(_ point: Point, _ scale: Double) -> Point {
        Point(x: point.x * scale, y: point.y * scale)
    }
    static func blend(_ a: Point, _ b: Point, _ fraction: Double) -> Point {
        a + times(b - a, fraction)
    }

    /// Reuse a cloth-only rectangle as an image drawing, never as a new bitmap.
    /// Original source pixels outside this rectangle are clipped before drawing.
    static func material(context: inout GraphicsContext, path: Path,
                         patch: CharacterConversationBodyArtwork.MaterialPatch,
                         tiled: Bool, mirrored: Bool = false, tileWidth: Double = 0.16, opacity: Double = 1) {
        let bounds = path.boundingRect
        guard patch.isValid, !bounds.isEmpty else { return }
        var cloth = context
        cloth.clip(to: path)
        cloth.opacity *= opacity
        if tiled && !mirrored {
            // One native tiled fill for moving cloth. The ROI is unit-space;
            // scale keeps the original weave at its registered portrait size.
            cloth.fill(path, with: .tiledImage(Image(patch.asset),
                origin: CGPoint(x: bounds.minX, y: bounds.minY),
                sourceRect: CGRect(x: patch.x / patch.imageWidth, y: patch.y / patch.imageHeight,
                    width: patch.width / patch.imageWidth, height: patch.height / patch.imageHeight),
                scale: CGFloat(tileWidth / patch.width)))
            return
        }
        let image = cloth.resolve(Image(patch.asset))
        func draw(_ target: CGRect, in context: GraphicsContext, mirrorX: Bool = false, mirrorY: Bool = false) {
            var sample = context
            sample.clip(to: Path(target))
            if mirrorX || mirrorY {
                // Adjacent reflected windows share the identical edge pixels.
                // This avoids a checkerboard lighting seam without a new texture.
                sample.translateBy(x: target.midX, y: target.midY)
                sample.scaleBy(x: mirrorX ? -1 : 1, y: mirrorY ? -1 : 1)
                sample.translateBy(x: -target.midX, y: -target.midY)
            }
            let sx = target.width / patch.width, sy = target.height / patch.height
            sample.draw(image, in: CGRect(x: target.minX - patch.x * sx,
                y: target.minY - patch.y * sy, width: patch.imageWidth * sx, height: patch.imageHeight * sy))
        }
        if tiled {
            // The static cloth layer is equatable. Keep original weave scale,
            // with a fixed finite tile count rather than a per-frame texture build.
            let width = CGFloat(tileWidth), height = width * patch.height / patch.width
            let rows = min(16, Int(ceil(bounds.height / height)))
            let columns = min(16, Int(ceil(bounds.width / width)))
            for row in 0..<rows {
                for column in 0..<columns {
                    draw(CGRect(x: bounds.minX + CGFloat(column) * width,
                                y: bounds.minY + CGFloat(row) * height, width: width, height: height),
                         in: cloth, mirrorX: column % 2 == 1, mirrorY: row % 2 == 1)
                }
            }
        } else { draw(bounds, in: cloth) }
    }

    /// The lower torso continues the original crop to the common tall edge.
    /// Broad shoulder underpaint hides seams beneath the head's original hair
    /// and neckline. The Kiana continuation contains no supporting bitmap.
    static func torsoPath(_ kind: Kind) -> Path {
        var p = Path()
        let kiana = kind == .kiana
        let neckY = kind == .lilly ? 0.64 : 0.76
        p.move(to: CGPoint(x: 0.43, y: neckY))
        p.addCurve(to: CGPoint(x: kiana ? 0.10 : 0.20, y: 0.93),
            control1: CGPoint(x: 0.31, y: 0.79), control2: CGPoint(x: 0.18, y: 0.83))
        p.addCurve(to: CGPoint(x: kiana ? 0.002 : 0.17, y: 1.04),
            control1: CGPoint(x: kiana ? 0.04 : 0.15, y: 0.99),
            control2: CGPoint(x: kiana ? 0.002 : 0.16, y: 1.02))
        p.addCurve(to: CGPoint(x: 0.20, y: 1.4976),
            control1: CGPoint(x: 0.13, y: 1.22), control2: CGPoint(x: 0.17, y: 1.40))
        p.addLine(to: CGPoint(x: 0.80, y: 1.4976))
        p.addCurve(to: CGPoint(x: kiana ? 0.998 : 0.83, y: 1.04),
            control1: CGPoint(x: 0.83, y: 1.40), control2: CGPoint(x: 0.87, y: 1.22))
        p.addCurve(to: CGPoint(x: kiana ? 0.90 : 0.80, y: 0.93),
            control1: CGPoint(x: kiana ? 0.998 : 0.84, y: 1.02),
            control2: CGPoint(x: kiana ? 0.96 : 0.85, y: 0.99))
        p.addCurve(to: CGPoint(x: 0.57, y: neckY),
            control1: CGPoint(x: 0.82, y: 0.83), control2: CGPoint(x: 0.69, y: 0.79))
        p.closeSubpath()
        return p
    }

    static let torsoPaths: [Kind: Path] = Dictionary(uniqueKeysWithValues:
        Kind.allCases.map { ($0, torsoPath($0)) })

    static func sourceTorso(_ kind: Kind) -> Path {
        // Harley's source hands begin much farther down; the other plates have
        // closer fused anatomy. End those cuts before any such pixels enter.
        let end: Double = kind == .lilly ? 1.17 : (kind == .witherspoon ? 1.26 : 1.4976)
        var p = Path()
        let start: Double = kind == .lilly ? 0.61 : 0.72
        p.move(to: CGPoint(x: 0.43, y: start))
        p.addQuadCurve(to: CGPoint(x: 0.27, y: 0.91), control: CGPoint(x: 0.30, y: 0.76))
        p.addLine(to: CGPoint(x: 0.27, y: end - 0.025))
        p.addQuadCurve(to: CGPoint(x: 0.73, y: end - 0.025), control: CGPoint(x: 0.50, y: end + 0.025))
        p.addLine(to: CGPoint(x: 0.73, y: 0.91))
        p.addQuadCurve(to: CGPoint(x: 0.57, y: start), control: CGPoint(x: 0.70, y: 0.76))
        p.closeSubpath()
        return p
    }

    static let sourceTorsoPaths: [Kind: Path] = Dictionary(uniqueKeysWithValues:
        Kind.allCases.map { ($0, sourceTorso($0)) })

    static let hoodiePouch: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.32, y: 1.22))
        p.addQuadCurve(to: CGPoint(x: 0.28, y: 1.41), control: CGPoint(x: 0.29, y: 1.31))
        p.addQuadCurve(to: CGPoint(x: 0.72, y: 1.41), control: CGPoint(x: 0.50, y: 1.45))
        p.addQuadCurve(to: CGPoint(x: 0.68, y: 1.22), control: CGPoint(x: 0.71, y: 1.31))
        return p
    }()

    static let tee: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.44, y: 0.86)); p.addLine(to: CGPoint(x: 0.56, y: 0.86))
        p.addLine(to: CGPoint(x: 0.59, y: 1.50)); p.addLine(to: CGPoint(x: 0.41, y: 1.50))
        p.closeSubpath()
        return p
    }()

    static let blouse: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.44, y: 0.83)); p.addLine(to: CGPoint(x: 0.57, y: 0.83))
        p.addCurve(to: CGPoint(x: 0.65, y: 1.50),
            control1: CGPoint(x: 0.63, y: 1.05), control2: CGPoint(x: 0.64, y: 1.27))
        p.addLine(to: CGPoint(x: 0.345, y: 1.50))
        p.addCurve(to: CGPoint(x: 0.44, y: 0.83),
            control1: CGPoint(x: 0.35, y: 1.27), control2: CGPoint(x: 0.38, y: 1.02))
        p.closeSubpath(); return p
    }()

    static func torso(context: inout GraphicsContext, artwork: CharacterConversationBodyArtwork) {
        let kind = artwork.kind
        let colors = palette(kind)
        guard let path = torsoPaths[kind] else { return }
        context.fill(path, with: .linearGradient(Gradient(colors:
            [colors.clothDark, colors.clothLight, colors.cloth, colors.clothDark]),
            startPoint: CGPoint(x: 0.12, y: 1), endPoint: CGPoint(x: 0.93, y: 1.4)))
        material(context: &context, path: path, patch: artwork.fabric, tiled: true,
                 mirrored: true, tileWidth: kind == .kiana ? 0.087 : (kind == .lilly ? 0.115 : 0.16))
        context.fill(path, with: .linearGradient(Gradient(colors: [.black.opacity(0.19), .clear,
            .clear, .black.opacity(0.22)]), startPoint: CGPoint(x: 0.15, y: 1.1),
            endPoint: CGPoint(x: 0.87, y: 1.1)))
        var detail = context
        detail.clip(to: path)
        if let shirt = artwork.shirtFabric {
            material(context: &detail, path: blouse, patch: shirt, tiled: true, mirrored: true, tileWidth: 0.076)
            // Continue the same original blouse beneath its safe central cut,
            // avoiding both the plate's book/hands and a horizontal green seam.
            for y in [1.29, 1.44] {
                let button = Path(ellipseIn: CGRect(x: 0.49, y: y, width: 0.023, height: 0.023))
                detail.fill(button, with: .color(color(0xDFCEB6)))
                detail.stroke(button, with: .color(color(0xB9A48C).opacity(0.45)), lineWidth: 0.0015)
            }
        } else if kind == .lilly {
            detail.stroke(hoodiePouch, with: .color(colors.clothDark.opacity(0.42)),
                style: StrokeStyle(lineWidth: 0.005, lineCap: .round))
        } else if kind == .harley {
            detail.fill(tee, with: .linearGradient(Gradient(colors: [color(0xD9D8D1), color(0xF0F0E9)]),
                startPoint: CGPoint(x: 0.43, y: 1), endPoint: CGPoint(x: 0.57, y: 1.5)))
        }
    }

    /// Smooth single sleeve outline, including a rounded shoulder and elbow.
    /// Adjacent segment normals meet at the same joint, never as floating parts.
    static func sleeve(_ arm: CharacterConversationArm, upperRadius: Double,
                       lowerRadius: Double, roundedShoulder: Bool = false) -> Path {
        let s = arm.shoulder, e = arm.elbow, w = arm.wrist
        let upper = e - s, lower = w - e
        let n1 = normal(upper), n2 = normal(lower)
        let normalSum = n1 + n2
        let ne = times(normalSum, 1 / max(0.000001, normalSum.length))
        let elbowRadius = upperRadius * 0.78
        let tangentSum = times(upper, 1 / max(0.000001, upper.length))
            + times(lower, 1 / max(0.000001, lower.length))
        let tangent = times(tangentSum, 1 / max(0.000001, tangentSum.length))
        let curve = times(tangent, min(upper.length, lower.length) * 0.27)
        let so = s + times(n1, upperRadius), si = s - times(n1, upperRadius)
        let eo = e + times(ne, elbowRadius), ei = e - times(ne, elbowRadius)
        let wo = w + times(n2, lowerRadius), wi = w - times(n2, lowerRadius)
        var p = Path()
        p.move(to: cg(so))
        p.addCurve(to: cg(eo), control1: cg(so + times(upper, 0.38)),
            control2: cg(eo - curve))
        p.addCurve(to: cg(wo), control1: cg(eo + curve),
            control2: cg(wo - times(lower, 0.26)))
        p.addQuadCurve(to: cg(wi), control: cg(w + times(lower, 0.06)))
        p.addCurve(to: cg(ei), control1: cg(wi - times(lower, 0.26)),
            control2: cg(ei + curve))
        p.addCurve(to: cg(si), control1: cg(ei - curve),
            control2: cg(si + times(upper, 0.35)))
        if roundedShoulder {
            // Two quarter-circle cubics meet both sleeve edges along the upper
            // bone. Lilly's soft hoodie cap has no diagonal corner at its join.
            let direction = times(upper, 1 / max(0.000001, upper.length))
            let apex = s - times(direction, upperRadius)
            let tangentRadius = upperRadius * 0.5522847498307936
            p.addCurve(to: cg(apex), control1: cg(si - times(direction, tangentRadius)),
                control2: cg(apex - times(n1, tangentRadius)))
            p.addCurve(to: cg(so), control1: cg(apex + times(n1, tangentRadius)),
                control2: cg(so - times(direction, tangentRadius)))
        } else {
            p.addQuadCurve(to: cg(so), control: cg(s - times(upper, 0.25)))
        }
        p.closeSubpath()
        return p
    }

    static func arm(context: inout GraphicsContext, pose: CharacterConversationArm,
                    registration: CharacterConversationBodyGeometry.Registration,
                    artwork: CharacterConversationBodyArtwork, viewerLeft: Bool) {
        let kind = artwork.kind
        let colors = palette(kind)
        let radius = registration.upperRadius
        let lower = pose.wrist - pose.elbow
        let sleeveEnd = kind == .harley ? blend(pose.elbow, pose.wrist, 0.25) : pose.wrist
        let sleevePose = CharacterConversationArm(shoulder: pose.shoulder, elbow: pose.elbow,
            wrist: sleeveEnd, shoulderDegrees: pose.shoulderDegrees, elbowDegrees: pose.elbowDegrees,
            wristDegrees: pose.wristDegrees, handDegrees: pose.handDegrees, openness: pose.openness)
        if kind == .harley {
            let bare = sleeve(pose, upperRadius: radius * 0.77, lowerRadius: 0.031)
            context.fill(bare, with: .linearGradient(Gradient(colors:
                [colors.skinDark, colors.skinLight, colors.skin]),
                startPoint: cg(pose.elbow + Point(x: -0.06, y: 0)),
                endPoint: cg(pose.wrist + Point(x: 0.05, y: 0))))
            material(context: &context, path: bare, patch: artwork.skin, tiled: false, opacity: 0.55)
        }
        let cloth = sleeve(sleevePose, upperRadius: radius, lowerRadius: registration.lowerRadius,
                           roundedShoulder: kind == .lilly)
        context.fill(cloth, with: .linearGradient(Gradient(colors:
            [colors.clothDark, colors.clothLight, colors.cloth, colors.clothDark]),
            startPoint: cg(pose.shoulder + Point(x: -radius, y: 0)),
            endPoint: cg(pose.wrist + Point(x: radius, y: 0))))
        material(context: &context, path: cloth, patch: artwork.fabric,
                 tiled: kind == .kiana, tileWidth: 0.087)
        context.fill(cloth, with: .linearGradient(Gradient(colors:
            [.black.opacity(0.26), .clear, .white.opacity(0.07), .black.opacity(0.20)]),
            startPoint: cg(pose.shoulder + Point(x: -radius, y: 0)),
            endPoint: cg(pose.wrist + Point(x: radius, y: 0))))
        var seam = Path()
        let n = normal(pose.elbow - pose.shoulder)
        seam.move(to: cg(pose.shoulder + times(n, radius * 0.60)))
        seam.addQuadCurve(to: cg(pose.elbow + times(n, radius * 0.51)),
            control: cg(blend(pose.shoulder, pose.elbow, 0.55) + times(n, radius * 0.65)))
        context.stroke(seam, with: .color(colors.clothDark.opacity(0.18)),
            style: StrokeStyle(lineWidth: 0.002, lineCap: .round))
        let cuffVector = times(lower, 0.13)
        let cuffNormal = times(normal(lower), registration.lowerRadius * 1.06)
        var cuff = Path()
        cuff.move(to: cg(sleeveEnd + cuffNormal)); cuff.addLine(to: cg(sleeveEnd - cuffNormal))
        cuff.addQuadCurve(to: cg(sleeveEnd - cuffVector - cuffNormal),
            control: cg(sleeveEnd - times(cuffNormal, 1.08) - times(cuffVector, 0.5)))
        cuff.addLine(to: cg(sleeveEnd - cuffVector + cuffNormal)); cuff.closeSubpath()
        context.fill(cuff, with: .linearGradient(Gradient(colors:
            [colors.clothDark, colors.cloth, colors.clothLight]),
            startPoint: cg(sleeveEnd - cuffNormal), endPoint: cg(sleeveEnd + cuffNormal)))
        material(context: &context, path: cuff, patch: artwork.fabric, tiled: false)
        context.fill(cuff, with: .color(.white.opacity(kind == .harley ? 0.25 : 0.08)))
        context.stroke(cuff, with: .color(colors.clothDark.opacity(0.18)), lineWidth: 0.0015)
        hand(context: &context, pose: pose, scale: registration.handScale,
             colors: colors, skin: artwork.skin, viewerLeft: viewerLeft)
    }

    /// One continuous wrist/palm/five-digit outline. Thumb handedness is
    /// mirrored with its whole hand; no independent finger or floating palm.
    static func handPath(openness: Double) -> Path {
        let amount = min(1, max(0, openness))
        let spread = 0.78 + amount * 0.22
        // Relaxed distal fingers curl toward the palm and shorten in projection.
        // The thumb/palm/wrist never shrink; the continuous chain stays attached.
        let extensionAmount = 0.52 + amount * 0.48
        func q(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: x * spread, y: y > 0.72 ? 0.72 + (y - 0.72) * extensionAmount : y)
        }
        var p = Path()
        p.move(to: q(-0.21, -0.12))
        p.addQuadCurve(to: q(-0.29, 0.30), control: q(-0.21, 0.15))
        p.addCurve(to: q(-0.58, 0.47), control1: q(-0.39, 0.30), control2: q(-0.50, 0.38))
        p.addQuadCurve(to: q(-0.57, 0.67), control: q(-0.71, 0.61))
        p.addQuadCurve(to: q(-0.30, 0.53), control: q(-0.43, 0.67))
        p.addLine(to: q(-0.29, 1.07))
        p.addCurve(to: q(-0.14, 1.10), control1: q(-0.30, 1.23), control2: q(-0.14, 1.24))
        p.addLine(to: q(-0.10, 0.77))
        p.addLine(to: q(-0.08, 1.20))
        p.addCurve(to: q(0.09, 1.22), control1: q(-0.07, 1.37), control2: q(0.09, 1.38))
        p.addLine(to: q(0.12, 0.79))
        p.addLine(to: q(0.15, 1.14))
        p.addCurve(to: q(0.31, 1.13), control1: q(0.18, 1.30), control2: q(0.32, 1.29))
        p.addLine(to: q(0.32, 0.77))
        p.addLine(to: q(0.36, 0.98))
        p.addCurve(to: q(0.48, 0.94), control1: q(0.40, 1.13), control2: q(0.51, 1.08))
        p.addCurve(to: q(0.36, 0.39), control1: q(0.48, 0.74), control2: q(0.40, 0.53))
        p.addQuadCurve(to: q(0.21, -0.12), control: q(0.21, 0.20))
        p.closeSubpath()
        return p
    }

    static func hand(context: inout GraphicsContext, pose: CharacterConversationArm,
                     scale: Double, colors: Palette,
                     skin: CharacterConversationBodyArtwork.MaterialPatch, viewerLeft: Bool) {
        var local = context
        local.translateBy(x: pose.wrist.x, y: pose.wrist.y)
        local.rotate(by: .degrees(pose.handDegrees))
        local.scaleBy(x: (viewerLeft ? -1 : 1) * scale, y: scale)
        let path = handPath(openness: pose.openness)
        local.fill(path, with: .linearGradient(Gradient(colors:
            [colors.skinDark, colors.skin, colors.skinLight, colors.skin]),
            startPoint: CGPoint(x: -0.55, y: 0.25), endPoint: CGPoint(x: 0.50, y: 0.80)))
        material(context: &local, path: path, patch: skin, tiled: false, opacity: 0.60)
        local.stroke(path, with: .color(colors.skinDark.opacity(0.22)),
            style: StrokeStyle(lineWidth: 0.012, lineJoin: .round))
        var palm = Path()
        palm.move(to: CGPoint(x: -0.16, y: 0.34))
        palm.addQuadCurve(to: CGPoint(x: 0.24, y: 0.56), control: CGPoint(x: 0.10, y: 0.39))
        palm.move(to: CGPoint(x: -0.14, y: 0.52))
        palm.addQuadCurve(to: CGPoint(x: 0.19, y: 0.68), control: CGPoint(x: 0.04, y: 0.57))
        palm.move(to: CGPoint(x: -0.27, y: 0.37))
        palm.addQuadCurve(to: CGPoint(x: -0.08, y: 0.68), control: CGPoint(x: -0.08, y: 0.39))
        local.stroke(palm, with: .color(colors.skinDark.opacity(0.14)),
            style: StrokeStyle(lineWidth: 0.014, lineCap: .round))
    }
}
