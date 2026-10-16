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
    var changed = 0
    for pixel in stride(from: 0, to: moved.count, by: 4) {
        let red: UInt8 = moved[pixel], green: UInt8 = moved[pixel + 1]
        if red != filled[pixel] || green != filled[pixel + 1] { changed += 1 }
    }
    check(changed > 30, "fixture \(index) an open mouth and closed eyes change the picture (\(changed) pixels)")
}

// MARK: Body editor (PuppetRecipe.swift): recipe paths, sliders, accessories, Undo, words

let builderStart = count
func json(_ text: String) -> PuppetJSON {
    do { return try JSONDecoder().decode(PuppetJSON.self, from: Data(text.utf8)) } catch { fatalError("json \(text): \(error)") }
}
let small = json(#"{"hair":{"style":"bob"},"accessories":["round-glasses","cowboy-hat",7],"schema":1,"on":true,"gone":null}"#)
check(small.value(at: "hair.style") == .string("bob"), "path read finds a nested value")
check(small.value(at: "hair.color") == nil && small.value(at: "eyes.size") == nil, "path read of a missing key is nil")
check(small.value(at: "on") == .bool(true) && small.value(at: "schema") == .number(1), "true stays a Bool and 1 stays a number")
check(small.value(at: "gone") == .null, "null survives decoding")
let recoloured = small.setting(.string("auburn"), at: "hair.color")
check(recoloured.value(at: "hair.color") == .string("auburn") && recoloured.value(at: "hair.style") == .string("bob"),
    "path write keeps the sibling fields")
check(small.value(at: "hair.color") == nil, "path write leaves the original recipe alone")
check(small.setting(.number(0.3), at: "eyes.size").value(at: "eyes.size") == .number(0.3), "path write creates missing objects")
check(small.setting(.string("dusk"), at: "backdrop").value(at: "backdrop") == .string("dusk"), "path write at the top level")
check(small.setting(.string("x"), at: "on.deeper").value(at: "on.deeper") == .string("x"), "path write through a non-object makes an object")
if let encoded = try? JSONEncoder().encode(recoloured), let again = try? JSONDecoder().decode(PuppetJSON.self, from: encoded) {
    check(again == recoloured, "a recipe survives encoding and decoding unchanged")
} else {
    check(false, "a recipe encodes and decodes")
}

check(PuppetRecipeEdit.sliderWords(0.2, low: "Narrow", high: "Wide") == "Narrow, 20 percent", "slider words near the low end")
check(PuppetRecipeEdit.sliderWords(0.5, low: "Narrow", high: "Wide") == "In between, 50 percent", "slider words in the middle")
check(PuppetRecipeEdit.sliderWords(0.8, low: "Narrow", high: "Wide") == "Wide, 80 percent", "slider words near the high end")
check(PuppetRecipeEdit.sliderWords(0, low: "None", high: "Very rosy") == "None, 0 percent", "slider words at zero")
check(PuppetRecipeEdit.sliderWords(1, low: "Small", high: "Big") == "Big, 100 percent", "slider words at one")
check(PuppetRecipeEdit.sliderWords(0.33, low: "a", high: "b") == "a, 33 percent"
    && PuppetRecipeEdit.sliderWords(0.34, low: "a", high: "b") == "In between, 34 percent"
    && PuppetRecipeEdit.sliderWords(0.66, low: "a", high: "b") == "In between, 66 percent"
    && PuppetRecipeEdit.sliderWords(0.67, low: "a", high: "b") == "b, 67 percent", "slider words switch at a third and two thirds")
check(PuppetRecipeEdit.sliderWords(.nan, low: "a", high: "b") == "In between, 50 percent"
    && PuppetRecipeEdit.sliderWords(1.7, low: "a", high: "b") == "b, 100 percent"
    && PuppetRecipeEdit.sliderWords(-2, low: "a", high: "b") == "a, 0 percent", "slider words clamp odd values")
let widthControl = PuppetCatalog.Control(path: "head.width", kind: .slider, name: "Face width", ends: ["Narrow", "Wide"])
check(PuppetRecipeEdit.sliderValue(widthControl, in: small) == 0.5, "a missing slider value reads as the middle")
check(PuppetRecipeEdit.sliderValue(widthControl, in: small.setting(.number(1.4), at: "head.width")) == 1, "a slider value clamps to one")
let widened = PuppetRecipeEdit.setting(slider: 0.456, for: widthControl, in: small)
check(widened.value(at: "head.width") == .number(0.46), "a slider writes two decimals")
check(widthControl.low == "Narrow" && widthControl.high == "Wide" && widthControl.isEditable, "slider ends and editability")

let glasses = PuppetCatalog.Control(path: "accessories", kind: .accessory, name: "Glasses",
    options: [.init(id: "", name: "None"), .init(id: "round-glasses", name: "Round glasses"), .init(id: "square-glasses", name: "Square glasses")],
    slot: "eyewear")
check(glasses.id == "accessories.eyewear", "accessory controls are told apart by slot")
check(PuppetRecipeEdit.selectedID(glasses, in: small) == "round-glasses", "the glasses slot reads what it wears")
let squared = PuppetRecipeEdit.choosing("square-glasses", for: glasses, in: small)
let squaredIDs = squared.value(at: "accessories")?.array?.compactMap(\.string) ?? []
check(squaredIDs.contains("square-glasses") && !squaredIDs.contains("round-glasses") && squaredIDs.contains("cowboy-hat"),
    "new glasses replace the old ones and keep the hat")
check(squared.value(at: "accessories")?.array?.contains(.number(7)) == true, "an accessory entry this build does not know rides along")
let bare = PuppetRecipeEdit.choosing("", for: glasses, in: squared)
check(PuppetRecipeEdit.selectedID(glasses, in: bare) == "" && (bare.value(at: "accessories")?.array?.compactMap(\.string) ?? []) == ["cowboy-hat"],
    "None takes the glasses off and nothing else")
let hairStyle = PuppetCatalog.Control(path: "hair.style", kind: .choice, name: "Hairstyle",
    options: [.init(id: "bob", name: "Bob"), .init(id: "afro", name: "Afro", note: "a full rounded afro")])
check(PuppetRecipeEdit.selectedOption(hairStyle, in: small)?.name == "Bob", "a choice reads its option")
check(PuppetRecipeEdit.selectedID(hairStyle, in: PuppetRecipeEdit.choosing("afro", for: hairStyle, in: small)) == "afro", "a choice writes its option")
check(PuppetCatalog.Option(id: "slim", name: "Slim", note: "slim").extraNote == ""
    && PuppetCatalog.Option(id: "broad", name: "Broad", note: "broad-shouldered").extraNote == "broad-shouldered",
    "an option's note shows only when it says more than its name")
check(!PuppetCatalog.Control(path: "x", kind: .choice, name: "X", options: [.init(id: "a", name: "A")]).isEditable
    && !PuppetCatalog.Control(path: "y", kind: .other, name: "Y").isEditable, "single-option and unknown controls are not shown")

var history = PuppetEditHistory()
let t0 = Date(timeIntervalSinceReferenceDate: 1000)
let r0 = json(#"{"n":0}"#), r1 = json(#"{"n":1}"#), r2 = json(#"{"n":2}"#)
history.record(before: r0, label: "Face width", key: "head.width", at: t0)
history.record(before: r1, label: "Face width", key: "head.width", at: t0.addingTimeInterval(1.5))
history.record(before: r2, label: "Face width", key: "head.width", at: t0.addingTimeInterval(3))
check(history.entries.count == 1 && history.entries[0].recipe == r0, "a run of changes to one control is one Undo step")
history.record(before: r1, label: "Face width", key: "head.width", at: t0.addingTimeInterval(5.5))
history.record(before: r2, label: "Hair colour", key: "hair.color", at: t0.addingTimeInterval(5.6))
check(history.entries.count == 3 && history.lastLabel == "Hair colour", "a pause or another control starts a new step")
let undone = history.undo()
check(undone?.recipe == r2 && undone?.label == "Hair colour" && history.entries.count == 2, "Undo returns the last step's recipe")
for index in 0..<100 { history.record(before: r0, label: "Design", key: "design-\(index)", at: t0) }
check(history.entries.count == PuppetEditHistory.limit && history.canUndo, "Undo keeps the newest \(PuppetEditHistory.limit) steps")
history.clear()
check(!history.canUndo && history.undo() == nil, "a cleared Undo list is empty")

let lookBefore = "An oval face with fair skin. Round green eyes, soft brows. Hair: a bob, auburn. Average build; moves in an easygoing way."
let lookAfter = "An oval face with fair skin. Round green eyes, soft brows. Hair: a bob, jet black. Average build; moves in an easygoing way."
check(PuppetDescriptionText.changedSentences(before: lookBefore, after: lookAfter) == "Hair: a bob, jet black.", "only the changed sentence is said")
check(PuppetDescriptionText.changedSentences(before: lookBefore, after: lookBefore) == "", "no change says nothing")
check(PuppetDescriptionText.changedSentences(before: "", after: "One. Two.") == "One. Two.", "a first description is said whole")
check(PuppetDescriptionText.sentences("Size 0.5 is fine. Next one! Last?  ") == ["Size 0.5 is fine.", "Next one!", "Last?"],
    "sentences split at an end mark and a space, not inside a number")
check(PuppetDescriptionText.dollars(0.0012) == "$0.0012" && PuppetDescriptionText.dollars(0.031) == "$0.03"
    && PuppetDescriptionText.dollars(0) == "$0.00" && PuppetDescriptionText.dollars(.nan) == "$0.00", "cost words")

// The real catalog and a real saved body, as the server sends them (written by the kit).
struct BuilderSample: Decodable {
    struct Body: Decodable {
        let rev: Int
        let recipe: PuppetJSON
        let description: String
        let scene: PuppetScene
    }
    let catalog: PuppetCatalogReply
    let body: Body
}
let samplePath = ProcessInfo.processInfo.environment["PUPPET_BUILDER_SAMPLE"] ?? "Sources/PuppetBuilderSample.json"
if let data = try? Data(contentsOf: URL(fileURLWithPath: samplePath)) {
    do {
        let sample = try JSONDecoder().decode(BuilderSample.self, from: data)
        let controls = sample.catalog.catalog.sections.flatMap(\.controls)
        check(sample.catalog.catalog.sections.count >= 6 && controls.count >= 40, "the catalog has its sections (\(controls.count) controls)")
        check(controls.allSatisfy { $0.kind != .other }, "every catalog control kind is one the editor draws")
        check(Set(controls.map(\.id)).count == controls.count, "every control has its own id")
        for control in controls where control.isEditable {
            switch control.kind {
            case .slider:
                check(control.ends.count == 2, "\(control.id) names both ends")
                let start = PuppetRecipeEdit.sliderValue(control, in: sample.catalog.defaults)
                check(start >= 0 && start <= 1 && sample.catalog.defaults.value(at: control.path)?.number != nil,
                    "\(control.id) has a default value")
                let moved = PuppetRecipeEdit.setting(slider: 0.3, for: control, in: sample.catalog.defaults)
                check(PuppetRecipeEdit.sliderValue(control, in: moved) == 0.3, "\(control.id) writes and reads back")
            case .choice, .color, .accessory:
                check(Set(control.options.map(\.id)).count == control.options.count, "\(control.id) option ids are unique")
                check(control.options.allSatisfy { !$0.name.isEmpty }, "\(control.id) every option has a spoken name")
                if control.kind == .accessory {
                    check(control.options.first?.id == "" && control.slot != nil, "\(control.id) starts with None and has a slot")
                } else {
                    let chosen = PuppetRecipeEdit.selectedID(control, in: sample.catalog.defaults)
                    check(control.options.contains { $0.id == chosen }, "\(control.id) default \(chosen) is one of its options")
                    let saved = PuppetRecipeEdit.selectedID(control, in: sample.body.recipe)
                    check(control.options.contains { $0.id == saved }, "\(control.id) saved \(saved) is one of its options")
                }
                for option in control.options {
                    let next = PuppetRecipeEdit.choosing(option.id, for: control, in: sample.body.recipe)
                    if PuppetRecipeEdit.selectedID(control, in: next) != option.id {
                        check(false, "\(control.id) choosing \(option.id) reads back")
                    }
                }
                check(true, "\(control.id) every option reads back after choosing")
            case .other:
                break
            }
        }
        check(sample.body.rev > 0 && !sample.body.description.isEmpty, "the sample body has a revision and words")
        check(sample.body.scene.problems().isEmpty && PuppetPreparedScene(scene: sample.body.scene) != nil, "the sample body's scene draws")
    } catch {
        check(false, "the builder sample decodes: \(error)")
    }
} else {
    check(false, "missing builder sample at \(samplePath)")
}
let builderChecks = count - builderStart

if !failures.isEmpty {
    print("PUPPET TESTS FAILED: \(failures.count) of \(count) checks")
    for failure in failures.prefix(40) { print("  - " + failure) }
    exit(1)
}
print("Puppet tests passed: \(count) checks (\(matrixChecks) matrices, \(coordinateChecks) coordinates, \(alphaChecks) alphas, \(motionChecks) motion channel values, \(builderChecks) body editor checks).")
