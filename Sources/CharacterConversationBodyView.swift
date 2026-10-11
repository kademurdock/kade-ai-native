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
        ZStack(alignment: .topLeading) {
            CharacterConversationStaticTorso(kind: artwork.kind, side: side, height: height)
                .equatable()
            if let bodyAsset = artwork.bodyAsset {
                // A precise central clothing cut excludes every fused original
                // sleeve/forearm/hand and the plate's diffuse alpha halo.
                Image(bodyAsset).resizable().interpolation(.high)
                    .frame(width: bust.bodyWidth * side / bust.cropSide,
                           height: bust.bodyHeight * side / bust.cropSide)
                    .offset(x: (bust.bodyX - bust.cropX) * side / bust.cropSide,
                            y: (bust.bodyY - bust.cropY) * side / bust.cropSide)
                    .frame(width: side, height: height, alignment: .topLeading)
                    .clipShape(CharacterConversationTorsoCut(kind: artwork.kind))
            }
            Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
                context.scaleBy(x: side, y: side)
                let registration = CharacterConversationBodyGeometry.registration(artwork.kind)
                CharacterConversationDrawing.arm(context: &context, pose: pose.viewerLeft,
                    registration: registration, kind: artwork.kind, viewerLeft: true)
                CharacterConversationDrawing.arm(context: &context, pose: pose.viewerRight,
                    registration: registration, kind: artwork.kind, viewerLeft: false)
            }
            .frame(width: side, height: height)
            head.frame(width: side, height: side)
                .rotationEffect(.degrees(pose.headDegrees), anchor: neck)
                .offset(y: pose.headLift * side)
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
private struct CharacterConversationStaticTorso: View, Equatable {
    let kind: CharacterConversationBodyArtwork.Kind
    let side: Double
    let height: Double
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            context.scaleBy(x: side, y: side)
            CharacterConversationDrawing.torso(context: &context, kind: kind)
        }
        .frame(width: side, height: height)
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
            return Palette(cloth: color(0xD3C5B5), clothLight: color(0xE8DFD0), clothDark: color(0xA99381),
                skin: color(0xA26D50), skinLight: color(0xBF8966), skinDark: color(0x71472F))
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

    /// The lower torso continues the original crop to the common tall edge.
    /// Broad shoulder underpaint hides seams beneath the head's original hair
    /// and neckline. The Kiana continuation contains no supporting bitmap.
    static func torsoPath(_ kind: Kind) -> Path {
        var p = Path()
        let kiana = kind == .kiana
        p.move(to: CGPoint(x: 0.43, y: 0.76))
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
        p.addCurve(to: CGPoint(x: 0.57, y: 0.76),
            control1: CGPoint(x: 0.82, y: 0.83), control2: CGPoint(x: 0.69, y: 0.79))
        p.closeSubpath()
        return p
    }

    static let torsoPaths: [Kind: Path] = Dictionary(uniqueKeysWithValues:
        Kind.allCases.map { ($0, torsoPath($0)) })

    static func sourceTorso(_ kind: Kind) -> Path {
        // Harley's source hands begin much farther down; the other plates have
        // closer fused anatomy. End those cuts before any such pixels enter.
        let end: Double = kind == .lilly ? 1.18 : (kind == .witherspoon ? 1.26 : 1.4976)
        var p = Path()
        p.move(to: CGPoint(x: 0.43, y: 0.72))
        p.addQuadCurve(to: CGPoint(x: 0.27, y: 0.91), control: CGPoint(x: 0.30, y: 0.76))
        p.addLine(to: CGPoint(x: 0.27, y: end))
        p.addLine(to: CGPoint(x: 0.73, y: end))
        p.addLine(to: CGPoint(x: 0.73, y: 0.91))
        p.addQuadCurve(to: CGPoint(x: 0.57, y: 0.72), control: CGPoint(x: 0.70, y: 0.76))
        p.closeSubpath()
        return p
    }

    static let sourceTorsoPaths: [Kind: Path] = Dictionary(uniqueKeysWithValues:
        Kind.allCases.map { ($0, sourceTorso($0)) })

    static let knitRibs: [Path] = (0..<18).map { index in
        let x = 0.16 + Double(index) * 0.04
        var rib = Path()
        rib.move(to: CGPoint(x: x, y: 0.96))
        rib.addCurve(to: CGPoint(x: x + 0.015, y: 1.50),
            control1: CGPoint(x: x - 0.018, y: 1.14), control2: CGPoint(x: x + 0.012, y: 1.32))
        return rib
    }

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

    static func torso(context: inout GraphicsContext, kind: Kind) {
        let colors = palette(kind)
        guard let path = torsoPaths[kind] else { return }
        context.fill(path, with: .linearGradient(Gradient(colors:
            [colors.clothDark, colors.clothLight, colors.cloth, colors.clothDark]),
            startPoint: CGPoint(x: 0.12, y: 1), endPoint: CGPoint(x: 0.93, y: 1.4)))
        var detail = context
        detail.clip(to: path)
        if kind == .kiana || kind == .witherspoon {
            // Ribbed knitting follows the garment vertically; a low contrast
            // stroke survives phone scale without a noisy high-frequency mesh.
            for rib in knitRibs {
                detail.stroke(rib, with: .color(colors.clothDark.opacity(0.18)), lineWidth: 0.003)
                detail.stroke(rib.offsetBy(dx: 0.004, dy: 0),
                    with: .color(colors.clothLight.opacity(0.32)), lineWidth: 0.002)
            }
        } else if kind == .lilly {
            detail.stroke(hoodiePouch, with: .color(colors.clothDark.opacity(0.42)),
                style: StrokeStyle(lineWidth: 0.005, lineCap: .round))
        } else {
            detail.fill(tee, with: .linearGradient(Gradient(colors: [color(0xD9D8D1), color(0xF0F0E9)]),
                startPoint: CGPoint(x: 0.43, y: 1), endPoint: CGPoint(x: 0.57, y: 1.5)))
        }
    }

    /// Smooth single sleeve outline, including a rounded shoulder and elbow.
    /// Adjacent segment normals meet at the same joint, never as floating parts.
    static func sleeve(_ arm: CharacterConversationArm, upperRadius: Double,
                       lowerRadius: Double) -> Path {
        let s = arm.shoulder, e = arm.elbow, w = arm.wrist
        let upper = e - s, lower = w - e
        let n1 = normal(upper), n2 = normal(lower)
        let normalSum = n1 + n2
        let ne = times(normalSum, 1 / max(0.000001, normalSum.length))
        let elbowRadius = upperRadius * 0.83
        let so = s + times(n1, upperRadius), si = s - times(n1, upperRadius)
        let eo = e + times(ne, elbowRadius), ei = e - times(ne, elbowRadius)
        let wo = w + times(n2, lowerRadius), wi = w - times(n2, lowerRadius)
        var p = Path()
        p.move(to: cg(so))
        p.addCurve(to: cg(eo), control1: cg(so + times(upper, 0.38)),
            control2: cg(eo - times(upper, 0.28)))
        p.addCurve(to: cg(wo), control1: cg(eo + times(lower, 0.32)),
            control2: cg(wo - times(lower, 0.26)))
        p.addQuadCurve(to: cg(wi), control: cg(w + times(lower, 0.06)))
        p.addCurve(to: cg(ei), control1: cg(wi - times(lower, 0.26)),
            control2: cg(ei + times(lower, 0.24)))
        p.addCurve(to: cg(si), control1: cg(ei - times(upper, 0.25)),
            control2: cg(si + times(upper, 0.35)))
        p.addQuadCurve(to: cg(so), control: cg(s - times(upper, 0.25)))
        p.closeSubpath()
        return p
    }

    static func arm(context: inout GraphicsContext, pose: CharacterConversationArm,
                    registration: CharacterConversationBodyGeometry.Registration,
                    kind: Kind, viewerLeft: Bool) {
        let colors = palette(kind)
        let radius = registration.upperRadius
        let lower = pose.wrist - pose.elbow
        let sleeveEnd = kind == .harley ? blend(pose.elbow, pose.wrist, 0.25) : pose.wrist
        let sleevePose = CharacterConversationArm(shoulder: pose.shoulder, elbow: pose.elbow,
            wrist: sleeveEnd, shoulderDegrees: pose.shoulderDegrees, elbowDegrees: pose.elbowDegrees,
            wristDegrees: pose.wristDegrees, handDegrees: pose.handDegrees, openness: pose.openness)
        if kind == .harley {
            let bare = sleeve(pose, upperRadius: radius * 0.77, lowerRadius: 0.027)
            context.fill(bare, with: .linearGradient(Gradient(colors:
                [colors.skinDark, colors.skinLight, colors.skin]),
                startPoint: cg(pose.elbow + Point(x: -0.06, y: 0)),
                endPoint: cg(pose.wrist + Point(x: 0.05, y: 0))))
        }
        let cloth = sleeve(sleevePose, upperRadius: radius, lowerRadius: registration.lowerRadius)
        context.fill(cloth, with: .linearGradient(Gradient(colors:
            [colors.clothDark, colors.clothLight, colors.cloth, colors.clothDark]),
            startPoint: cg(pose.shoulder + Point(x: -radius, y: 0)),
            endPoint: cg(pose.wrist + Point(x: radius, y: 0))))
        var seam = Path()
        let n = normal(pose.elbow - pose.shoulder)
        seam.move(to: cg(pose.shoulder + times(n, radius * 0.60)))
        seam.addQuadCurve(to: cg(pose.elbow + times(n, radius * 0.51)),
            control: cg(blend(pose.shoulder, pose.elbow, 0.55) + times(n, radius * 0.65)))
        context.stroke(seam, with: .color(colors.clothLight.opacity(0.34)),
            style: StrokeStyle(lineWidth: 0.003, lineCap: .round))
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
        context.stroke(cuff, with: .color(colors.clothDark.opacity(0.3)), lineWidth: 0.002)
        hand(context: &context, pose: pose, scale: registration.handScale,
             colors: colors, viewerLeft: viewerLeft)
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
                     scale: Double, colors: Palette, viewerLeft: Bool) {
        var local = context
        local.translateBy(x: pose.wrist.x, y: pose.wrist.y)
        local.rotate(by: .degrees(pose.handDegrees))
        local.scaleBy(x: (viewerLeft ? -1 : 1) * scale, y: scale)
        let path = handPath(openness: pose.openness)
        local.fill(path, with: .linearGradient(Gradient(colors:
            [colors.skinDark, colors.skin, colors.skinLight, colors.skin]),
            startPoint: CGPoint(x: -0.55, y: 0.25), endPoint: CGPoint(x: 0.50, y: 0.80)))
        local.stroke(path, with: .color(colors.skinDark.opacity(0.35)),
            style: StrokeStyle(lineWidth: 0.015, lineJoin: .round))
        var palm = Path()
        palm.move(to: CGPoint(x: -0.16, y: 0.34))
        palm.addQuadCurve(to: CGPoint(x: 0.24, y: 0.56), control: CGPoint(x: 0.10, y: 0.39))
        palm.move(to: CGPoint(x: -0.14, y: 0.52))
        palm.addQuadCurve(to: CGPoint(x: 0.19, y: 0.68), control: CGPoint(x: 0.04, y: 0.57))
        palm.move(to: CGPoint(x: -0.27, y: 0.37))
        palm.addQuadCurve(to: CGPoint(x: -0.08, y: 0.68), control: CGPoint(x: -0.08, y: 0.39))
        local.stroke(palm, with: .color(colors.skinDark.opacity(0.20)),
            style: StrokeStyle(lineWidth: 0.018, lineCap: .round))
    }
}
