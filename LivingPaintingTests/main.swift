import Foundation

// Oct 16 2026: living paintings. The Swift rig must reproduce the Python
// reference (dev/living-paintings/lp_runtime.py) frame for frame; the
// fixture is lp-golden.json from lp_golden.py. Run with
// run-living-painting-tests.sh (macOS).
var count = 0
var failures: [String] = []
func check(_ value: Bool, _ name: @autoclosure () -> String) {
    count += 1
    if !value { failures.append(name()) }
}

let environment = ProcessInfo.processInfo.environment
let root = URL(fileURLWithPath: environment["LIVING_ROOT"] ?? ".")

struct Golden: Decodable {
    struct Layer: Decodable {
        let panel: String
        let flow: Bool
        let alpha: Double
        let region: String
    }
    struct State: Decodable {
        let channels: [String: Double]
        let face: String?
        let prior: String?
        let blend: Double?
        let rollDegrees: Double?
        let offsetY: Double?
    }
    struct Case: Decodable {
        let name: String
        let state: State
        let indices: [Int]
        let vertices: [Double]
        let layers: [Layer]
    }
    let tolerance: Double
    let cases: [Case]
}

func panel(_ key: String?) -> LivingPaintingPanel? {
    guard let key else { return nil }
    let parts = key.split(separator: ".")
    guard parts.count == 2, let sheet = LivingPaintingPanel.Sheet(rawValue: String(parts[0])),
          let index = Int(parts[1]) else { fatalError("bad panel \(key)") }
    return LivingPaintingPanel(sheet: sheet, index: index)
}

let rigData = try! Data(contentsOf: root.appendingPathComponent("Sources/LivingPaintingDella.json"))
let rig = try! LivingPaintingRig(data: rigData)
let golden = try! JSONDecoder().decode(Golden.self,
    from: Data(contentsOf: root.appendingPathComponent("LivingPaintingTests/lp-golden.json")))
check(rig.vertexCount == rig.restX.count && rig.triangles.count == (rig.columns - 1) * (rig.rows - 1) * 6,
    "grid and triangles agree")

var worst = 0.0
for item in golden.cases {
    var state = LivingPaintingState()
    state.channels = PuppetChannel.values(item.state.channels)
    state.face = panel(item.state.face)
    state.prior = panel(item.state.prior)
    state.blend = item.state.blend ?? 1
    state.rollDegrees = item.state.rollDegrees ?? 0
    state.offsetY = item.state.offsetY ?? 0
    let vertices = rig.vertices(state)
    for (k, index) in item.indices.enumerated() {
        for axis in 0..<2 {
            let got = Double(vertices[index * 2 + axis]), want = item.vertices[k * 2 + axis]
            let error = abs(got - want)
            worst = max(worst, error)
            check(error <= golden.tolerance, "\(item.name): vertex \(index) axis \(axis) \(got) vs \(want)")
        }
    }
    let layers = rig.layers(state)
    check(layers.count == item.layers.count, "\(item.name): \(layers.count) layers vs \(item.layers.count)")
    for (got, want) in zip(layers, item.layers) {
        check(got.panel.key == want.panel && (got.flowKey != nil) == want.flow
            && abs(got.alpha - want.alpha) < 1e-6 && got.region.rawValue == want.region,
            "\(item.name): layer \(got.panel.key) \(got.alpha) \(got.region) vs \(want.panel) \(want.alpha) \(want.region)")
    }
}

// Every rest triangle has positive area, and the rest grid draws the panel unmoved.
var rest = LivingPaintingState()
rest.warp = false
let still = rig.vertices(rest)
var moved = 0.0
for i in 0..<rig.vertexCount {
    moved = max(moved, abs(Double(still[i * 2]) - rig.restX[i]), abs(Double(still[i * 2 + 1]) - rig.restY[i]))
}
check(moved < 1e-3, "the sliced rest pose leaves the grid where it is (\(moved))")

// A painted face keeps every facial channel off the expression; the head,
// gaze and body still answer it.
var options = PuppetMotion.Options()
options.artFace = true
let painted = PuppetMotion.stillChannels(expression: "surprised", options: options)
let coded = PuppetMotion.stillChannels(expression: "surprised", options: PuppetMotion.Options())
for channel in PuppetMotion.paintedChannels where channel != .mouthSmile {
    check(painted[channel.rawValue] == 0, "painted surprise leaves \(channel.name) at rest")
}
check(coded[PuppetChannel.browRaise.rawValue] > 0.5 && painted[PuppetChannel.headPitch.rawValue] < 0,
    "the coded face still lifts its brows and the painted head still lifts")
let motion = PuppetMotion(seed: 7, options: options)
motion.setExpression("angry")
var furrow = 0.0
for _ in 0..<60 { furrow = max(furrow, motion.update(dt: 1.0 / 30)[PuppetChannel.browFurrow.rawValue]) }
check(furrow == 0, "a painted angry face never furrows the warped brows (\(furrow))")

// Kade, Oct 16 2026: living paintings are on unless someone turns them off
// in Settings, and the switch keeps the key the portrait and Settings share.
check(LivingPaintingSetting.defaultOn, "living painted faces are on by default")
check(LivingPaintingSetting.key == "kadeLivingPaintings", "the setting keeps its stored key")

// Cost of one frame's grid on this machine (the phone measures its own).
var timing = LivingPaintingState()
timing.channels = PuppetChannel.values(["head.yaw": 0.5, "eye.blink": 0.5, "mouth.open": 0.6, "gaze.x": 0.4])
timing.face = LivingPaintingPanel(sheet: .faces, index: 1)
let started = Date()
for _ in 0..<200 { _ = rig.vertices(timing) }
let perFrame = Date().timeIntervalSince(started) * 1000 / 200

print("living paintings: \(count) checks, \(failures.count) failures, worst vertex error \(String(format: "%.5f", worst)) px, grid \(rig.columns)x\(rig.rows), \(String(format: "%.3f", perFrame)) ms per frame here")
for failure in failures.prefix(40) { print("FAIL: \(failure)") }
exit(failures.isEmpty ? 0 : 1)
