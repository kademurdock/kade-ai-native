import SwiftUI
import UIKit
import CryptoKit

/// Loaded once from the original, reviewable vector master in the asset bundle.
/// A failed contract stays a static server avatar rather than partial anatomy.
enum CharacterAngelArtwork {
    static let assetName = "CharacterAngelVectorArt"
    static let sourceSHA256 = "805783c577c0beb332256fd8786fefa6b42d8a24a2f499b4e1a3de9e26f7f1e0"
    static let loaded: CharacterAngelVectorArt? = {
        guard let data = NSDataAsset(name: assetName)?.data,
              data.count < 2_000_000,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sourceSHA256,
              let art = try? JSONDecoder().decode(CharacterAngelVectorArt.self, from: data),
              art.isValid else { return nil }
        return art
    }()
    /// Compile the verified master once. Frames only change transforms and the
    /// small facial curves, rather than rebuilding all 149 ornamental paths.
    fileprivate static let drawing = loaded.map(CharacterAngelVectorDrawing.init)
    #if DEBUG && targetEnvironment(simulator)
    struct CacheAudit {
        let shapeCount: Int
        let groupCount: Int
        let retainsSourceOrder: Bool
        let finiteGeometry: Bool
        let paintContractsMatch: Bool
    }
    /// Inspect the actual compiled drawing used by Canvas. This diagnostic is
    /// absent from production and does not rebuild or replace any geometry.
    static var cacheAudit: CacheAudit? {
        guard let art = loaded, let cached = drawing else { return nil }
        let shapes = cached.groups.values.flatMap { $0 }
        let source = Dictionary(uniqueKeysWithValues: art.shapes.map { ($0.id, $0) })
        return CacheAudit(shapeCount: shapes.count, groupCount: cached.groups.count,
            retainsSourceOrder: CharacterAngelVectorArt.groups.allSatisfy { group in
                cached.groups[group]?.map(\.id) == art.shapes.filter { $0.group == group }.map(\.id)
            }, finiteGeometry: shapes.allSatisfy { shape in
                let bounds = shape.path.boundingRect
                return !shape.path.isEmpty && [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite)
            }, paintContractsMatch: shapes.allSatisfy { shape in
                guard let original = source[shape.id] else { return false }
                return (shape.fill == nil) == (original.fill == "none")
                    && (shape.stroke == nil) == (original.stroke == nil)
                    && shape.strokeStyle.map { Double($0.lineWidth) } == original.strokeWidth
                    && shape.opacity == (original.opacity ?? 1)
            })
    }
    #endif
    static func approved(agentID: String?, avatarPath: String?) -> CharacterAngelVectorArt? {
        guard agentID == CharacterMotion.angelID,
              CharacterMotion.prepared(id: agentID, path: avatarPath) else { return nil }
        return loaded
    }
    static let limits = CharacterBustMotionLimits(headDegrees: 1.8,
        bodyDegrees: 0.4, headOffsetPixels: 2, bodyOffsetPixels: 1.5)
}

fileprivate struct CharacterAngelVectorDrawing {
    struct Shape {
        let id: String
        let path: Path
        let fill: GraphicsContext.Shading?
        let stroke: GraphicsContext.Shading?
        let strokeStyle: StrokeStyle?
        let opacity: Double
        let glimmers: Bool
        let claspedArm: Bool
    }
    let groups: [String: [Shape]]

    init(_ art: CharacterAngelVectorArt) {
        let paints = art.gradients.mapValues { paint -> GraphicsContext.Shading in
            let gradient = Gradient(stops: paint.stops.map {
                Gradient.Stop(color: Self.color($0.color, opacity: $0.opacity ?? 1), location: $0.at)
            })
            if paint.kind == "radial", let center = paint.center, let radius = paint.radius {
                return .radialGradient(gradient, center: CGPoint(x: center[0], y: center[1]),
                    startRadius: 0, endRadius: radius)
            }
            let start = paint.start!, end = paint.end!
            return .linearGradient(gradient, startPoint: CGPoint(x: start[0], y: start[1]),
                endPoint: CGPoint(x: end[0], y: end[1]))
        }
        func shading(_ fill: String) -> GraphicsContext.Shading {
            paints[fill] ?? .color(Self.color(fill))
        }
        var compiled: [String: [Shape]] = [:]
        for shape in art.shapes {
            compiled[shape.group, default: []].append(Shape(id: shape.id,
                path: Self.path(shape.path),
                fill: shape.fill == "none" ? nil : shading(shape.fill),
                stroke: shape.stroke.map(shading),
                strokeStyle: shape.strokeWidth.map {
                    StrokeStyle(lineWidth: $0, lineCap: .round, lineJoin: .round)
                }, opacity: shape.opacity ?? 1,
                glimmers: shape.id.hasPrefix("sparkle") || shape.id.hasPrefix("robe-jewel-")
                    || shape.id.hasPrefix("robe-sequin-") || shape.id.hasPrefix("halo-pearl-")
                    || shape.id.hasPrefix("hair-pearl-") || shape.id == "heart-star",
                claspedArm: AngelVectorArmPose.shapeIDs.contains(shape.id)))
        }
        groups = compiled
    }

    private static func path(_ commands: [CharacterAngelVectorArt.Command]) -> Path {
        var value = Path()
        for command in commands {
            let v = command.v
            switch command.op {
            case "M": value.move(to: CGPoint(x: v[0], y: v[1]))
            case "L": value.addLine(to: CGPoint(x: v[0], y: v[1]))
            case "Q": value.addQuadCurve(to: CGPoint(x: v[2], y: v[3]), control: CGPoint(x: v[0], y: v[1]))
            case "C": value.addCurve(to: CGPoint(x: v[4], y: v[5]),
                control1: CGPoint(x: v[0], y: v[1]), control2: CGPoint(x: v[2], y: v[3]))
            case "Z": value.closeSubpath()
            default: break
            }
        }
        return value
    }

    static func color(_ value: String, opacity: Double = 1) -> Color {
        var digits = String(value.dropFirst())
        if digits.count == 3 { digits = digits.map { String(repeating: String($0), count: 2) }.joined() }
        let number = UInt64(digits, radix: 16) ?? 0
        let alpha = digits.count == 8 ? Double(number & 0xff) / 255 : 1
        let rgb = digits.count == 8 ? number >> 8 : number
        return Color(.sRGB, red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255, blue: Double(rgb & 0xff) / 255,
            opacity: alpha * opacity)
    }
}

/// Angel's own shaded vector face and clothing. One small decorative Canvas
/// consumes the existing portrait timeline; it owns no audio, timers or text.
struct CharacterAngelVectorView: View {
    let art: CharacterAngelVectorArt
    let facial: AngelVectorFacialPose
    let mouth: AngelVectorMouthPose
    let ornaments: AngelVectorOrnamentPose
    var arms = AngelVectorArmPose.still
    var motion = CharacterBustPose(headAngle: 0, bodyAngle: 0, headOffsetY: 0, bodyOffsetY: 0)

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / art.canvas, y: size.height / art.canvas)
            var torso = context
            rotate(&torso, degrees: motion.bodyAngle, around: art.pivots["body"]!)
            torso.translateBy(x: 0, y: motion.bodyOffsetY)
            var leftWing = torso
            rotate(&leftWing, degrees: ornaments.leftWingDegrees, around: art.pivots["leftWing"]!)
            draw(group: "leftWing", into: &leftWing)
            var rightWing = torso
            rotate(&rightWing, degrees: ornaments.rightWingDegrees, around: art.pivots["rightWing"]!)
            draw(group: "rightWing", into: &rightWing)
            draw(group: "body", into: &torso)
            var head = torso
            rotate(&head, degrees: motion.headAngle, around: art.pivots["head"]!)
            head.translateBy(x: 0, y: motion.headOffsetY)
            draw(group: "head", into: &head)
            drawFace(into: &head)
            var halo = head
            rotate(&halo, degrees: ornaments.haloDegrees, around: art.pivots["halo"]!)
            halo.translateBy(x: 0, y: ornaments.haloOffsetY * art.canvas)
            draw(group: "halo", into: &halo)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func rotate(_ context: inout GraphicsContext, degrees: Double, around pivot: [Double]) {
        context.translateBy(x: pivot[0], y: pivot[1])
        context.rotate(by: .degrees(degrees))
        context.translateBy(x: -pivot[0], y: -pivot[1])
    }

    private func color(_ value: String, opacity: Double = 1) -> Color {
        CharacterAngelVectorDrawing.color(value, opacity: opacity)
    }

    private func draw(group: String, into context: inout GraphicsContext) {
        for shape in CharacterAngelArtwork.drawing?.groups[group] ?? [] {
            var local = context
            if shape.claspedArm {
                // Sleeves, hands and the finger seam share one transform.
                // Keep their authored draw order and overlapping wrist joins.
                local.translateBy(x: arms.offsetX * art.canvas, y: arms.offsetY * art.canvas)
                rotate(&local, degrees: arms.degrees, around: AngelVectorArmPose.pivot)
            }
            local.opacity = shape.opacity
            if shape.glimmers {
                // Neutral SVG and native art have exactly the same opacity.
                // Slow changes only dim an authored jewel by at most 10.5%.
                local.opacity *= 1 - abs(ornaments.sparkle - AngelVectorOrnamentPose.still.sparkle) * 0.7
            }
            if let fill = shape.fill { local.fill(shape.path, with: fill) }
            if let stroke = shape.stroke, let style = shape.strokeStyle {
                local.stroke(shape.path, with: stroke, style: style)
            }
        }
    }

    private func eyePath(_ eye: CharacterAngelVectorArt.Eye, aperture: Double) -> Path {
        var curve = Path()
        curve.move(to: CGPoint(x: eye.cx - eye.width / 2, y: eye.cy))
        curve.addQuadCurve(to: CGPoint(x: eye.cx + eye.width / 2, y: eye.cy),
            control: CGPoint(x: eye.cx, y: eye.cy - eye.height * 0.92 * aperture))
        curve.addQuadCurve(to: CGPoint(x: eye.cx - eye.width / 2, y: eye.cy),
            control: CGPoint(x: eye.cx, y: eye.cy + eye.height * 0.72 * aperture))
        curve.closeSubpath()
        return curve
    }

    private func drawFace(into context: inout GraphicsContext) {
        for cheek in art.features.cheeks {
            let y = cheek.cy - facial.cheekLift * 5
            let rect = CGRect(x: cheek.cx - cheek.rx, y: y - cheek.ry,
                width: cheek.rx * 2, height: cheek.ry * 2)
            var blush = context
            blush.opacity = 0.58 + facial.cheekLift * 0.12
            blush.fill(Path(ellipseIn: rect), with: .radialGradient(
                Gradient(colors: [color("#ee9fa0", opacity: 0.66), color("#ee9fa0", opacity: 0)]),
                center: CGPoint(x: cheek.cx, y: y), startRadius: 0, endRadius: cheek.rx))
        }
        for index in art.features.eyes.indices {
            let eye = art.features.eyes[index]
            let opening = index == 0 ? facial.leftEye : facial.rightEye
            let brow = index == 0 ? facial.leftBrow : facial.rightBrow
            let slope = index == 0 ? facial.leftBrowSlope : facial.rightBrowSlope
            drawEye(eye, opening: opening, into: &context)
            var eyebrow = Path()
            let y = eye.cy - eye.height * 0.72 - brow * eye.height * 0.12
            eyebrow.move(to: CGPoint(x: eye.cx - eye.width * 0.41, y: y + slope * 9))
            eyebrow.addQuadCurve(to: CGPoint(x: eye.cx + eye.width * 0.41, y: y - slope * 9),
                control: CGPoint(x: eye.cx, y: y - 8))
            context.stroke(eyebrow, with: .color(color("#684126")),
                style: StrokeStyle(lineWidth: 6, lineCap: .round))
        }
        drawMouth(into: &context)
    }

    private func drawEye(_ eye: CharacterAngelVectorArt.Eye, opening: Double,
                         into context: inout GraphicsContext) {
        if opening <= 0.025 {
            var closed = Path()
            closed.move(to: CGPoint(x: eye.cx - eye.width / 2, y: eye.cy))
            closed.addQuadCurve(to: CGPoint(x: eye.cx + eye.width / 2, y: eye.cy),
                control: CGPoint(x: eye.cx, y: eye.cy + 10))
            context.stroke(closed, with: .color(color("#694735")),
                style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
            return
        }
        let aperture = eyePath(eye, aperture: opening)
        context.fill(aperture, with: .linearGradient(
            Gradient(colors: [color("#fffcf5"), color("#eee2d4")]),
            startPoint: CGPoint(x: eye.cx, y: eye.cy - eye.height / 2),
            endPoint: CGPoint(x: eye.cx, y: eye.cy + eye.height / 2)))
        var irisContext = context
        irisContext.clip(to: aperture)
        let x = eye.cx + facial.gazeX * eye.irisRadius
        let y = eye.cy + facial.gazeY * eye.irisRadius
        let r = eye.irisRadius
        irisContext.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
            with: .radialGradient(Gradient(colors: [color("#ae8644"), color("#756337"), color("#40331e")]),
                center: CGPoint(x: x, y: y + r * 0.1), startRadius: r * 0.15, endRadius: r))
        irisContext.fill(Path(ellipseIn: CGRect(x: x - r * 0.47, y: y - r * 0.58,
            width: r * 0.94, height: r * 1.10)), with: .color(color("#251c17")))
        irisContext.fill(Path(ellipseIn: CGRect(x: x - r * 0.42, y: y - r * 0.48,
            width: r * 0.40, height: r * 0.34)), with: .color(color("#ffffff", opacity: 0.95)))
        irisContext.fill(Path(ellipseIn: CGRect(x: x + r * 0.18, y: y + r * 0.23,
            width: r * 0.17, height: r * 0.14)), with: .color(color("#fff7db", opacity: 0.75)))
        context.stroke(aperture, with: .color(color("#805d43", opacity: 0.76)),
            style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
        var upper = Path()
        upper.move(to: CGPoint(x: eye.cx - eye.width / 2, y: eye.cy))
        upper.addQuadCurve(to: CGPoint(x: eye.cx + eye.width / 2, y: eye.cy),
            control: CGPoint(x: eye.cx, y: eye.cy - eye.height * 0.92 * opening))
        context.stroke(upper, with: .color(color("#684735")),
            style: StrokeStyle(lineWidth: 4, lineCap: .round))
    }

    private func drawMouth(into context: inout GraphicsContext) {
        let box = art.features.mouth
        let w = box.width * mouth.width
        let h = box.height * mouth.aperture
        let corners = -mouth.smile * 10
        let left = CGPoint(x: box.cx - w / 2, y: box.cy + corners)
        let right = CGPoint(x: box.cx + w / 2, y: box.cy + corners)
        if h <= 1 {
            var seam = Path()
            seam.move(to: left)
            seam.addQuadCurve(to: right, control: CGPoint(x: box.cx, y: box.cy + mouth.smile * 48))
            context.stroke(seam, with: .color(color("#aa6860")),
                style: StrokeStyle(lineWidth: 4, lineCap: .round))
            return
        }
        var opening = Path()
        let handle = w * (0.26 + mouth.roundness * 0.20)
        opening.move(to: left)
        opening.addCurve(to: right, control1: CGPoint(x: box.cx - handle, y: box.cy - h * 0.48),
            control2: CGPoint(x: box.cx + handle, y: box.cy - h * 0.48))
        opening.addCurve(to: left, control1: CGPoint(x: box.cx + handle, y: box.cy + h * 0.78),
            control2: CGPoint(x: box.cx - handle, y: box.cy + h * 0.78))
        opening.closeSubpath()
        context.fill(opening, with: .linearGradient(Gradient(colors: [color("#724335"), color("#a5695b")]),
            startPoint: CGPoint(x: box.cx, y: box.cy - h / 2), endPoint: CGPoint(x: box.cx, y: box.cy + h)))
        var inner = context
        inner.clip(to: opening)
        if mouth.upperTeeth > 0 {
            inner.fill(Path(roundedRect: CGRect(x: box.cx - w * 0.38, y: box.cy - h * 0.46,
                width: w * 0.76, height: box.height * mouth.upperTeeth), cornerSize: CGSize(width: 6, height: 6)),
                with: .color(color("#fff7e9")))
        }
        if mouth.lowerTeeth > 0 {
            inner.fill(Path(roundedRect: CGRect(x: box.cx - w * 0.30,
                y: box.cy + h * 0.44 - box.height * mouth.lowerTeeth,
                width: w * 0.60, height: box.height * mouth.lowerTeeth), cornerSize: CGSize(width: 5, height: 5)),
                with: .color(color("#ede4d7")))
        }
        if mouth.tongue > 0 {
            inner.fill(Path(ellipseIn: CGRect(x: box.cx - w * 0.26,
                y: box.cy + h * 0.24, width: w * 0.52, height: box.height * mouth.tongue)),
                with: .color(color("#d99691")))
        }
        context.stroke(opening, with: .color(color("#b77b71")),
            style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
    }
}
