import Foundation
import CoreGraphics

// Oct 16 2026: puppet scene conformance. The fixtures are the web kit's own
// (scene-golden.json, motion-golden.json); every renderer and motion port must
// reproduce them within their tolerance. Run with run-puppet-tests.sh.
var count = 0
var failures: [String] = []
func check(_ value: Bool, _ name: @autoclosure () -> String) {
    count += 1
    if !value { failures.append(name()) }
}

let fixtures = ProcessInfo.processInfo.environment["PUPPET_FIXTURES"] ?? "PuppetTests/fixtures"
func load<T: Decodable>(_ type: T.Type, _ name: String) -> T {
    let url = URL(fileURLWithPath: fixtures).appendingPathComponent(name)
    guard let data = try? Data(contentsOf: url) else { fatalError("missing fixture \(url.path)") }
    do { return try JSONDecoder().decode(T.self, from: data) } catch { fatalError("fixture \(name): \(error)") }
}

// MARK: scene geometry

struct SceneGolden: Decodable {
    struct Expect: Decodable {
        let channels: [String: Double]
        let groups: [String: [Double]]
        let shapes: [String: [PuppetScene.Command]]
        let alpha: [String: Double]
    }
    struct Case: Decodable {
        let scene: PuppetScene
        let expect: [Expect]
    }
    let tolerance: Double
    let cases: [Case]
}

let sceneGolden = load(SceneGolden.self, "scene-golden.json")
let sceneTolerance = sceneGolden.tolerance + 1e-9
var matrixChecks = 0, coordinateChecks = 0, alphaChecks = 0
var preparedFixtures: [PuppetPreparedScene] = []
for (caseIndex, item) in sceneGolden.cases.enumerated() {
    let problems = item.scene.problems()
    check(problems.isEmpty, "golden scene \(caseIndex) passes the shared check: \(problems)")
    guard let prepared = PuppetPreparedScene(scene: item.scene) else {
        check(false, "golden scene \(caseIndex) prepares")
        continue
    }
    preparedFixtures.append(prepared)
    for (setIndex, expect) in item.expect.enumerated() {
        let channels = PuppetChannel.values(expect.channels)
        let matrices = PuppetMath.worldMatrices(prepared, channels: channels)
        check(matrices.count == prepared.groups.count, "case \(caseIndex) one matrix per group")
        for (id, expected) in expect.groups.sorted(by: { $0.key < $1.key }) {
            guard let index = prepared.groupIDs.firstIndex(of: id), index < matrices.count else {
                check(false, "case \(caseIndex) group \(id) exists")
                continue
            }
            let actual = matrices[index].values
            matrixChecks += 1
            check(expected.count == 6 && zip(actual, expected).allSatisfy { abs($0 - $1) <= sceneTolerance },
                "case \(caseIndex) set \(setIndex) group \(id): \(actual) expected \(expected)")
        }
        for (id, commands) in expect.shapes.sorted(by: { $0.key < $1.key }) {
            guard let index = prepared.shapeIndex[id] else {
                check(false, "case \(caseIndex) shape \(id) exists")
                continue
            }
            let shape = prepared.shapes[index]
            let actual = PuppetMath.morphedCoordinates(shape, channels: channels)
            let expected = commands.flatMap(\.v)
            let ops = commands.map { $0.op.utf8.first ?? 0 }
            coordinateChecks += expected.count
            let worst = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
            check(ops == shape.ops && actual.count == expected.count && worst <= sceneTolerance,
                "case \(caseIndex) set \(setIndex) shape \(id): worst difference \(worst), \(actual.count) of \(expected.count) numbers")
        }
        for (id, expected) in expect.alpha.sorted(by: { $0.key < $1.key }) {
            guard let index = prepared.shapeIndex[id] else {
                check(false, "case \(caseIndex) alpha shape \(id) exists")
                continue
            }
            let actual = PuppetMath.opacity(prepared.shapes[index], channels: channels)
            alphaChecks += 1
            check(abs(actual - expected) <= sceneTolerance, "case \(caseIndex) set \(setIndex) alpha \(id): \(actual) expected \(expected)")
        }
    }
}
check(matrixChecks >= 40 && coordinateChecks >= 1000 && alphaChecks >= 4,
    "scene golden coverage: \(matrixChecks) matrices, \(coordinateChecks) coordinates, \(alphaChecks) alphas")

// MARK: motion engine

struct MotionGolden: Decodable {
    struct Options: Decodable {
        let energy: String?
        let expressiveness: Double?
        let blink: String?
        let baseSmile: Double?
    }
    /// ["setExpression", name, strength, holdSeconds]
    struct Event: Decodable {
        let name: String
        let strength: Double
        let hold: Double
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            _ = try c.decode(String.self)
            name = try c.decode(String.self)
            strength = try c.decode(Double.self)
            hold = try c.decode(Double.self)
        }
    }
    struct Step: Decodable {
        let dt: Double
        let speaking: Bool
        let level: Double
        let listening: Bool
        let reduceMotion: Bool
        let event: Event?
    }
    struct Checkpoint: Decodable {
        let frame: Int
        let channels: [String: Double]
    }
    struct Run: Decodable {
        let seed: UInt32
        let options: Options
        let script: [Step]
        let checkpoints: [Checkpoint]
    }
    let tolerance: Double
    let runs: [MotionGolden.Run]
}

let motionGolden = load(MotionGolden.self, "motion-golden.json")
let motionTolerance = motionGolden.tolerance + 1e-9
var motionChecks = 0
for run in motionGolden.runs {
    let options = PuppetMotion.Options(energy: run.options.energy ?? "steady",
        expressiveness: run.options.expressiveness ?? 0.6, blink: run.options.blink ?? "normal",
        baseSmile: run.options.baseSmile ?? 0.12)
    let motion = PuppetMotion(seed: run.seed, options: options)
    var expectedByFrame: [Int: [String: Double]] = [:]
    for checkpoint in run.checkpoints { expectedByFrame[checkpoint.frame] = checkpoint.channels }
    var worst = 0.0
    var firstMiss: String?
    for (frame, step) in run.script.enumerated() {
        if let event = step.event { motion.setExpression(event.name, strength: event.strength, holdSeconds: event.hold) }
        let out = motion.update(dt: step.dt, input: PuppetMotion.Input(speaking: step.speaking, level: step.level,
            listening: step.listening, reduceMotion: step.reduceMotion))
        guard let expected = expectedByFrame[frame] else { continue }
        for (name, value) in expected.sorted(by: { $0.key < $1.key }) {
            guard let index = PuppetChannel.indexByName[name] else {
                check(false, "seed \(run.seed) unknown channel \(name)")
                continue
            }
            let difference = abs(out[index] - value)
            worst = max(worst, difference)
            motionChecks += 1
            if difference > motionTolerance, firstMiss == nil {
                firstMiss = "seed \(run.seed) frame \(frame) \(name): \(out[index]) expected \(value)"
            }
        }
    }
    check(firstMiss == nil, firstMiss ?? "")
    check(run.checkpoints.count == 60, "seed \(run.seed) has its 60 checkpoints")
    print("motion seed \(run.seed): \(run.checkpoints.count) checkpoints, worst difference \(worst)")
}
check(motionChecks == 3 * 60 * PuppetChannel.count, "every motion checkpoint channel compared (\(motionChecks))")

// Seeds from agent ids are full 32-bit hashes; the web values for the same text.
check(PuppetMotion.hashSeed("agent_BSOLa3eNEZyjs-7abCjMt") == 1_676_933_926, "hashSeed matches the web for an agent id")
check(PuppetMotion.hashSeed("kade") == 851_033_918, "hashSeed matches the web for a short word")
check(PuppetMotion.hashSeed("caf\u{e9} \u{1F600}") == 1_387_128_011, "hashSeed matches the web past the BMP")
check(PuppetMotion.hashSeed("") == 2_166_136_261, "hashSeed of nothing is the FNV offset")
do {
    // A high-bit seed through 120 frames of rest then speech (motion.mjs reference run).
    let motion = PuppetMotion(seed: PuppetMotion.hashSeed(""),
        options: PuppetMotion.Options(energy: "lively", expressiveness: 0.9))
    var out: [Double] = []
    for i in 0..<120 {
        out = motion.update(dt: 1.0 / 24, input: PuppetMotion.Input(speaking: i > 40,
            level: i > 40 ? 0.5 + 0.4 * sin(Double(i)) : 0))
    }
    let reference: [String: Double] = ["head.yaw": -0.130997381, "head.pitch": -0.038152697, "head.roll": -0.061102104,
        "body.breath": -0.05763897, "gaze.x": -0.112891101, "gaze.y": 0.057040974, "eye.squint": 0.02903783,
        "brow.raise": 0.022999364, "mouth.open": 0.444251837, "mouth.wide": 0.371095827, "mouth.round": 0.001146522,
        "mouth.smile": 0.108106705, "hair.swing": -0.001741506, "extras.flap": 0.809130901, "extras.float": -0.977530118]
    for (name, value) in reference.sorted(by: { $0.key < $1.key }) {
        let actual = out[PuppetChannel.indexByName[name]!]
        check(abs(actual - value) <= 1e-6, "high-bit seed run \(name): \(actual) expected \(value)")
    }
}

// MARK: app-side rules

for expression in CharacterExpression.allCases {
    let name = PuppetMotion.expressionName(expression)
    check(PuppetMotion.expressions[name] != nil, "\(expression) maps to a motion expression (\(name))")
}
check(PuppetMotion.expressionName(for: CharacterPresentation(activity: .speaking, expression: .warm, laughing: true)) == "laughing",
    "a laugh moment is the laughing face")
check(PuppetMotion.expressionName(for: CharacterPresentation(activity: .thinking)) == "thinking", "a neutral thinker looks away to think")
check(PuppetMotion.expressionName(for: CharacterPresentation(activity: .thinking, expression: .sad)) == "sad", "a direction outranks thinking")
check(PuppetMotion.holdSeconds(for: "laughing") < 1 && PuppetMotion.holdSeconds(for: "warm") > 3600, "a laugh is short, a direction holds")
let still = PuppetMotion.stillChannels(expression: "neutral", options: PuppetMotion.Options(baseSmile: 0.2))
check(still[PuppetChannel.mouthSmile.rawValue] == 0.2 && still.enumerated().allSatisfy { $0.offset == PuppetChannel.mouthSmile.rawValue || $0.element == 0 },
    "a still neutral pose is the resting smile alone")
let stillHappy = PuppetMotion.stillChannels(expression: "happy", options: PuppetMotion.Options())
check(stillHappy[PuppetChannel.mouthSmile.rawValue] > 0.5 && stillHappy[PuppetChannel.cheekRaise.rawValue] > 0.3
    && stillHappy[PuppetChannel.eyeBlink.rawValue] == 0 && stillHappy[PuppetChannel.mouthOpen.rawValue] == 0,
    "Reduce Motion still shows the expression with eyes open and mouth closed")
check(PuppetMotion.voiceLevel(0.008) == 0 && PuppetMotion.voiceLevel(0.3) == 1 && PuppetMotion.voiceLevel(.nan) == 0
    && abs(PuppetMotion.voiceLevel(0.108) - 0.5) < 1e-12, "voice level uses the painted faces' mouth scale")
func fps(_ activity: CharacterActivity, _ thermal: CharacterThermalPressure, active: Bool = true) -> Double {
    PuppetFrameBudget(active: active, activity: activity, thermal: thermal).framesPerSecond
}
check(fps(.speaking, .nominal) == 30 && fps(.listening, .nominal) == 24 && fps(.thinking, .nominal) == 24
    && fps(.idle, .nominal) == 20, "nominal puppet clocks 30/24/24/20")
check(fps(.speaking, .fair) == 20 && fps(.listening, .fair) == 15 && fps(.thinking, .fair) == 15
    && fps(.idle, .fair) == 12, "fair puppet clocks 20/15/15/12")
check([CharacterActivity.idle, .listening, .thinking, .speaking].allSatisfy { fps($0, .serious) == 0 && fps($0, .critical) == 0 && fps($0, .nominal, active: false) == 0 },
    "serious or critical pressure and an inactive stage stop the clock")
check(PuppetFrameBudget(active: false, activity: .speaking).paused
    && PuppetFrameBudget(active: false, activity: .speaking).minimumInterval == 1, "a paused clock keeps a finite interval")
check(PuppetFrameBudget.activity(CharacterPresentation(activity: .speaking, outputPhase: .queuedGap), playing: true) == .idle
    && PuppetFrameBudget.activity(CharacterPresentation(activity: .listening), playing: true) == .speaking
    && PuppetFrameBudget.activity(CharacterPresentation(activity: .thinking), playing: false) == .thinking,
    "the puppet samples activity like the portrait")

// MARK: validator (the web's scene-check.mjs rules)

func decodeScene(_ json: String) -> PuppetScene? { try? JSONDecoder().decode(PuppetScene.self, from: Data(json.utf8)) }
let minimal = ##"{"schema":"kade-puppet-scene/1","size":[1000,1000],"view":[0,0,1000,1000],"gradients":{"g":{"kind":"linear","start":[0,0],"end":[0,10],"stops":[{"at":0,"color":"#000000"},{"at":1,"color":"#FFFFFF","opacity":0.5}]}},"groups":[{"id":"root","parent":null,"pivot":[500,500]},{"id":"head","parent":"root","pivot":[500,400],"r":[["head.roll",0.1]]}],"shapes":[{"id":"a","g":"root","d":[{"op":"M","v":[0,0]},{"op":"L","v":[10,0]},{"op":"L","v":[0,10]},{"op":"Z","v":[]}],"fill":"g"},{"id":"b","g":"head","d":[{"op":"M","v":[0,0]},{"op":"C","v":[1,2,3,4,5,6]}],"stroke":"#123abc","sw":2,"clip":"a"}]}"##
func problems(_ json: String) -> [String] { decodeScene(json)?.problems() ?? ["did not decode"] }
check(problems(minimal) == [], "the minimal scene passes: \(problems(minimal))")
check(decodeScene(minimal).flatMap(PuppetPreparedScene.init(scene:)) != nil, "the minimal scene prepares")
func rejects(_ old: String, _ new: String, _ expected: String) {
    check(minimal.contains(old), "validator case edits the minimal scene: \(old)")
    let found = problems(minimal.replacingOccurrences(of: old, with: new))
    check(found.contains(expected), "validator reports '\(expected)' (found \(found))")
    if let scene = decodeScene(minimal.replacingOccurrences(of: old, with: new)) {
        check(PuppetPreparedScene(scene: scene) == nil, "a scene with '\(expected)' never prepares")
    }
}
rejects(##""schema":"kade-puppet-scene/1""##, ##""schema":"kade-puppet-scene/2""##, "schema")
rejects(##""size":[1000,1000]"##, ##""size":[1000]"##, "size")
rejects(##""view":[0,0,1000,1000]"##, ##""view":[0,0,1000]"##, "view")
rejects(##""stops":[{"at":0,"color":"#000000"},"##, ##""stops":["##, "gradient g stops")
rejects(##"{"at":0,"color":"#000000"}"##, ##"{"at":0,"color":"#00000"}"##, "gradient g stop")
rejects(##"{"at":0,"color":"#000000"}"##, ##"{"at":1.5,"color":"#000000"}"##, "gradient g stop")
rejects(##""kind":"linear","start":[0,0],"##, ##""kind":"linear","##, "gradient g linear")
rejects(##""kind":"linear""##, ##""kind":"conic""##, "gradient g kind")
rejects(##""kind":"linear","start":[0,0],"end":[0,10]"##, ##""kind":"radial","center":[5,5],"radius":0"##, "gradient g radial")
rejects(##""parent":"root""##, ##""parent":"nobody""##, "group head parent nobody not earlier")
rejects(##""pivot":[500,400]"##, ##""pivot":[500]"##, "group head pivot")
rejects(##"{"id":"head","parent":"root""##, ##"{"id":"root","parent":"root""##, "group root duplicate")
rejects(##""g":"head""##, ##""g":"nowhere""##, "shape b group nowhere")
rejects(##"{"op":"L","v":[10,0]}"##, ##"{"op":"L","v":[10]}"##, "shape a path")
rejects(##"{"op":"L","v":[10,0]}"##, ##"{"op":"L","v":[1400,0]}"##, "shape a path")
rejects(##"{"op":"L","v":[10,0]}"##, ##"{"op":"T","v":[10,0]}"##, "shape a path")
rejects(##""d":[{"op":"M","v":[0,0]},{"op":"L","v":[10,0]}"##, ##""d":[{"op":"L","v":[0,0]},{"op":"L","v":[10,0]}"##, "shape a path")
rejects(##""fill":"g""##, ##""fill":"missing""##, "shape a paint")
rejects(##""stroke":"#123abc""##, ##""stroke":"#123abz""##, "shape b paint")
rejects(##""clip":"a""##, ##""clip":"b""##, "shape b clip b not earlier")
rejects(##""sw":2,"##, ##""sw":2,"op":1.5,"##, "shape b opacity")
rejects(##""fill":"g"}"##, ##""fill":"g","m":[{"c":"mouth.open","d":[{"op":"M","v":[1,1]},{"op":"L","v":[2,2]}]}]}"##, "shape a morph mouth.open")
rejects(##""fill":"g"}"##, ##""fill":"g","m":[{"c":"mouth.open","d":[{"op":"M","v":[1,1]},{"op":"Q","v":[2,2,3,3]},{"op":"L","v":[4,4]},{"op":"Z","v":[]}]}]}"##, "shape a morph mouth.open")
rejects(##"{"id":"b","g":"head""##, ##"{"id":"a","g":"head""##, "shape a duplicate")
check(decodeScene("not a scene") == nil, "garbage never decodes")
check(problems(##"{"size":[1,1],"view":[0,0,1,1]}"##) == ["schema"], "a scene without a schema says so")
do {
    var many: [String] = []
    for i in 0..<901 { many.append(##"{"id":"s\##(i)","g":"root","d":[{"op":"M","v":[0,0]},{"op":"L","v":[1,1]}]}"##) }
    let crowded = ##"{"schema":"kade-puppet-scene/1","size":[1000,1000],"view":[0,0,1000,1000],"groups":[{"id":"root","pivot":[0,0]}],"shapes":["## + many.joined(separator: ",") + "]}"
    check(problems(crowded) == ["too many shapes"], "more than 900 shapes is too many: \(problems(crowded).prefix(3))")
}
for (index, item) in sceneGolden.cases.enumerated() {
    // The web scene encodes and decodes losslessly through the disk cache shape.
    if let data = try? JSONEncoder().encode(item.scene), let again = try? JSONDecoder().decode(PuppetScene.self, from: data) {
        check(again.shapes.count == item.scene.shapes.count && again.groups.count == item.scene.groups.count
            && again.problems().isEmpty, "golden scene \(index) survives the disk cache round trip")
    } else {
        check(false, "golden scene \(index) encodes and decodes")
    }
}

// MARK: drawing (Core Graphics, the same calls the app's Canvas makes)

func render(_ renderer: PuppetRenderer, _ channels: [Double], side: Int = 160, backdrop: Bool) -> [UInt8] {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("bitmap context") }
    context.clear(CGRect(x: 0, y: 0, width: side, height: side))
    context.translateBy(x: 0, y: CGFloat(side))
    context.scaleBy(x: 1, y: -1)
    renderer.draw(in: context, rect: CGRect(x: 0, y: 0, width: side, height: side), channels: channels, drawsBackdrop: backdrop)
    guard let data = context.data else { fatalError("bitmap data") }
    return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: side * side * 4))
}
for (index, prepared) in preparedFixtures.enumerated() {
    let renderer = PuppetRenderer(prepared)
    let rest = PuppetMotion.stillChannels(expression: "neutral", options: prepared.motion)
    let plain = render(renderer, rest, backdrop: false)
    let opaque = stride(from: 3, to: plain.count, by: 4).filter { plain[$0] > 200 }.count
    let fraction = Double(opaque) / Double(160 * 160)
    check(fraction > 0.2 && fraction < 0.95, "fixture \(index) draws a figure, not nothing or a full square (\(fraction))")
    let center = (72 * 160 + 80) * 4
    check(plain[center + 3] == 255, "fixture \(index) face centre is painted")
    let filled = render(renderer, rest, backdrop: true)
    check(stride(from: 3, to: filled.count, by: 4).allSatisfy { filled[$0] == 255 }, "fixture \(index) backdrop fills the square")
    var talking = rest
    talking[PuppetChannel.mouthOpen.rawValue] = 1
    talking[PuppetChannel.eyeBlink.rawValue] = 1
    let moved = render(renderer, talking, backdrop: true)
    let changed = stride(from: 0, to: moved.count, by: 4).filter { moved[$0] != filled[$0] || moved[$0 + 1] != filled[$0 + 1] }.count
    check(changed > 30, "fixture \(index) an open mouth and closed eyes change the picture (\(changed) pixels)")
}

if !failures.isEmpty {
    print("PUPPET TESTS FAILED: \(failures.count) of \(count) checks")
    for failure in failures.prefix(40) { print("  - " + failure) }
    exit(1)
}
print("Puppet tests passed: \(count) checks (\(matrixChecks) matrices, \(coordinateChecks) coordinates, \(alphaChecks) alphas, \(motionChecks) motion channel values).")
