import Foundation

/// Oct 16 2026: living paintings. A painted character keeps its original
/// panels as the only pictures, and a grid of points laid over the neutral
/// panel bends like a rubber sheet (the Live2D / VTuber mesh-warp technique),
/// driven by the same motion channels as the coded puppets (PuppetMotion).
///
/// The rig file (LivingPainting<Name>.json, built offline by
/// dev/living-paintings/lp_rig.py) holds the grid, landmarks for the lids,
/// irises, head and neck, and "flows": where every neutral point's feature
/// sits in each of the painter's other panels. A painted expression or mouth
/// shape is then a real morph: the grid moves toward that panel's shape while
/// its pixels dissolve in, both registered point for point.
///
/// Pure data and arithmetic, no UIKit or Metal, so the model tests can check
/// it against the Python reference (LivingPaintingTests, lp-golden.json).
/// Any change here must land in lp_runtime.py (and the web port) too.
struct LivingPaintingRig {
    struct Oval: Decodable { let x: Double; let y: Double; let rx: Double; let ry: Double }
    struct Head: Decodable { let x: Double; let y: Double; let rx: Double; let ry: Double; let rz: Double }
    struct Nose: Decodable { let x: Double; let y: Double; let r: Double; let z: Double }
    struct Eye: Decodable {
        let x: Double
        let y: Double
        /// Half the eye opening's width.
        let w: Double
        /// Upper lid, closed lash line and lower lid at the eye's middle.
        let upper: Double
        let closed: Double
        let lower: Double
        /// How far above the lid the skin stretches as the lid comes down.
        let crease: Double
        let iris: Double
        /// Slope of the lid line across the eye (a painted head roll plus
        /// the eye's own corner tilt), and of the painted closed lash line.
        var tilt: Double? = nil
        var closedTilt: Double? = nil
        /// Thickness of the lash line that slides down whole (default 3).
        var lash: Double? = nil
        /// How much of the opening the lid travels (default 1).
        var travel: Double? = nil
    }
    struct Brow: Decodable { let x: Double; let y: Double; let w: Double; let h: Double; let inner: Double }
    struct Spot: Decodable { let x: Double; let y: Double; let r: Double }
    struct Mouth: Decodable { let x: Double; let y: Double; let w: Double; let h: Double }
    struct Neck: Decodable { let x: Double; let y: Double; let chin: Double; let collar: Double }
    struct Hair: Decodable { let x: Double; let y: Double; let inner: Double; let outer: Double; let reach: Double }
    struct Landmarks: Decodable {
        let face: Oval
        let head: Head
        let nose: Nose
        let eyes: [Eye]
        let brows: [Brow]
        let mouth: Mouth
        let cheeks: [Spot]
        let neck: Neck
        let hair: Hair
        /// Rows this near the top hold still (a crown touching the stage edge).
        var pinTop: Double? = nil
        /// Scale on the engine's own head roll (default 1).
        var rollChannel: Double? = nil
    }
    /// Witherspoon has no nuance sheet.
    struct Sheets: Decodable { let faces: String; let mouths: String; let nuance: String?; let pitch: Double }
    /// A matte picture's place in panel pixels; its alpha cuts the head.
    struct Matte: Decodable { let asset: String; let x: Double; let y: Double; let side: Double }
    struct File: Decodable {
        let id: String
        let version: Int
        let panel: Double
        let sheets: Sheets
        /// The head cut: a matte picture and an always-opaque face oval
        /// (Della, Harley), joined with the bust's head outline at load.
        let mask: Matte?
        let core: Oval?
        /// The old rig's dissolve regions as fractions of the panel:
        /// x, y, width, height, feather inner radius.
        let regions: [String: [Double]]
        let landmarks: Landmarks
        /// Mouth sheet signatures: open, wide, round, press.
        let visemes: [[Double]]
        let gridX: [Double]
        let gridY: [Double]
        let flowScale: Double
        let flows: [String: String]
        let keyforms: [String: String]
        /// Panels whose painted eyes are already closed: no blink on them.
        var noBlinkFaces: [String]? = nil
        /// Where the painted closed eyes start fading in, and over how much
        /// blink (default 0.45, 0.45).
        var closedFade: [Double]? = nil
    }

    enum RigError: Error { case shape(String) }

    static let yawDegrees = 9.0
    static let pitchDegrees = 6.0
    static let rollDegrees = 5.0
    static let laughKey = "faces.2"
    static let closedKey = "faces.8"

    let file: File
    let columns: Int
    let rows: Int
    var vertexCount: Int { columns * rows }
    let restX: [Double]
    let restY: [Double]
    /// Per vertex, interleaved x, y: where that neutral point's feature sits
    /// in each painted panel ("faces.3", "mouths.5", "nuance.2").
    let flows: [String: [Double]]
    let keyforms: [String: [Double]]
    let mouthWeight: [Double]
    let faceWeight: [Double]
    let headWeight: [Double]
    let depth: [Double]
    let hairWeight: [Double]
    let triangles: [UInt16]
    let noBlink: Set<String>
    let rollChannel: Double

    init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        self.file = file
        columns = file.gridX.count
        rows = file.gridY.count
        let count = columns * rows
        guard columns >= 2, rows >= 2, count <= 65_535, file.flowScale > 0 else {
            throw RigError.shape("grid \(columns) x \(rows)")
        }
        var xs = [Double](repeating: 0, count: count)
        var ys = [Double](repeating: 0, count: count)
        for r in 0..<rows {
            for c in 0..<columns {
                xs[r * columns + c] = file.gridX[c]
                ys[r * columns + c] = file.gridY[r]
            }
        }
        restX = xs
        restY = ys
        func unpack(_ name: String, _ text: String) throws -> [Double] {
            guard let bytes = Data(base64Encoded: text), bytes.count == count * 4 else {
                throw RigError.shape("field \(name)")
            }
            var values = [Double](repeating: 0, count: count * 2)
            bytes.withUnsafeBytes { raw in
                for i in 0..<(count * 2) {
                    let low = UInt16(raw[i * 2]), high = UInt16(raw[i * 2 + 1])
                    values[i] = Double(Int16(bitPattern: low | (high << 8))) / file.flowScale
                }
            }
            return values
        }
        var flows: [String: [Double]] = [:]
        for (key, text) in file.flows { flows[key] = try unpack(key, text) }
        var keyforms: [String: [Double]] = [:]
        for (key, text) in file.keyforms { keyforms[key] = try unpack(key, text) }
        self.flows = flows
        self.keyforms = keyforms

        let lm = file.landmarks
        noBlink = Set(file.noBlinkFaces ?? [])
        rollChannel = lm.rollChannel ?? 1
        let pinTop = lm.pinTop ?? 0
        var mouth = [Double](repeating: 0, count: count)
        var face = [Double](repeating: 0, count: count)
        var head = [Double](repeating: 0, count: count)
        var depth = [Double](repeating: 0, count: count)
        var hair = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let x = xs[i], y = ys[i]
            // Where a speaking mouth takes over from an expression's own mouth
            // shape: wide and flat-topped, so even a cartoon's big smile hands
            // its cheeks over gently.
            mouth[i] = Self.smooth01(Self.softEllipse(x, y, lm.mouth.x, lm.mouth.y + 2,
                lm.mouth.w * 2.4, lm.mouth.h * 4.2, 0.5))
            face[i] = Self.smooth01(Self.softEllipse(x, y, lm.face.x, lm.face.y + 14,
                lm.face.rx * 1.1, lm.face.ry * 1.12, 0.5))
            let pin = pinTop > 0 ? Self.smooth01(y / pinTop) : 1
            head[i] = (1 - Self.smooth01((y - lm.neck.chin) / (lm.neck.collar - lm.neck.chin))) * pin
            let hx = (x - lm.head.x) / lm.head.rx, hy = (y - lm.head.y) / lm.head.ry
            let r2 = hx * hx + hy * hy
            let nx = x - lm.nose.x, ny = y - lm.nose.y
            depth[i] = lm.head.rz * min(1, max(0, 1 - r2)).squareRoot()
                + lm.nose.z * Self.bump((nx * nx + ny * ny) / (lm.nose.r * lm.nose.r))
            let hang = min(1.3, max(0, (y - lm.hair.y + 40) / lm.head.ry))
            // Hair below the collar lies on the shoulders and stays with them.
            let shoulders = 1 - Self.smooth01((y - lm.neck.collar) / 40)
            hair[i] = Self.smooth01((r2.squareRoot() - lm.hair.inner) / (lm.hair.outer - lm.hair.inner))
                * (1 - face[i]) * hang * lm.hair.reach * shoulders * pin
        }
        mouthWeight = mouth
        faceWeight = face
        headWeight = head
        self.depth = depth
        hairWeight = hair

        var triangles: [UInt16] = []
        triangles.reserveCapacity((rows - 1) * (columns - 1) * 6)
        for r in 0..<(rows - 1) {
            for c in 0..<(columns - 1) {
                let a = UInt16(r * columns + c), b = UInt16(r * columns + c + 1)
                let d = UInt16((r + 1) * columns + c), e = UInt16((r + 1) * columns + c + 1)
                triangles += [a, b, e, a, e, d]
            }
        }
        self.triangles = triangles
        for key in ["browRaise", "browFurrow", "browSad", "eyeWide", "smileUp", "smileDown", "cheekRaise"]
            where keyforms[key] == nil { throw RigError.shape("keyform \(key)") }
        for index in 0..<file.visemes.count where flows["mouths.\(index)"] == nil {
            throw RigError.shape("mouths.\(index)")
        }
        guard lm.eyes.count == 2, file.visemes.allSatisfy({ $0.count == 4 }) else {
            throw RigError.shape("landmarks")
        }
    }

    static func smooth01(_ value: Double) -> Double {
        let v = min(1, max(0, value))
        return v * v * (3 - 2 * v)
    }

    /// The grid row at or above height y (clamped to the grid) and how far y
    /// sits toward the next row.
    static func rowAt(_ gy: [Double], _ y: Double) -> (Int, Double) {
        var r = 0
        while r + 1 < gy.count && gy[r + 1] <= y { r += 1 }
        r = max(0, min(gy.count - 2, r))
        return (r, (y - gy[r]) / (gy[r + 1] - gy[r]))
    }

    /// (1 - r^2)^2 inside the unit circle: smooth, with zero slope at its edge.
    static func bump(_ r2: Double) -> Double {
        let t = min(1, max(0, 1 - r2))
        return t * t
    }

    /// The old rig's feathered region: opaque to `inner`, fading to clear at
    /// the ellipse's edge.
    static func softEllipse(_ x: Double, _ y: Double, _ cx: Double, _ cy: Double,
                            _ rx: Double, _ ry: Double, _ inner: Double) -> Double {
        let dx = (x - cx) / rx, dy = (y - cy) / ry
        let r = (dx * dx + dy * dy).squareRoot()
        return min(1, max(0, (1 - r) / max(1e-6, 1 - inner)))
    }
}

/// The "Living painted faces" switch in Settings, Feedback & Sounds. On by
/// default (Kade, Oct 16 2026: most people never open Settings); anyone can
/// turn it off there. Reduce Motion, Low Power Mode, heat and the Animated
/// characters switch still hold every portrait still, as before.
enum LivingPaintingSetting {
    static let key = "kadeLivingPaintings"
    static let defaultOn = true
}

/// One painted panel of a character's sheets.
struct LivingPaintingPanel: Hashable {
    enum Sheet: String { case faces, mouths, nuance }
    let sheet: Sheet
    let index: Int
    var key: String { sheet.rawValue + "." + String(index) }

    /// The portrait's shown expression as a painted panel; nil is the neutral
    /// panel itself (and the closed-eye panel is never an expression).
    init?(face: CharacterFace) {
        switch face {
        case .neutral, .closed: return nil
        default:
            let raw = face.rawValue
            if raw < 9 { self.init(sheet: .faces, index: raw) } else { self.init(sheet: .nuance, index: raw - 8) }
        }
    }

    init(sheet: Sheet, index: Int) {
        self.sheet = sheet
        self.index = index
    }
}

/// Everything one frame needs. Channels are indexed by PuppetChannel.
struct LivingPaintingState {
    var channels = [Double](repeating: 0, count: PuppetChannel.count)
    var face: LivingPaintingPanel? = nil
    var prior: LivingPaintingPanel? = nil
    /// How far the shown face has replaced the prior one (0...1).
    var blend = 1.0
    /// The body's own head turn and lift, so head and shoulders stay one figure.
    var rollDegrees = 0.0
    var offsetY = 0.0
    /// False draws the old sliced portrait with the same pictures and
    /// regions: whole panels dissolving over a head that only turns and
    /// lifts. Kept for side-by-side review and as a still fallback.
    var warp = true
    /// The old portrait's single painted mouth (mouth sheet panel), when not warping.
    var slicedViseme = 0

    func value(_ channel: PuppetChannel) -> Double {
        channel.rawValue < channels.count ? channels[channel.rawValue] : 0
    }
}

/// One draw of the grid: which panel's pixels, at what opacity, in which
/// feathered region. `flowKey` nil samples the panel at the rest grid.
struct LivingPaintingLayer: Equatable {
    enum Region: String { case head, face, mouth, eyes }
    let panel: LivingPaintingPanel
    let flowKey: String?
    let alpha: Double
    let region: Region
}

extension LivingPaintingRig {
    /// Painted mouth panels nearest the engine's mouth shape (top two),
    /// scaled by how much the mouth is doing. A laugh keeps its own mouth.
    func visemeWeights(_ state: LivingPaintingState) -> [(index: Int, weight: Double)] {
        if state.face?.key == Self.laughKey { return [] }
        let open = state.value(.mouthOpen), wide = state.value(.mouthWide)
        let round = state.value(.mouthRound), press = state.value(.mouthPress)
        let amount = min(1, max(open, round, press, wide * 0.6) / 0.12)
        guard amount > 0.001 else { return [] }
        let signature = [open, wide, round, press]
        var weights: [(weight: Double, index: Int)] = []
        for (index, panel) in file.visemes.enumerated() {
            var d2 = 0.0
            for k in 0..<4 {
                let d = signature[k] - panel[k]
                d2 += d * d
            }
            weights.append((exp(-d2 / 0.06), index))
        }
        weights.sort { $0.weight != $1.weight ? $0.weight > $1.weight : $0.index > $1.index }
        let top = weights.prefix(2)
        let total = top.reduce(0) { $0 + $1.weight }
        return top.compactMap { item -> (index: Int, weight: Double)? in
            let weight = amount * item.weight / total
            return weight > 0.01 ? (item.index, weight) : nil
        }
    }

    /// Which expression panels shape the face and how strongly, mirroring the
    /// dissolve: the prior face fades out while the shown one fades in.
    func expressionWeights(_ state: LivingPaintingState) -> [(key: String, weight: Double)] {
        var out: [(key: String, weight: Double)] = []
        if let prior = state.prior, prior != state.face, state.blend < 1 {
            out.append((prior.key, 1 - state.blend))
        }
        if let shown = state.face {
            out.append((shown.key, state.prior != shown ? state.blend : 1))
        }
        return out
    }

    /// Screen positions (panel pixels, interleaved x, y) of every grid vertex.
    /// The frame's state with blinks removed on a face painted with its eyes
    /// already closed (CharacterFacialPolicy.shouldBlink's laughing panels).
    func blinkable(_ state: LivingPaintingState) -> LivingPaintingState {
        guard let face = state.face, noBlink.contains(face.key) else { return state }
        var state = state
        for channel in [PuppetChannel.eyeBlink, .eyeWink] where channel.rawValue < state.channels.count {
            state.channels[channel.rawValue] = 0
        }
        return state
    }

    func vertices(_ given: LivingPaintingState, into out: UnsafeMutablePointer<Float>) {
        let state = blinkable(given)
        let n = vertexCount
        let lm = file.landmarks
        func ch(_ channel: PuppetChannel) -> Double { state.value(channel) }
        guard state.warp else {
            // The old portrait: one rigid head, turned about the neck.
            let rho = (ch(.headRoll) * Self.rollDegrees + state.rollDegrees) * .pi / 180
            let cs = cos(rho), sn = sin(rho)
            for i in 0..<n {
                let cx = restX[i] - lm.neck.x, cy = restY[i] - lm.neck.y
                out[i * 2] = Float(lm.neck.x + cx * cs - cy * sn)
                out[i * 2 + 1] = Float(lm.neck.y + cx * sn + cy * cs + state.offsetY)
            }
            return
        }
        var dx = [Double](repeating: 0, count: n)
        var dy = [Double](repeating: 0, count: n)
        // 1. painted morphs: expressions, speaking mouth shapes, keyforms.
        // A speaking mouth takes the lips over from the expression's own.
        let visemes = visemeWeights(state)
        let speak = min(1, visemes.reduce(0) { $0 + $1.weight })
        func add(_ field: [Double], _ weight: Double, keep: Bool = false) {
            for i in 0..<n {
                if keep {
                    let k = 1 - mouthWeight[i] * speak
                    dx[i] += weight * field[i * 2] * k
                    dy[i] += weight * field[i * 2 + 1] * k
                } else {
                    dx[i] += weight * field[i * 2]
                    dy[i] += weight * field[i * 2 + 1]
                }
            }
        }
        for item in expressionWeights(state) {
            if let field = flows[item.key] { add(field, item.weight, keep: true) }
        }
        for item in visemes {
            if let field = flows["mouths.\(item.index)"] { add(field, item.weight) }
        }
        let lift = ch(.browRaise)
        // Keyforms cut from different panels are each fold-free; a combination
        // stays a weighted average of them, never a sum past full strength.
        let brows: [(String, Double)] = [("browRaise", lift > 0 ? lift : lift * 0.6),
            ("browFurrow", ch(.browFurrow)), ("browSad", ch(.browSad))]
        let smile = ch(.mouthSmile)
        let cheeks: [(String, Double)] = [("smileUp", max(0, smile)), ("smileDown", max(0, -smile)),
            ("cheekRaise", ch(.cheekRaise))]
        // A closing lid takes over the eye: the iris and a widened lid rest.
        let open = 1 - min(1, max(ch(.eyeBlink), ch(.eyeWink)))
        for group in [brows, cheeks, [("eyeWide", ch(.eyeWide) * open)]] {
            let total = group.reduce(0) { $0 + abs($1.1) }
            let norm = total > 1 ? 1 / total : 1
            for (key, weight) in group where abs(weight) > 1e-4 {
                if let field = keyforms[key] { add(field, weight * norm) }
            }
        }
        // 2. eyes: irises follow the gaze inside the lids
        let gazeX = ch(.gazeX), gazeY = ch(.gazeY)
        for eye in lm.eyes {
            for i in 0..<n {
                let ex = (restX[i] - eye.x) / (eye.w * 1.05), ey = (restY[i] - eye.y) / (eye.iris * 1.5)
                let wg = Self.bump(ex * ex + ey * ey)
                if wg == 0 { continue }
                dx[i] += gazeX * eye.iris * 0.55 * wg * open
                dy[i] += gazeY * eye.iris * 0.3 * wg * open
            }
        }
        // Lids last, as monotonic remaps of each grid column's already-moved
        // points: first the upper lid comes down, then the lower lid rises.
        // The lid lines are read where the face has already moved them in that
        // column (an expression may have half-closed the eye), so a blink
        // closes what is open now and never pushes one lid through the other.
        let squint = ch(.eyeSquint)
        let h2 = 9.0
        let gy = file.gridY
        for (side, eye) in lm.eyes.enumerated() {
            var blink = ch(.eyeBlink)
            if side == 1 { blink = max(blink, ch(.eyeWink)) }
            blink = min(1, max(blink, squint * 0.25))
            let yc = eye.closed, yu = eye.upper, low = eye.lower
            for c in 0..<columns {
                let u = (file.gridX[c] - eye.x) / eye.w
                guard abs(u) < 1 else { continue }
                let f = 1 - u * u
                // A tilted eye's lid line rises or falls across its width; its
                // painted closed lash line may slope its own way.
                let t = (eye.tilt ?? 0) * (file.gridX[c] - eye.x)
                let tc = (eye.closedTilt ?? eye.tilt ?? 0) * (file.gridX[c] - eye.x)
                let lid = yc - (yc - yu) * f + t
                func moved(_ y: Double) -> Double {
                    let (r, w) = Self.rowAt(gy, y)
                    return y + dy[r * columns + c] * (1 - w) + dy[(r + 1) * columns + c] * w
                }
                let lidMoved = moved(lid), closedMoved = moved(yc + tc)
                let middleMoved = moved(eye.y + t), lowMoved = moved(low + t)
                let opening = max(closedMoved - lidMoved, 0)
                // 0.96: a closed lid keeps a sliver of height; no zero-area cells.
                // A big cartoon lid may travel part of the way.
                let d = min(blink, 0.96) * opening * (eye.travel ?? 1)
                let top = lidMoved - eye.crease
                // The lash line slides down whole; only the skin above it stretches.
                let lash = min(eye.lash ?? 3, eye.crease * 0.5)
                let band = lidMoved - lash
                let span = max(opening, 0.01)
                let rise = squint * 0.35 * max(lowMoved - lidMoved, 0) * f
                let reach = max(lowMoved - middleMoved, 0.01)
                for r in 0..<rows {
                    let i = r * columns + c
                    var py = gy[r] + dy[i]
                    if py >= top && py < band { py += d * (py - top) / (eye.crease - lash) }
                    else if py >= band && py < lidMoved { py += d }
                    else if py >= lidMoved && py < closedMoved { py += d * (closedMoved - py) / span }
                    if py > middleMoved && py <= lowMoved { py -= rise * (py - middleMoved) / reach }
                    else if py > lowMoved && py <= lowMoved + h2 { py -= rise * (1 - (py - lowMoved) / h2) }
                    dy[i] = py - gy[r]
                }
            }
        }
        let swing = ch(.hairSwing)
        // 3. head turn: an ellipsoid head with a nose; features slide, outline holds
        let phi = ch(.headYaw) * Self.yawDegrees * .pi / 180
        let theta = ch(.headPitch) * Self.pitchDegrees * .pi / 180
        let cosPhi = cos(phi) - 1, sinPhi = sin(phi)
        let cosTheta = cos(theta) - 1, sinTheta = sin(theta)
        // 4. roll about the neck; the neck bends instead of the head cutting
        let roll = (ch(.headRoll) * Self.rollDegrees * rollChannel + state.rollDegrees) * .pi / 180
        for i in 0..<n {
            let x = restX[i], y = restY[i], hw = headWeight[i]
            var qx = x + dx[i] + swing * hairWeight[i]
            var qy = y + dy[i]
            qx += hw * ((x - lm.head.x) * cosPhi + depth[i] * sinPhi)
            qy += hw * ((y - lm.head.y) * cosTheta + depth[i] * sinTheta)
            let rho = roll * hw
            let cx = qx - lm.neck.x, cy = qy - lm.neck.y
            let cs = cos(rho), sn = sin(rho)
            qx = lm.neck.x + cx * cs - cy * sn
            qy = lm.neck.y + cx * sn + cy * cs
            // 5. the body's breath and nod lift the whole head
            out[i * 2] = Float(qx)
            out[i * 2 + 1] = Float(qy + state.offsetY)
        }
    }

    func vertices(_ state: LivingPaintingState) -> [Float] {
        var out = [Float](repeating: 0, count: vertexCount * 2)
        out.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress { vertices(state, into: base) }
        }
        return out
    }

    /// The draw list, bottom to top: the neutral panel cut by the head matte,
    /// the dissolving expressions, the speaking mouth shapes, then the
    /// painted closed eyes as the lids arrive.
    func layers(_ given: LivingPaintingState) -> [LivingPaintingLayer] {
        let state = blinkable(given)
        var out = [LivingPaintingLayer(panel: LivingPaintingPanel(sheet: .faces, index: 0),
            flowKey: nil, alpha: 1, region: .head)]
        let fading = state.blend < 1 && state.prior != state.face
        guard state.warp else {
            if fading, let prior = state.prior {
                out.append(LivingPaintingLayer(panel: prior, flowKey: nil,
                    alpha: state.face == nil ? 1 - state.blend : 1, region: .face))
            }
            if let shown = state.face {
                out.append(LivingPaintingLayer(panel: shown, flowKey: nil, alpha: fading ? state.blend : 1, region: .face))
            }
            if state.slicedViseme > 0, state.slicedViseme < file.visemes.count, state.face?.key != Self.laughKey {
                out.append(LivingPaintingLayer(panel: LivingPaintingPanel(sheet: .mouths, index: state.slicedViseme),
                    flowKey: nil, alpha: 1, region: .mouth))
            }
            let blink = min(1, max(0, state.value(.eyeBlink)))
            if blink > 0.001 {
                out.append(LivingPaintingLayer(panel: LivingPaintingPanel(sheet: .faces, index: 8),
                    flowKey: nil, alpha: blink, region: .eyes))
            }
            return out
        }
        if fading, let prior = state.prior {
            out.append(LivingPaintingLayer(panel: prior, flowKey: prior.key,
                alpha: state.face == nil ? 1 - state.blend : 1, region: .face))
        }
        if let shown = state.face {
            out.append(LivingPaintingLayer(panel: shown, flowKey: shown.key,
                alpha: fading ? state.blend : 1, region: .face))
        }
        let visemes = visemeWeights(state)
        var later = visemes.reduce(0) { $0 + $1.weight }
        // Stable order by weight, heaviest drawn first.
        let ordered = visemes.enumerated().sorted {
            $0.element.weight != $1.element.weight ? $0.element.weight > $1.element.weight : $0.offset < $1.offset
        }.map { $0.element }
        for item in ordered {
            later -= item.weight
            out.append(LivingPaintingLayer(panel: LivingPaintingPanel(sheet: .mouths, index: item.index),
                flowKey: "mouths.\(item.index)", alpha: min(1, item.weight / max(1e-6, 1 - later)), region: .mouth))
        }
        let fade = file.closedFade ?? [0.45, 0.45]
        let start = fade.count == 2 ? fade[0] : 0.45, width = fade.count == 2 ? max(fade[1], 0.01) : 0.45
        let closed = Self.smooth01((state.value(.eyeBlink) - start) / width)
        if closed > 0.001 {
            out.append(LivingPaintingLayer(panel: LivingPaintingPanel(sheet: .faces, index: 8),
                flowKey: nil, alpha: closed, region: .eyes))
        }
        return out
    }

    /// The region a layer is feathered into, in panel pixels: centre x, y,
    /// radii x, y and the feather's inner radius.
    func region(_ region: LivingPaintingLayer.Region) -> (cx: Double, cy: Double, rx: Double, ry: Double, inner: Double) {
        guard region != .head, let r = file.regions[region.rawValue], r.count == 5 else { return (0, 0, 1, 1, 0) }
        let p = file.panel
        return ((r[0] + r[2] / 2) * p, (r[1] + r[3] / 2) * p, r[2] * p / 2, r[3] * p / 2, r[4])
    }
}
