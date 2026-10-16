import Foundation

/// Oct 16 2026: a compiled puppet body (schema `kade-puppet-scene/1`), the same
/// data the web draws. The server builds every part from the character's body
/// recipe; this app only checks the scene, prepares it once and draws it.
/// Plain data: paths, gradients and channel-driven groups, never executable.
struct PuppetScene: Codable {
    static let schemaName = "kade-puppet-scene/1"

    struct Command: Codable {
        let op: String
        let v: [Double]
    }
    struct Stop: Codable {
        let at: Double
        let color: String
        let opacity: Double?
    }
    struct Gradient: Codable {
        let kind: String
        let start: [Double]?
        let end: [Double]?
        let center: [Double]?
        let focal: [Double]?
        let radius: Double?
        let stops: [Stop]
    }
    /// `[channel, number]`: a drive gain, an opacity gain or a hide threshold.
    struct ChannelValue: Codable {
        let channel: String
        let value: Double
        init(channel: String, value: Double) {
            self.channel = channel
            self.value = value
        }
        init(from decoder: Decoder) throws {
            var pair = try decoder.unkeyedContainer()
            channel = try pair.decode(String.self)
            value = try pair.decode(Double.self)
        }
        func encode(to encoder: Encoder) throws {
            var pair = encoder.unkeyedContainer()
            try pair.encode(channel)
            try pair.encode(value)
        }
    }
    struct Group: Codable {
        let id: String
        let parent: String?
        let pivot: [Double]
        let tx: [ChannelValue]?
        let ty: [ChannelValue]?
        let r: [ChannelValue]?
        let sx: [ChannelValue]?
        let sy: [ChannelValue]?
    }
    struct Morph: Codable {
        let c: String
        let d: [Command]
        let n: Bool?
    }
    struct Shape: Codable {
        let id: String
        let g: String
        let d: [Command]
        let m: [Morph]?
        let fill: String?
        let stroke: String?
        let sw: Double?
        let op: Double?
        let oc: [ChannelValue]?
        let clip: String?
        let hide: [ChannelValue]?
        let cap: String?
    }
    struct Backdrop: Codable {
        let top: String
        let bottom: String
    }
    struct Motion: Codable {
        let energy: String?
        let expressiveness: Double?
        let blink: String?
        let baseSmile: Double?
    }

    let schema: String
    let size: [Double]?
    let view: [Double]?
    let backdrop: Backdrop?
    let gradients: [String: Gradient]
    let groups: [Group]
    let shapes: [Shape]
    let motion: Motion?
    let description: String?
    let recipeHash: String?

    enum CodingKeys: String, CodingKey {
        case schema, size, view, backdrop, gradients, groups, shapes, motion, description, recipeHash
    }

    /// Missing collections read as empty, like the web check (`|| []`), so a
    /// thin scene reaches the validator instead of failing the whole reply.
    /// Optional extras that do not parse are dropped rather than fatal.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = (try? c.decodeIfPresent(String.self, forKey: .schema)) ?? ""
        size = try? c.decodeIfPresent([Double].self, forKey: .size)
        view = try? c.decodeIfPresent([Double].self, forKey: .view)
        backdrop = try? c.decodeIfPresent(Backdrop.self, forKey: .backdrop)
        gradients = try c.decodeIfPresent([String: Gradient].self, forKey: .gradients) ?? [:]
        groups = try c.decodeIfPresent([Group].self, forKey: .groups) ?? []
        shapes = try c.decodeIfPresent([Shape].self, forKey: .shapes) ?? []
        motion = try? c.decodeIfPresent(Motion.self, forKey: .motion)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        recipeHash = try? c.decodeIfPresent(String.self, forKey: .recipeHash)
    }
}

/// The 25 animation channels, in the motion engine's CHANNELS order.
enum PuppetChannel: Int, CaseIterable {
    case headYaw, headPitch, headRoll, bodyBreath, bodyShrug
    case gazeX, gazeY, eyeBlink, eyeWink, eyeSquint, eyeWide
    case browRaise, browFurrow, browSad, browAsym
    case mouthOpen, mouthWide, mouthRound, mouthSmile, mouthPress
    case cheekRaise, cheekBlush, hairSwing, extrasFlap, extrasFloat

    static let names = [
        "head.yaw", "head.pitch", "head.roll", "body.breath", "body.shrug",
        "gaze.x", "gaze.y", "eye.blink", "eye.wink", "eye.squint", "eye.wide",
        "brow.raise", "brow.furrow", "brow.sad", "brow.asym",
        "mouth.open", "mouth.wide", "mouth.round", "mouth.smile", "mouth.press",
        "cheek.raise", "cheek.blush", "hair.swing", "extras.flap", "extras.float",
    ]
    static let count = names.count
    static let indexByName: [String: Int] = {
        var index: [String: Int] = [:]
        for (position, name) in names.enumerated() { index[name] = position }
        return index
    }()
    var name: String { Self.names[rawValue] }

    /// A named channel set (fixtures, gallery states) as the renderer's array.
    /// Unknown names are ignored, exactly like a missing channel on the web.
    static func values(_ named: [String: Double]) -> [Double] {
        var values = [Double](repeating: 0, count: count)
        for (name, value) in named {
            if let index = indexByName[name] { values[index] = value }
        }
        return values
    }
}

extension PuppetScene {
    static let commandLengths: [String: Int] = ["M": 2, "L": 2, "Q": 4, "C": 6, "Z": 0]

    /// `#rrggbb`, ASCII only (the web's /^#[0-9a-f]{6}$/i).
    static func isHexColor(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 7, bytes[0] == UInt8(ascii: "#") else { return false }
        return bytes.dropFirst().allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    /// Structural check, the same rules and wording as the web's scene-check.mjs.
    /// An empty list means every renderer can draw it.
    func problems() -> [String] {
        var problems: [String] = []
        func fail(_ message: String) {
            if problems.count < 50 { problems.append(message) }
        }
        if schema != Self.schemaName { fail("schema") }
        if size?.count != 2 { fail("size") }
        if view?.count != 4 { fail("view") }
        for id in gradients.keys.sorted() {
            guard let gradient = gradients[id] else { continue }
            if gradient.stops.count < 2 { fail("gradient \(id) stops") }
            for stop in gradient.stops where !(Self.isHexColor(stop.color) && stop.at >= 0 && stop.at <= 1) {
                fail("gradient \(id) stop")
            }
            if gradient.kind == "linear" && (gradient.start == nil || gradient.end == nil) { fail("gradient \(id) linear") }
            if gradient.kind == "radial" && !(gradient.center != nil && (gradient.radius ?? 0) > 0) { fail("gradient \(id) radial") }
            if gradient.kind != "linear" && gradient.kind != "radial" { fail("gradient \(id) kind") }
        }
        var groupIDs = Set<String>()
        for group in groups {
            if groupIDs.contains(group.id) { fail("group \(group.id) duplicate") }
            if let parent = group.parent, !parent.isEmpty, !groupIDs.contains(parent) {
                fail("group \(group.id) parent \(parent) not earlier")
            }
            if group.pivot.count != 2 || !group.pivot.allSatisfy(\.isFinite) { fail("group \(group.id) pivot") }
            for (key, drive) in [("tx", group.tx), ("ty", group.ty), ("r", group.r), ("sx", group.sx), ("sy", group.sy)] {
                if let drive, drive.contains(where: { !$0.value.isFinite }) { fail("group \(group.id) drive \(key)") }
            }
            groupIDs.insert(group.id)
        }
        func pathIsValid(_ path: [Command]) -> Bool {
            guard path.count >= 2, path[0].op == "M" else { return false }
            return path.allSatisfy { command in
                guard let length = Self.commandLengths[command.op], command.v.count == length else { return false }
                return command.v.allSatisfy { $0.isFinite && $0 > -400 && $0 < 1400 }
            }
        }
        func paintIsValid(_ value: String?) -> Bool {
            guard let value else { return true }
            return value == "none" || Self.isHexColor(value) || gradients[value] != nil
        }
        var shapeIDs = Set<String>()
        var commands = 0
        for shape in shapes {
            if shapeIDs.contains(shape.id) { fail("shape \(shape.id) duplicate") }
            if !groupIDs.contains(shape.g) { fail("shape \(shape.id) group \(shape.g)") }
            if !pathIsValid(shape.d) { fail("shape \(shape.id) path") }
            commands += shape.d.count * (1 + (shape.m?.count ?? 0))
            for morph in shape.m ?? [] {
                if !pathIsValid(morph.d) || morph.d.count != shape.d.count
                    || zip(morph.d, shape.d).contains(where: { $0.op != $1.op }) {
                    fail("shape \(shape.id) morph \(morph.c)")
                }
            }
            if !paintIsValid(shape.fill) || !paintIsValid(shape.stroke) { fail("shape \(shape.id) paint") }
            if let clip = shape.clip, !clip.isEmpty, !shapeIDs.contains(clip) { fail("shape \(shape.id) clip \(clip) not earlier") }
            if let opacity = shape.op, !(opacity >= 0 && opacity <= 1) { fail("shape \(shape.id) opacity") }
            shapeIDs.insert(shape.id)
        }
        if shapes.count > 900 { fail("too many shapes") }
        if commands > 60000 { fail("too many path commands") }
        return problems
    }
}

/// A checked scene flattened once for drawing: Double arrays instead of nested
/// commands, group parents and clips as indices, channels as array positions
/// (-1 for a channel this app does not know, which always reads as zero).
final class PuppetPreparedScene: @unchecked Sendable {
    struct Drive {
        let channel: Int
        let gain: Double
    }
    struct Group {
        let parent: Int
        let pivotX: Double
        let pivotY: Double
        let tx: [Drive]
        let ty: [Drive]
        let r: [Drive]
        let sx: [Drive]
        let sy: [Drive]
    }
    struct Morph {
        let channel: Int
        let negative: Bool
        let coordinates: [Double]
    }
    enum Paint {
        case none
        case color(red: Double, green: Double, blue: Double)
        case gradient(Int)
    }
    struct Shape {
        let id: String
        let group: Int
        /// ASCII command letters (M, L, Q, C, Z); coordinates follow in order.
        let ops: [UInt8]
        let coordinates: [Double]
        let morphs: [Morph]
        let fill: Paint
        let stroke: Paint
        let strokeWidth: Double
        let cap: String?
        let opacity: Double
        let opacityDrives: [Drive]
        let clip: Int
        let hide: [Drive]
    }
    struct GradientStop {
        let at: Double
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }
    enum GradientKind {
        case linear(startX: Double, startY: Double, endX: Double, endY: Double)
        case radial(focalX: Double, focalY: Double, centerX: Double, centerY: Double, radius: Double)
    }
    struct Gradient {
        let kind: GradientKind
        let stops: [GradientStop]
    }
    struct Rect {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    let view: Rect
    let groups: [Group]
    let shapes: [Shape]
    /// Nil when a gradient's geometry cannot be drawn; a shape using it paints nothing.
    let gradients: [Gradient?]
    let backdrop: (top: GradientStop, bottom: GradientStop)?
    let motion: PuppetMotion.Options
    let description: String?
    let recipeHash: String?
    let groupIDs: [String]
    let shapeIndex: [String: Int]

    /// Nil when the scene fails the shared check: a bad body stays a portrait.
    init?(scene: PuppetScene) {
        guard scene.problems().isEmpty, let view = scene.view, view.count == 4,
              view.allSatisfy(\.isFinite), view[2] > 0, view[3] > 0 else { return nil }
        self.view = Rect(x: view[0], y: view[1], width: view[2], height: view[3])
        let channels = PuppetChannel.indexByName
        func drives(_ list: [PuppetScene.ChannelValue]?) -> [Drive] {
            (list ?? []).map { Drive(channel: channels[$0.channel] ?? -1, gain: $0.value) }
        }
        var groupIndex: [String: Int] = [:]
        var groups: [Group] = []
        for group in scene.groups {
            let parent = group.parent.flatMap { groupIndex[$0] } ?? -1
            groups.append(Group(parent: parent, pivotX: group.pivot[0], pivotY: group.pivot[1],
                tx: drives(group.tx), ty: drives(group.ty), r: drives(group.r),
                sx: drives(group.sx), sy: drives(group.sy)))
            groupIndex[group.id] = groups.count - 1
        }
        var gradientIndex: [String: Int] = [:]
        var gradients: [Gradient?] = []
        for id in scene.gradients.keys.sorted() {
            guard let gradient = scene.gradients[id] else { continue }
            gradientIndex[id] = gradients.count
            gradients.append(PuppetPreparedScene.gradient(gradient))
        }
        func paint(_ value: String?) -> Paint {
            guard let value, value != "none" else { return .none }
            if let index = gradientIndex[value] { return .gradient(index) }
            guard let color = PuppetPreparedScene.color(value, alpha: 1) else { return .none }
            return .color(red: color.red, green: color.green, blue: color.blue)
        }
        var shapeIndex: [String: Int] = [:]
        var shapes: [Shape] = []
        for shape in scene.shapes {
            let morphs = (shape.m ?? []).map { morph in
                Morph(channel: channels[morph.c] ?? -1, negative: morph.n == true,
                    coordinates: morph.d.flatMap(\.v))
            }
            shapes.append(Shape(id: shape.id, group: groupIndex[shape.g] ?? 0,
                ops: shape.d.map { $0.op.utf8.first ?? UInt8(ascii: "Z") },
                coordinates: shape.d.flatMap(\.v), morphs: morphs,
                fill: paint(shape.fill), stroke: paint(shape.stroke),
                strokeWidth: shape.sw ?? 0, cap: shape.cap, opacity: shape.op ?? 1,
                opacityDrives: drives(shape.oc),
                clip: shape.clip.flatMap { shapeIndex[$0] } ?? -1,
                hide: drives(shape.hide)))
            shapeIndex[shape.id] = shapes.count - 1
        }
        self.groups = groups
        self.shapes = shapes
        self.gradients = gradients
        self.groupIDs = scene.groups.map(\.id)
        self.shapeIndex = shapeIndex
        if let backdrop = scene.backdrop, let top = PuppetPreparedScene.color(backdrop.top, alpha: 1),
           let bottom = PuppetPreparedScene.color(backdrop.bottom, alpha: 1) {
            self.backdrop = (GradientStop(at: 0, red: top.red, green: top.green, blue: top.blue, alpha: 1),
                GradientStop(at: 1, red: bottom.red, green: bottom.green, blue: bottom.blue, alpha: 1))
        } else {
            self.backdrop = nil
        }
        motion = PuppetMotion.Options(energy: scene.motion?.energy ?? "steady",
            expressiveness: scene.motion?.expressiveness ?? 0.6,
            blink: scene.motion?.blink ?? "normal",
            baseSmile: scene.motion?.baseSmile ?? 0.12)
        description = scene.description
        recipeHash = scene.recipeHash
    }

    /// A tighter square around the head for small still faces in lists.
    var faceView: Rect {
        let width = view.width / 1.4
        return Rect(x: view.x + (view.width - width) / 2, y: view.y + view.height * 0.03,
            width: width, height: width)
    }

    static func color(_ hex: String, alpha: Double) -> (red: Double, green: Double, blue: Double)? {
        guard PuppetScene.isHexColor(hex), let number = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((number >> 16) & 0xff) / 255, Double((number >> 8) & 0xff) / 255, Double(number & 0xff) / 255)
    }

    private static func gradient(_ source: PuppetScene.Gradient) -> Gradient? {
        // Canvas sorts stops by offset and keeps equal offsets in order.
        let ordered = source.stops.enumerated().sorted {
            $0.element.at == $1.element.at ? $0.offset < $1.offset : $0.element.at < $1.element.at
        }
        var stops: [GradientStop] = []
        for (_, stop) in ordered {
            guard let rgb = color(stop.color, alpha: 1) else { return nil }
            let alpha = min(1, max(0, stop.opacity ?? 1))
            stops.append(GradientStop(at: min(1, max(0, stop.at)), red: rgb.red, green: rgb.green,
                blue: rgb.blue, alpha: alpha))
        }
        guard stops.count >= 2 else { return nil }
        func point(_ values: [Double]?) -> (Double, Double)? {
            guard let values, values.count >= 2, values[0].isFinite, values[1].isFinite else { return nil }
            return (values[0], values[1])
        }
        if source.kind == "linear", let start = point(source.start), let end = point(source.end) {
            return Gradient(kind: .linear(startX: start.0, startY: start.1, endX: end.0, endY: end.1), stops: stops)
        }
        if source.kind == "radial", let center = point(source.center), let radius = source.radius,
           radius.isFinite, radius > 0 {
            let focal = point(source.focal) ?? center
            return Gradient(kind: .radial(focalX: focal.0, focalY: focal.1, centerX: center.0,
                centerY: center.1, radius: radius), stops: stops)
        }
        return nil
    }
}
