import Foundation
import CoreGraphics

/// A 2x3 affine `[a b c d e f]`: x' = a x + c y + e, y' = b x + d y + f.
struct PuppetAffine {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0

    static let identity = PuppetAffine()

    /// `m * n` applies n first, then m (the web renderer's mul(m, n)).
    static func * (m: PuppetAffine, n: PuppetAffine) -> PuppetAffine {
        PuppetAffine(a: m.a * n.a + m.c * n.b, b: m.b * n.a + m.d * n.b,
            c: m.a * n.c + m.c * n.d, d: m.b * n.c + m.d * n.d,
            e: m.a * n.e + m.c * n.f + m.e, f: m.b * n.e + m.d * n.f + m.f)
    }

    var cgAffine: CGAffineTransform {
        CGAffineTransform(a: CGFloat(a), b: CGFloat(b), c: CGFloat(c), d: CGFloat(d), tx: CGFloat(e), ty: CGFloat(f))
    }

    var values: [Double] { [a, b, c, d, e, f] }
}

/// The scene rules every renderer shares (SCENE_SPEC.md), as pure math so the
/// conformance fixtures can check them without drawing anything.
enum PuppetMath {
    @inline(__always) static func value(_ channel: Int, _ channels: [Double]) -> Double {
        channel >= 0 && channel < channels.count ? channels[channel] : 0
    }

    static func drive(_ list: [PuppetPreparedScene.Drive], _ channels: [Double]) -> Double {
        var sum = 0.0
        for item in list { sum += value(item.channel, channels) * item.gain }
        return sum
    }

    /// local = translate(tx + px, ty + py) · rotate(r) · scale(sx, sy) · translate(-px, -py);
    /// world = world(parent) · local. Parents always come first.
    static func worldMatrices(_ scene: PuppetPreparedScene, channels: [Double], into out: inout [PuppetAffine]) {
        out.removeAll(keepingCapacity: true)
        for group in scene.groups {
            let tx = drive(group.tx, channels)
            let ty = drive(group.ty, channels)
            let r = drive(group.r, channels)
            let sx = 1 + drive(group.sx, channels)
            let sy = 1 + drive(group.sy, channels)
            let px = group.pivotX, py = group.pivotY
            let cosine = cos(r), sine = sin(r)
            let a = cosine * sx
            let b = sine * sx
            let c = -sine * sy
            let d = cosine * sy
            let e = tx + px - (a * px + c * py)
            let f = ty + py - (b * px + d * py)
            let local = PuppetAffine(a: a, b: b, c: c, d: d, e: e, f: f)
            out.append(group.parent >= 0 && group.parent < out.count ? out[group.parent] * local : local)
        }
    }

    static func worldMatrices(_ scene: PuppetPreparedScene, channels: [Double]) -> [PuppetAffine] {
        var out: [PuppetAffine] = []
        worldMatrices(scene, channels: channels, into: &out)
        return out
    }

    /// Final coordinate = base + Σ w·(target − base), w = max(0, v), or max(0, −v)
    /// for a negative morph. Returns false (and leaves `out` alone) when no morph
    /// weighs anything, so the caller can keep the unmorphed path.
    static func morph(_ shape: PuppetPreparedScene.Shape, channels: [Double], into out: inout [Double]) -> Bool {
        var any = false
        for morph in shape.morphs {
            let v = value(morph.channel, channels)
            if (morph.negative ? max(0, -v) : max(0, v)) > 0 { any = true; break }
        }
        guard any else { return false }
        let base = shape.coordinates
        out.removeAll(keepingCapacity: true)
        out.append(contentsOf: base)
        for morph in shape.morphs {
            let v = value(morph.channel, channels)
            let w = morph.negative ? max(0, -v) : max(0, v)
            guard w > 0, morph.coordinates.count == base.count else { continue }
            let target = morph.coordinates
            for j in 0..<base.count { out[j] += (target[j] - base[j]) * w }
        }
        return true
    }

    static func morphedCoordinates(_ shape: PuppetPreparedScene.Shape, channels: [Double]) -> [Double] {
        var out: [Double] = []
        return morph(shape, channels: channels, into: &out) ? out : shape.coordinates
    }

    /// clamp(op + Σ gain·channel, 0, 1).
    static func opacity(_ shape: PuppetPreparedScene.Shape, channels: [Double]) -> Double {
        var alpha = shape.opacity
        for item in shape.opacityDrives { alpha += value(item.channel, channels) * item.gain }
        return max(0, min(1, alpha))
    }

    /// Skipped while any listed channel is above its threshold.
    static func hidden(_ shape: PuppetPreparedScene.Shape, channels: [Double]) -> Bool {
        shape.hide.contains { value($0.channel, channels) > $0.gain }
    }

    /// Scene `view` fitted (aspect fit, centred) into a target rectangle.
    static func viewTransform(_ view: PuppetPreparedScene.Rect, into rect: CGRect) -> PuppetAffine {
        let width = Double(rect.width), height = Double(rect.height)
        let scale = min(width / view.width, height / view.height)
        return PuppetAffine(a: scale, b: 0, c: 0, d: scale,
            e: Double(rect.minX) + (width - view.width * scale) / 2 - view.x * scale,
            f: Double(rect.minY) + (height - view.height * scale) / 2 - view.y * scale)
    }
}

/// Draws one prepared scene into any Core Graphics context whose user space has
/// y growing downward (SwiftUI's Canvas through withCGContext). Gradients, colors
/// and unmorphed paths are built once per scene; a frame only rebuilds the paths
/// whose morphs are currently weighted.
final class PuppetRenderer: @unchecked Sendable {
    private enum Paint {
        case none
        case color(CGColor)
        case gradient(CGGradient, PuppetPreparedScene.GradientKind)
    }

    let prepared: PuppetPreparedScene
    private let basePaths: [CGPath]
    private let fills: [Paint]
    private let strokes: [Paint]
    private let backdrop: CGGradient?

    init(_ prepared: PuppetPreparedScene) {
        self.prepared = prepared
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        func gradient(_ stops: [PuppetPreparedScene.GradientStop]) -> CGGradient? {
            var components: [CGFloat] = []
            var locations: [CGFloat] = []
            for stop in stops {
                components += [CGFloat(stop.red), CGFloat(stop.green), CGFloat(stop.blue), CGFloat(stop.alpha)]
                locations.append(CGFloat(stop.at))
            }
            return CGGradient(colorSpace: space, colorComponents: components, locations: locations, count: stops.count)
        }
        let gradients: [(CGGradient, PuppetPreparedScene.GradientKind)?] = prepared.gradients.map { spec in
            guard let spec, let built = gradient(spec.stops) else { return nil }
            return (built, spec.kind)
        }
        func paint(_ source: PuppetPreparedScene.Paint) -> Paint {
            switch source {
            case .none:
                return .none
            case .color(let red, let green, let blue):
                guard let color = CGColor(colorSpace: space,
                    components: [CGFloat(red), CGFloat(green), CGFloat(blue), 1]) else { return .none }
                return .color(color)
            case .gradient(let index):
                guard index >= 0, index < gradients.count, let built = gradients[index] else { return .none }
                return .gradient(built.0, built.1)
            }
        }
        basePaths = prepared.shapes.map { PuppetRenderer.path(ops: $0.ops, coordinates: $0.coordinates) }
        fills = prepared.shapes.map { paint($0.fill) }
        strokes = prepared.shapes.map { paint($0.stroke) }
        backdrop = prepared.backdrop.flatMap { gradient([$0.top, $0.bottom]) }
    }

    static func path(ops: [UInt8], coordinates c: [Double]) -> CGPath {
        let path = CGMutablePath()
        var i = 0
        func point(_ k: Int) -> CGPoint { CGPoint(x: CGFloat(c[k]), y: CGFloat(c[k + 1])) }
        for op in ops {
            switch op {
            case UInt8(ascii: "M"):
                guard i + 2 <= c.count else { return path }
                path.move(to: point(i)); i += 2
            case UInt8(ascii: "L"):
                guard i + 2 <= c.count, !path.isEmpty else { return path }
                path.addLine(to: point(i)); i += 2
            case UInt8(ascii: "Q"):
                guard i + 4 <= c.count, !path.isEmpty else { return path }
                path.addQuadCurve(to: point(i + 2), control: point(i)); i += 4
            case UInt8(ascii: "C"):
                guard i + 6 <= c.count, !path.isEmpty else { return path }
                path.addCurve(to: point(i + 4), control1: point(i), control2: point(i + 2)); i += 6
            case UInt8(ascii: "Z"):
                if !path.isEmpty { path.closeSubpath() }
            default:
                return path
            }
        }
        return path
    }

    /// Draws the backdrop and every visible shape, fitted into `rect`.
    /// `view` overrides the scene's own crop (a closer face for small rows).
    func draw(in context: CGContext, rect: CGRect, channels: [Double],
              view: PuppetPreparedScene.Rect? = nil, drawsBackdrop: Bool = true) {
        let crop = view ?? prepared.view
        guard rect.width > 0, rect.height > 0, crop.width > 0, crop.height > 0,
              crop.width.isFinite, crop.height.isFinite else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        if drawsBackdrop, let backdrop {
            context.drawLinearGradient(backdrop, start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.minX, y: rect.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let base = PuppetMath.viewTransform(crop, into: rect)
        var matrices: [PuppetAffine] = []
        PuppetMath.worldMatrices(prepared, channels: channels, into: &matrices)
        var scratch: [Double] = []
        func matrix(_ group: Int) -> PuppetAffine {
            base * (group >= 0 && group < matrices.count ? matrices[group] : .identity)
        }
        func shapePath(_ index: Int) -> CGPath {
            let shape = prepared.shapes[index]
            guard PuppetMath.morph(shape, channels: channels, into: &scratch) else { return basePaths[index] }
            return PuppetRenderer.path(ops: shape.ops, coordinates: scratch)
        }
        for index in prepared.shapes.indices {
            let shape = prepared.shapes[index]
            if PuppetMath.hidden(shape, channels: channels) { continue }
            let alpha = PuppetMath.opacity(shape, channels: channels)
            guard alpha > 0 else { continue }
            let fill = fills[index]
            let stroke = shape.strokeWidth > 0 ? strokes[index] : .none
            if case .none = fill, case .none = stroke { continue }
            context.saveGState()
            if shape.clip >= 0, shape.clip < prepared.shapes.count {
                // The clip is an earlier shape's live outline in ITS group's transform.
                var transform = matrix(prepared.shapes[shape.clip].group).cgAffine
                if let clipPath = shapePath(shape.clip).copy(using: &transform) {
                    context.addPath(clipPath)
                    context.clip(using: .winding)
                }
            }
            context.concatenate(matrix(shape.group).cgAffine)
            context.setAlpha(CGFloat(alpha))
            let path = shapePath(index)
            switch fill {
            case .none:
                break
            case .color(let color):
                context.setFillColor(color)
                context.addPath(path)
                context.fillPath(using: .winding)
            case .gradient(let gradient, let kind):
                context.saveGState()
                context.addPath(path)
                context.clip(using: .winding)
                draw(gradient, kind, in: context)
                context.restoreGState()
            }
            if case .none = stroke {} else {
                context.setLineWidth(CGFloat(shape.strokeWidth))
                context.setLineJoin(.round)
                context.setLineCap(shape.cap == "butt" ? .butt : shape.cap == "square" ? .square : .round)
                switch stroke {
                case .none:
                    break
                case .color(let color):
                    context.setStrokeColor(color)
                    context.addPath(path)
                    context.strokePath()
                case .gradient(let gradient, let kind):
                    context.saveGState()
                    context.addPath(path)
                    context.replacePathWithStrokedPath()
                    context.clip()
                    draw(gradient, kind, in: context)
                    context.restoreGState()
                }
            }
            context.restoreGState()
        }
    }

    private func draw(_ gradient: CGGradient, _ kind: PuppetPreparedScene.GradientKind, in context: CGContext) {
        let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        switch kind {
        case .linear(let startX, let startY, let endX, let endY):
            context.drawLinearGradient(gradient, start: CGPoint(x: startX, y: startY),
                end: CGPoint(x: endX, y: endY), options: options)
        case .radial(let focalX, let focalY, let centerX, let centerY, let radius):
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: focalX, y: focalY), startRadius: 0,
                endCenter: CGPoint(x: centerX, y: centerY), endRadius: CGFloat(radius), options: options)
        }
    }
}
