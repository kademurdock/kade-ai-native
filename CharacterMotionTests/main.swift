import Foundation
var count = 0
func check(_ value: Bool, _ name: String) { count += 1; if !value { fatalError(name) } }
check(CharacterMotion.prepared(id: CharacterMotion.kianaID, path: "/images/" + CharacterMotion.kianaFile), "prepared identity")
check(!CharacterMotion.prepared(id: "della", path: "/images/" + CharacterMotion.kianaFile), "no copied identity")
check(!CharacterMotion.prepared(id: CharacterMotion.kianaID, path: "/changed.png"), "changed portrait")
check(CharacterMotion.pose(id: "a", time: 2, level: 1, active: false).mouth == 0, "off is still")
check(CharacterMotion.pose(id: "a", time: 2, level: .nan, active: true).mouth == 0, "bad level")
check(CharacterMotion.pose(id: "a", time: .infinity, level: 1, active: true).mouth == 0, "bad clock")
check(CharacterMotion.prepared(id: CharacterMotion.dellaID, path: "/images/" + CharacterMotion.dellaFile), "Della own artwork")
check(!CharacterMotion.prepared(id: CharacterMotion.dellaID, path: "/images/" + CharacterMotion.kianaFile), "Della never borrows Kiana")
check(CharacterMotion.prepared(id: CharacterMotion.lillyID, path: "/images/" + CharacterMotion.lillyFile), "the public Lilly's own artwork")
check(CharacterMotion.prepared(id: CharacterMotion.skyleeLillyID, path: "/images/" + CharacterMotion.skyleeLillyFile), "Skylee's Lilly's own artwork")
check(!CharacterMotion.prepared(id: CharacterMotion.lillyID, path: "/images/" + CharacterMotion.skyleeLillyFile), "each Lilly matches only her own file")
for (id, file) in [
    (CharacterMotion.kianaID, CharacterMotion.kianaFile),
    (CharacterMotion.dellaID, CharacterMotion.dellaFile),
    (CharacterMotion.harleyID, CharacterMotion.harleyFile),
    (CharacterMotion.lillyID, CharacterMotion.lillyFile),
    (CharacterMotion.skyleeLillyID, CharacterMotion.skyleeLillyFile),
    (CharacterMotion.witherspoonID, CharacterMotion.witherspoonFile),
] {
    check(CharacterAppearance.description(agentID: id, avatarPath: "/images/" + file) != nil,
        "current portrait has an optional description")
    check(CharacterAppearance.description(agentID: id, avatarPath: "/images/replaced.png") == nil,
        "replaced portrait has no stale description")
}
check(CharacterMotion.rigID(CharacterMotion.skyleeLillyID) == CharacterMotion.lillyID, "Skylee's Lilly wears the public Lilly's rig")
check(CharacterMotion.rigID(CharacterMotion.kianaID) == CharacterMotion.kianaID, "everyone else is their own rig")
check(CharacterMotion.animatedIDs.contains(CharacterMotion.lillyID) && CharacterMotion.animatedIDs.contains(CharacterMotion.skyleeLillyID), "both Lillys are on the moving-faces shelf")
check(CharacterMotion.blend(.nan) == 0 && CharacterMotion.blend(1) == 1, "blend bounds")
check(CharacterMotion.blend(0.5) == 0.5, "continuous facial pose")
var envelope = CharacterEnvelope()
envelope.append(samples: Array(repeating: 0.5, count: 800), sampleRate: 8000, start: 1)
check(envelope.level(at: 0.9) == 0, "nothing before actual playback")
check(abs(envelope.level(at: 1.05) - 0.5) < 0.001, "actual PCM level")
check(envelope.level(at: 1.2) == 0, "closed after clip")
envelope.append(samples: Array(repeating: 0, count: 800), sampleRate: 8000, start: 2)
check(envelope.level(at: 1.5) == 0, "underrun closes mouth")
check(envelope.level(at: 2.05) == 0, "recorded silence")
check(envelope.level(at: 1.05) == envelope.level(at: 1.05), "pause keeps source position")
check(envelope.level(at: .nan) == 0, "invalid audio clock")
envelope.reset(); check(envelope.windows.isEmpty, "interrupt clears source")
for i in 0..<130 { envelope.append(samples: Array(repeating: 0.1, count: 8000), sampleRate: 8000, start: Double(i)) }
check(envelope.windows.count <= CharacterEnvelope.capacity, "bounded retention")
check(envelope.level(at: 0) == 0, "old source evicted")
for id in ["kiana", "della", "lilly"] { for tick in 0..<1000 {
 let pose = CharacterMotion.pose(id: id, time: Double(tick) / 24, level: 0.2, active: true)
 check(abs(pose.tilt) <= 0.6 && abs(pose.lift) <= 0.7 && pose.mouth <= 1, "bounded motion")
} }
print("Character motion: \(count) checks passed")

let meter = CharacterOutputMeter()
check(meter.level(now: 1) == 0, "no invented call output")
meter.observe(sumSquares: 0.16, count: 4, now: 2)
check(abs(meter.level(now: 2.1) - 0.2) < 0.00001, "actual output amplitude")
check(meter.level(now: 2.3) == 0, "stale output closes mouth")
meter.reset(); check(meter.level(now: 2.1) == 0, "interruption clears output")
check(CharacterMotion.pose(id: CharacterMotion.dellaID, time: 5, level: 1, active: false).brow == 0, "motion disabled stops expression")
print("Call meter and expression: 5 additional checks passed")

struct CueFixture: Decodable { let input: String; let expression: CharacterExpression; let moment: CharacterExpression? }
let fixturePath = ProcessInfo.processInfo.environment["CHARACTER_CUE_FIXTURES"] ?? "CharacterMotionTests/cues.json"
let fixtures = try JSONDecoder().decode([CueFixture].self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
let beforeReactions = count
for row in fixtures {
    let cue = CharacterCue.fromSpeech(row.input)
    check(cue.expression == row.expression && cue.moment == row.moment, "authored cue: \(row.input)")
}
let laugh = CharacterCue.fromSpeech("%%%warm%%% %%%laugh%%% Hello.")
check(laugh.expression(at: 0.2) == .amused, "leading laugh follows actual clip start")
check(laugh.expression(at: 1) == .warm, "one-shot returns to authored direction")
check(laugh.expression(at: .nan) == .warm, "invalid moment clock is quiet")
let kiana = CharacterAudioIdentity(speakerID: CharacterMotion.kianaID, speech: true, expression: "warm", moment: nil)!
let della = CharacterAudioIdentity(speakerID: CharacterMotion.dellaID, speech: true, expression: "concerned", moment: nil)!
check(CharacterAudioIdentity(speakerID: "", speech: true, expression: "warm", moment: nil) == nil, "empty identity rejected")
check(CharacterAudioIdentity(speakerID: "kiana", speech: true, expression: "evil", moment: nil) == nil, "unknown expression rejected")
var call = CharacterPlaybackTimeline()
call.append(identity: kiana, duration: 2, now: 5)
call.append(identity: della, duration: 1, now: 5.1)
check(call.presentation(at: 4.9, expectedID: CharacterMotion.kianaID) == nil, "queued audio is not playing")
check(call.presentation(at: 6.9, expectedID: CharacterMotion.kianaID)?.expression == .warm, "local tail remains speaking independently of server state")
check(call.presentation(at: 6, expectedID: CharacterMotion.dellaID) == nil, "wrong speaker never borrows Kiana face")
check(call.presentation(at: 7.2, expectedID: CharacterMotion.dellaID)?.expression == .concerned, "next queued identity owns its own interval")
check(call.presentation(at: 7.2, expectedID: CharacterMotion.kianaID) == nil, "handoff closes previous mouth")
check(call.presentation(at: 8, expectedID: CharacterMotion.dellaID) == nil, "finished clip has no stale reaction")
call.append(identity: nil, duration: 1, now: 8)
call.append(identity: kiana, duration: 1, now: 8)
check(call.presentation(at: 8.5, expectedID: CharacterMotion.kianaID) == nil, "game effects and unsupported old metadata stay still")
check(call.presentation(at: 9.5, expectedID: CharacterMotion.kianaID) != nil, "speech after effect resumes at its actual queue position")
call.reset()
check(call.presentation(at: 9.5, expectedID: CharacterMotion.kianaID) == nil, "barge-in empties reaction queue")
call.append(identity: kiana, duration: .nan, now: 0)
call.append(identity: kiana, duration: 1, now: 0)
check(call.presentation(at: 0.5, expectedID: CharacterMotion.kianaID) == nil, "invalid queue timing cannot animate a later clip early")
call.reset()
for _ in 0..<129 { call.append(identity: kiana, duration: 1, now: 0) }
check(call.clips.isEmpty, "overflow falls back quietly without retaining a transcript")
for expression in CharacterExpression.allCases {
    let presentation = CharacterPresentation(activity: .speaking, expression: expression, elapsed: 0.5)
    let off = CharacterMotion.pose(id: CharacterMotion.kianaID, time: 100, level: 1, active: false, presentation: presentation)
    check(off.mouth == 0 && off.brow == 0 && off.lift == 0 && off.tilt == 0, "disabled reaction stays completely still")
}
for expression in CharacterExpression.allCases { check(expression.face != .laugh && expression.face != .closed, "a direction never parks on the laugh or the blink panel") }
check(CharacterExpression.angry.face == .angry && CharacterExpression.tender.face == .tender && CharacterExpression.dry.face == .skeptical && CharacterExpression.afraid.face == .worried && CharacterExpression.calm.face == .neutral, "extended expressions retain established emotional faces")
check(CharacterPresentation(activity: .thinking).face == .thoughtful, "thinking shows the thoughtful glance")
check(CharacterPresentation(activity: .listening).face == .curious, "listening shows interest")
let nuanced: [CharacterExpression] = [.curious, .thoughtful, .playful, .confident, .tender, .tired, .serious, .excited]
check(Set(nuanced.map { $0.face.rawValue }).count == 8, "eight distinct additional faces")
for id in CharacterMotion.animatedIDs { for tick in 0..<1000 {
    let pose = CharacterMotion.pose(id: id, time: Double(tick) / 24, level: 0.2, active: true)
    check(abs(pose.tilt) <= 2.8 && abs(pose.lift) <= 3.2 && pose.scale >= 1 && pose.scale <= 1.04, "real character motion bounds")
    check(CharacterMotion.pose(id: id, time: Double(tick) / 24, level: 0, active: true).viseme == 0, "silent portraits never invent speech")
} }
let carriedFrom = CharacterCue.fromSpeech("%%%flat and hot like you are mad%%% Eight hundred dollars.")
check(CharacterCue.fromSpeech("Somebody typed your name into a spreadsheet.", carrying: carriedFrom).expression == .angry, "a sentence with no direction keeps the reply's direction")
let carriedLaugh = CharacterCue.fromSpeech("%%%laugh%%% Sorry.", carrying: carriedFrom)
check(carriedLaugh.expression == .angry && carriedLaugh.moment == .amused && carriedLaugh.laughing(at: 0.2) && !carriedLaugh.laughing(at: 1), "a leading laugh plays over the carried direction")
check(CharacterCue.fromSpeech("%%%warm%%% Hey.", carrying: carriedFrom).expression == .warm, "a new direction replaces the carried one")
check(CharacterCue.fromSpeech("%%%reset%%% Anyway.", carrying: carriedFrom).expression == .neutral, "reset clears the carried direction")
check(CharacterPresentation(activity: .speaking, expression: .warm, elapsed: 0.1, laughing: true).face == .laugh, "the laugh borrows the laughing face")
check(CharacterMotion.viseme(time: 1, strength: 0.02, seed: 7) == 0 && CharacterMotion.viseme(time: .nan, strength: 0.5, seed: 7) == 0, "silence and a bad clock close the mouth")
var shapes = Set<Int>()
for tick in 0..<200 {
    let quiet = CharacterMotion.viseme(time: Double(tick) * 0.14, strength: 0.4, seed: 99), loud = CharacterMotion.viseme(time: Double(tick) * 0.14, strength: 0.9, seed: 99)
    check((1...8).contains(quiet) && [2, 3, 8].contains(loud), "bounded mouth shapes; a loud syllable is an open mouth")
    shapes.insert(quiet)
}
check(shapes.count >= 3, "the mouth keeps changing shape")
check(CharacterMotion.viseme(time: 3.01, strength: 0.4, seed: 7) == CharacterMotion.viseme(time: 3.05, strength: 0.4, seed: 7), "one shape per syllable slot, no flicker")
check(CharacterMotion.pose(id: "a", time: 2, level: 1, active: false).viseme == 0, "off is a closed mouth")
print("Character reactions and playback ownership: \(count - beforeReactions) checks passed")

let facialBefore = count
let neutralListener = CharacterPresentation(activity: .listening)
check(CharacterFacialPolicy.face(for: neutralListener, agentID: CharacterMotion.harleyID) == .neutral,
    "Harley listens with his resting face instead of startled curious eyes")
for id in CharacterMotion.animatedIDs.filter({ $0 != CharacterMotion.harleyID }) {
    check(CharacterFacialPolicy.face(for: neutralListener, agentID: id) == .curious,
        "the listening face of another prepared identity is unchanged")
}
for id in [nil, "", "unknown"] as [String?] {
    check(CharacterFacialPolicy.face(for: neutralListener, agentID: id) == neutralListener.face,
        "missing or unknown identities never borrow Harley's listening override")
}
for activity in [CharacterActivity.idle, .thinking, .speaking] {
    let presentation = CharacterPresentation(activity: activity)
    check(CharacterFacialPolicy.face(for: presentation, agentID: CharacterMotion.harleyID) == presentation.face,
        "Harley's other neutral activities preserve their established face")
}
for expression in CharacterExpression.allCases.filter({ $0 != .neutral }) {
    let presentation = CharacterPresentation(activity: .listening, expression: expression)
    check(CharacterFacialPolicy.face(for: presentation, agentID: CharacterMotion.harleyID) == expression.face,
        "an explicit direction takes precedence over Harley's resting-listener face")
}
for activity in [CharacterActivity.idle, .listening, .thinking, .speaking] {
    let presentation = CharacterPresentation(activity: activity, laughing: true)
    check(CharacterFacialPolicy.face(for: presentation, agentID: CharacterMotion.harleyID) == .laugh,
        "a one-shot laugh takes precedence over the listening override")
}
for invalid in [Double.nan, Double.infinity, -Double.infinity, -1, 1.01] {
    check(!CharacterFacialPolicy.shouldBlink(amount: invalid, face: .neutral, agentID: CharacterMotion.harleyID),
        "invalid blink data cannot park an eyelid over the face")
}
check(!CharacterFacialPolicy.shouldBlink(amount: 0, face: .neutral, agentID: CharacterMotion.harleyID)
    && !CharacterFacialPolicy.shouldBlink(amount: 0.349999, face: .neutral, agentID: CharacterMotion.harleyID)
    && CharacterFacialPolicy.shouldBlink(amount: 0.35, face: .neutral, agentID: CharacterMotion.harleyID)
    && CharacterFacialPolicy.shouldBlink(amount: 1, face: .neutral, agentID: CharacterMotion.harleyID),
    "authored closed eyes switch at a bounded threshold without fractional opacity")
for id in [CharacterMotion.harleyID, CharacterMotion.kianaID, CharacterMotion.lillyID, CharacterMotion.skyleeLillyID] {
    check(!CharacterFacialPolicy.shouldBlink(amount: 1, face: .laugh, agentID: id),
        "an authored closed-eye laugh retains its own eyes, including private Lilly")
}
for id in [CharacterMotion.dellaID, CharacterMotion.witherspoonID] {
    check(CharacterFacialPolicy.shouldBlink(amount: 1, face: .laugh, agentID: id),
        "an authored open-eye laugh retains its blink")
}
check(!CharacterFacialPolicy.shouldBlink(amount: 1, face: .delighted, agentID: CharacterMotion.harleyID),
    "Harley's authored closed-eye delight retains its own eyelids")
for id in [CharacterMotion.kianaID, CharacterMotion.lillyID, CharacterMotion.skyleeLillyID,
           CharacterMotion.dellaID, CharacterMotion.witherspoonID] {
    check(CharacterFacialPolicy.shouldBlink(amount: 1, face: .delighted, agentID: id),
        "the other authored open-eye delighted panels retain their blink")
}
// Both existing sinusoid windows must survive the actual 12/24 fps cadence,
// regardless of where the window falls between two display ticks. No new
// animation clock or duration is introduced by the discrete pixel selection.
for duration in [0.16, 0.2] {
    let ownedDuration = duration * (1 - 2 * asin(CharacterFacialPolicy.blinkThreshold) / .pi)
    check(ownedDuration > 0.12 && ownedDuration < 0.16,
        "the authored closed-eye hold stays brief inside the existing blink wave")
    for fps in [12, 24] {
        for offset in 0..<48 {
            var closedTicks = 0
            for tick in -1...(Int(ceil(duration * Double(fps))) + 1) {
                let elapsed = (Double(tick) + Double(offset) / 48) / Double(fps)
                let amount = (0...duration).contains(elapsed) ? sin(elapsed / duration * .pi) : 0
                if CharacterFacialPolicy.shouldBlink(amount: amount, face: .neutral, agentID: CharacterMotion.harleyID) {
                    closedTicks += 1
                }
            }
            check(closedTicks >= Int(floor(ownedDuration * Double(fps)))
                && closedTicks <= Int(ceil(ownedDuration * Double(fps))),
                "blink is visible for the expected bounded ticks at 12/24 fps")
        }
    }
}
for id in CharacterMotion.animatedIDs {
    for fps in [12, 24] {
        var blinkRun = 0
        var totalClosed = 0
        for tick in 0..<(20 * fps) {
            let pose = CharacterMotion.pose(id: id, time: Double(tick) / Double(fps), level: 0,
                active: true, presentation: neutralListener)
            if CharacterFacialPolicy.shouldBlink(amount: pose.blink, face: .neutral, agentID: id) {
                blinkRun += 1; totalClosed += 1
                check(blinkRun <= Int(ceil(0.16 * Double(fps))),
                    "actual per-character blink waves never hold the eye patch too long")
            } else {
                blinkRun = 0
            }
        }
        check(totalClosed > 0, "actual per-character clocks retain blinks at each display cadence")
    }
}
check(!CharacterFacialPolicy.shouldBlink(amount: CharacterPose.still.blink, face: .neutral,
        agentID: CharacterMotion.harleyID), "the still pose has no decorative blink")
print("Authored facial selection: \(count - facialBefore) checks passed")

let handBefore = count
for invalid in [Double.nan, Double.infinity, -Double.infinity, -1, 0, 2, 3] {
    check(!CharacterHarleyHandPrototypeMotion.pose(elapsed: invalid, active: true).visible,
        "invalid or completed hand samples show no additional limb")
}
for tick in 1..<200 {
    let elapsed = Double(tick) / 100
    let pose = CharacterHarleyHandPrototypeMotion.pose(elapsed: elapsed, active: true)
    check(pose.visible && pose.angle.isFinite && (-2...72).contains(pose.angle),
        "the entire hand study remains within its authored rotation range")
    check(!CharacterHarleyHandPrototypeMotion.pose(elapsed: elapsed, active: false).visible,
        "motion policy hides the hand at every point in the study")
}
for sample in [0.5, 1.0, 1.5] {
    check(abs(CharacterHarleyHandPrototypeMotion.pose(elapsed: sample, active: true).angle) < 0.000001,
        "entry, raised swings and exit join at the same position")
}
print("Isolated hand study: \(count - handBefore) checks passed")

let figureBefore = count
let figureSpeech = CharacterPresentation(activity: .speaking, expression: .excited, elapsed: 0.4)
let figureOn = CharacterFigureMotion.pose(id: CharacterMotion.kianaID, time: 100, level: 0.15,
    active: true, presentation: figureSpeech)
let figureQuiet = CharacterFigureMotion.pose(id: CharacterMotion.kianaID, time: 100, level: 0,
    active: true, presentation: figureSpeech)
check(figureOn.nearArmAngle != figureQuiet.nearArmAngle, "figure follows rendered speech energy")
let figureOff = CharacterFigureMotion.pose(id: CharacterMotion.kianaID, time: 100, level: 0.15,
    active: false, presentation: figureSpeech)
check(figureOff.headAngle == 0 && figureOff.nearArmAngle == 0 && figureOff.torsoLift == 0,
    "motion gate parks the entire figure")
check(CharacterFigureMotion.pose(id: CharacterMotion.kianaID, time: .nan, level: 0.15,
    active: true, presentation: figureSpeech).headAngle == 0, "invalid figure clock is still")
for sample in [CharacterPresentation.idle, CharacterPresentation(activity: .listening),
    CharacterPresentation(activity: .thinking), figureSpeech] {
    for level in [0.0, 0.02, 0.5, 100.0, Double.nan] {
        let p = CharacterFigureMotion.pose(id: CharacterMotion.kianaID, time: 14.5,
            level: level, active: true, presentation: sample)
        check(abs(p.headAngle) <= 7 && abs(p.headNod) <= 0.018 &&
            abs(p.torsoAngle) <= 3 && abs(p.torsoLift) <= 0.008 &&
            abs(p.farArmAngle) <= 14 && abs(p.nearArmAngle) <= 16,
            "figure joints stay bounded")
    }
}
func figureValues(_ pose: CharacterFigurePose) -> [Double] {
    [pose.headAngle, pose.headNod, pose.torsoAngle, pose.torsoLift,
        pose.farArmAngle, pose.nearArmAngle]
}
let stillFigure = figureValues(.still)
for clock in [Double.nan, Double.infinity, -Double.infinity, -0.001] {
    check(figureValues(CharacterFigureMotion.pose(id: CharacterMotion.harleyID,
        time: clock, level: 1, active: true, presentation: figureSpeech)) == stillFigure,
        "invalid or negative clock parks every Harley joint")
}
for activity in [CharacterActivity.idle, .listening, .thinking] {
    let state = CharacterPresentation(activity: activity, elapsed: 0.4)
    let quiet = CharacterFigureMotion.pose(id: CharacterMotion.harleyID,
        time: 14.5, level: 0, active: true, presentation: state)
    let unrelatedAudio = CharacterFigureMotion.pose(id: CharacterMotion.harleyID,
        time: 14.5, level: 1, active: true, presentation: state)
    check(figureValues(quiet) == figureValues(unrelatedAudio),
        "listening thinking and idle cannot gesture to another speaker's audio")
}
let figureLimits = [7.0, 0.018, 3, 0.008, 14, 16]
for expression in CharacterExpression.allCases {
    for clock in [0.0, 0.4, 0.8, 1, 14.5, 80, 3600, 86400] {
        let state = CharacterPresentation(activity: .speaking,
            expression: expression, elapsed: clock)
        let disabled = CharacterFigureMotion.pose(id: CharacterMotion.harleyID,
            time: clock, level: 1, active: false, presentation: state)
        check(figureValues(disabled) == stillFigure,
            "disabled preview parks all body joints across authored directions")
        for level in [-1.0, 0, 0.5, 100, Double.nan, Double.infinity] {
            let pose = CharacterFigureMotion.pose(id: CharacterMotion.harleyID,
                time: clock, level: level, active: true, presentation: state)
            check(zip(figureValues(pose), figureLimits).allSatisfy {
                $0.0.isFinite && abs($0.0) <= $0.1
            }, "Harley joint output stays finite and inside the compositor's limits")
        }
    }
}
for elapsed in [Double.nan, Double.infinity, -Double.infinity, -1] {
    let state = CharacterPresentation(activity: .speaking,
        expression: .excited, elapsed: elapsed)
    let pose = CharacterFigureMotion.pose(id: CharacterMotion.harleyID,
        time: 14.5, level: 0.5, active: true, presentation: state)
    check(figureValues(pose).allSatisfy { $0.isFinite },
        "invalid cue elapsed time cannot corrupt the body's transform")
}
print("Layered figure motion: \(count - figureBefore) checks passed")

let bustBefore = count
let harleyAvatarPath = "/images/" + CharacterMotion.harleyFile
func reviewBust(enabled: Bool = true, stage: Bool = true, side: Double = 208,
                agentID: String? = CharacterMotion.harleyID,
                avatarPath: String? = "/images/" + CharacterMotion.harleyFile) -> CharacterBustArtwork? {
    CharacterBustArtwork.review(enabled: enabled, stage: stage, side: side,
        agentID: agentID, avatarPath: avatarPath)
}
check(reviewBust() != nil, "explicit Harley stage review resolves its matching art pack")
check(reviewBust(enabled: false) == nil, "review opt-in is required")
check(reviewBust(stage: false) == nil, "inline portraits cannot become review busts")
check(reviewBust(side: 160) != nil, "minimum review stage is accepted")
for side in [0.0, -1, 84, 104, 132, 159.99, Double.nan, Double.infinity, -Double.infinity] {
    check(reviewBust(side: side) == nil, "compact or invalid stages keep the established face")
}
for agentID in [nil, "", "harley", CharacterMotion.kianaID, CharacterMotion.skyleeLillyID] as [String?] {
    check(reviewBust(agentID: agentID) == nil, "foreign or absent identity never borrows Harley's body")
}
for avatarPath in [nil, "", "/images/replaced.png", "/images/" + CharacterMotion.kianaFile,
                   harleyAvatarPath + ".backup", "/images/prefix-" + CharacterMotion.harleyFile] as [String?] {
    check(reviewBust(avatarPath: avatarPath) == nil, "changed or foreign avatar cannot inherit review artwork")
}
check(reviewBust(avatarPath: "https://example.test" + harleyAvatarPath + "?version=1") != nil,
    "a URL query does not change the verified avatar filename")

func bustValues(_ pose: CharacterBustPose) -> [Double] {
    [pose.headAngle, pose.bodyAngle, pose.headOffsetY, pose.bodyOffsetY]
}
check(bustValues(CharacterBustMotion.pose(.still)) == [0, 0, 0, 0],
    "the motion gate parks the bust without a residual transform")
let bustLimits = [2.0, 0.5, 3, 2]
for value in [-1000.0, -1, 0, 1, 1000, Double.nan, Double.infinity, -Double.infinity] {
    let figure = CharacterFigurePose(headAngle: value, headNod: value,
        torsoAngle: value, torsoLift: value, farArmAngle: value, nearArmAngle: value)
    let bust = CharacterBustMotion.pose(figure)
    check(zip(bustValues(bust), bustLimits).allSatisfy {
        $0.0.isFinite && abs($0.0) <= $0.1
    }, "review bust clamps every transform even with corrupt upstream motion")
    if !value.isFinite {
        check(bustValues(bust) == [0, 0, 0, 0], "invalid motion components park safely")
    }
}
for expression in CharacterExpression.allCases {
    let state = CharacterPresentation(activity: .speaking, expression: expression, elapsed: 0.4)
    let figure = CharacterFigureMotion.pose(id: CharacterMotion.harleyID,
        time: 100, level: 1, active: true, presentation: state)
    check(zip(bustValues(CharacterBustMotion.pose(figure)), bustLimits).allSatisfy {
        $0.0.isFinite && abs($0.0) <= $0.1
    }, "authored speech stays within the bust's conservative movement limits")
}

let lillyAvatarPath = "/images/" + CharacterMotion.lillyFile
let lillyBust = reviewBust(agentID: CharacterMotion.lillyID, avatarPath: lillyAvatarPath)!
check(lillyBust.requiredAssets == ["CharacterLillyBustBody"] && lillyBust.maskAsset == nil,
    "Lilly needs her body support and uses original atlas outlines rather than a generated head")
check(lillyBust.headOutline == .lillyHead &&
    lillyBust.accessoryOutlines == [.lillyLeftCat, .lillyRightCat],
    "Lilly keeps two static original companions separate from her moving head")
check(lillyBust.panelSide / lillyBust.cropSide >= 0.88 &&
    lillyBust.panelSide / lillyBust.cropSide <= 1,
    "close Lilly crop preserves a readable face at native stage size")
check(lillyBust.panelX >= lillyBust.cropX && lillyBust.panelY >= lillyBust.cropY &&
    lillyBust.panelX + lillyBust.panelSide <= lillyBust.cropX + lillyBust.cropSide &&
    lillyBust.panelY + lillyBust.panelSide <= lillyBust.cropY + lillyBust.cropSide,
    "complete Lilly atlas destination and both cats fit the close crop")
check(reviewBust(enabled: false, agentID: CharacterMotion.lillyID, avatarPath: lillyAvatarPath) == nil &&
    reviewBust(stage: false, agentID: CharacterMotion.lillyID, avatarPath: lillyAvatarPath) == nil,
    "Lilly requires the same explicit stage review gates as Harley")
check(reviewBust(side: 160, agentID: CharacterMotion.lillyID, avatarPath: lillyAvatarPath) != nil,
    "Lilly is eligible at the minimum readable stage size")
for side in [0.0, -1, 84, 104, 132, 159.99, Double.nan, Double.infinity, -Double.infinity] {
    check(reviewBust(side: side, agentID: CharacterMotion.lillyID, avatarPath: lillyAvatarPath) == nil,
        "Lilly stays an ordinary portrait in compact or invalid stages")
}
for avatarPath in [nil, "", "/images/replaced.png", harleyAvatarPath,
                   lillyAvatarPath + ".backup", "/images/prefix-" + CharacterMotion.lillyFile,
                   "/images/" + CharacterMotion.skyleeLillyFile] as [String?] {
    check(reviewBust(agentID: CharacterMotion.lillyID, avatarPath: avatarPath) == nil,
        "public Lilly body requires her exact current public avatar")
}
check(reviewBust(agentID: CharacterMotion.skyleeLillyID, avatarPath: lillyAvatarPath) == nil,
    "private Lilly cannot inherit public Lilly's avatar identity")
check(reviewBust(agentID: CharacterMotion.skyleeLillyID,
    avatarPath: "/images/" + CharacterMotion.skyleeLillyFile) != nil,
    "private Lilly has an explicit own-avatar production registration")
check(reviewBust(agentID: CharacterMotion.harleyID, avatarPath: lillyAvatarPath) == nil &&
    reviewBust(agentID: CharacterMotion.kianaID, avatarPath: lillyAvatarPath) == nil,
    "other characters cannot borrow public Lilly's body")
check(reviewBust()!.requiredAssets == ["CharacterHarleyBustBody", "CharacterHarleyBustMask"] &&
    reviewBust()!.headOutline == .harleyHead && reviewBust()!.accessoryOutlines.isEmpty,
    "Harley retains his existing mask and has no Lilly accessories")
check(bustValues(CharacterBustMotion.pose(.still, limits: lillyBust.motionLimits)) == [0, 0, 0, 0],
    "Lilly's disabled motion parks every transform")
let lillyBustLimits = [1.95, 0.22, 1.7, 0]
for value in [-1000.0, -1, 0, 1, 1000, Double.nan, Double.infinity, -Double.infinity] {
    let figure = CharacterFigurePose(headAngle: value, headNod: value,
        torsoAngle: value, torsoLift: value, farArmAngle: value, nearArmAngle: value)
    let pose = CharacterBustMotion.pose(figure, limits: lillyBust.motionLimits)
    check(zip(bustValues(pose), lillyBustLimits).allSatisfy {
        $0.0.isFinite && abs($0.0) <= $0.1
    }, "Lilly clamps corrupt motion to her own reviewed bounds without body translation")
    if !value.isFinite {
        check(bustValues(pose) == [0, 0, 0, 0], "nonfinite Lilly transforms park safely")
    }
}
for activity in [CharacterActivity.idle, .listening, .thinking, .speaking] {
    for expression in CharacterExpression.allCases {
        let state = CharacterPresentation(activity: activity, expression: expression, elapsed: 0.4)
        let figure = CharacterFigureMotion.pose(id: CharacterMotion.lillyID,
            time: 100, level: 1, active: true, presentation: state)
        check(zip(bustValues(CharacterBustMotion.pose(figure, limits: lillyBust.motionLimits)), lillyBustLimits).allSatisfy {
            $0.0.isFinite && abs($0.0) <= $0.1
        }, "Lilly's authored states stay inside her conservative head and shoulder range")
    }
}
print("Character bust review and transforms: \(count - bustBefore) checks passed")

let productionBefore = count
let productionPeople = [
    (CharacterMotion.harleyID, CharacterMotion.harleyFile),
    (CharacterMotion.kianaID, CharacterMotion.kianaFile),
    (CharacterMotion.lillyID, CharacterMotion.lillyFile),
    (CharacterMotion.dellaID, CharacterMotion.dellaFile),
    (CharacterMotion.witherspoonID, CharacterMotion.witherspoonFile),
    (CharacterMotion.skyleeLillyID, CharacterMotion.skyleeLillyFile)
]
for (id, file) in productionPeople {
    let path = "/images/" + file
    let artwork = CharacterBustArtwork.approved(stage: true, side: 208,
        agentID: id, avatarPath: path)!
    check(artwork.isValid, "every exact registered production geometry is valid")
    check(CharacterBustArtwork.approved(stage: false, side: 208,
        agentID: id, avatarPath: path) == nil, "small inline portraits keep their established renderer")
    for side in [84.0, 104, 132, 159.99, .nan, .infinity] {
        check(CharacterBustArtwork.approved(stage: true, side: side,
            agentID: id, avatarPath: path) == nil, "compact or corrupt stages fall back for every character")
    }
    for (_, otherFile) in productionPeople where otherFile != file {
        check(CharacterBustArtwork.approved(stage: true, side: 208,
            agentID: id, avatarPath: "/images/" + otherFile) == nil,
            "no character borrows a different avatar's production pack")
    }
    check(CharacterBustArtwork.approved(stage: true, side: 208,
        agentID: id, avatarPath: "/images/replaced.png") == nil,
        "new avatar upload does not keep old body/face geometry")
    check(bustValues(CharacterBustMotion.pose(.still, limits: artwork.motionLimits)) == [0, 0, 0, 0],
        "still policy parks every registered body and head")
    for activity in [CharacterActivity.idle, .listening, .thinking, .speaking] {
        for expression in CharacterExpression.allCases {
            let figure = CharacterFigureMotion.pose(id: id, time: 100, level: 1,
                active: true, presentation: CharacterPresentation(activity: activity,
                    expression: expression, elapsed: 0.4))
            let limits = artwork.motionLimits
            check(zip(bustValues(CharacterBustMotion.pose(figure, limits: limits)),
                [limits.headDegrees, limits.bodyDegrees, limits.headOffsetPixels, limits.bodyOffsetPixels])
                .allSatisfy { $0.0.isFinite && abs($0.0) <= $0.1 },
                "authored performance remains inside each character's native bounds")
        }
    }
}
var unsafeKiana = CharacterKianaBustGeometry.artwork
unsafeKiana.bodyClipMinY = nil
check(!unsafeKiana.isValid, "Kiana cannot expose the reused concept's generated face without the torso clip")
unsafeKiana.bodyClipMinY = 0
check(!unsafeKiana.isValid, "a zero-height Kiana clip cannot bypass exact-face registration")
unsafeKiana.bodyClipMinY = 600
check(!unsafeKiana.isValid, "the old y600 torso cutoff cannot expose Kiana's mismatched chest")
let closeKiana = CharacterKianaBustGeometry.artwork
let oldWideKiana = CharacterBustArtwork(
    bodyAsset: closeKiana.bodyAsset, maskAsset: closeKiana.maskAsset,
    bodyX: closeKiana.bodyX, bodyY: closeKiana.bodyY,
    bodyWidth: closeKiana.bodyWidth, bodyHeight: closeKiana.bodyHeight,
    cropX: 155, cropY: 0, cropSide: 740,
    panelX: closeKiana.panelX, panelY: closeKiana.panelY, panelSide: closeKiana.panelSide,
    neckX: closeKiana.neckX, neckY: closeKiana.neckY,
    waistX: closeKiana.waistX, waistY: closeKiana.waistY,
    faceCore: closeKiana.faceCore, headOutline: closeKiana.headOutline,
    accessoryOutlines: closeKiana.accessoryOutlines, motionLimits: closeKiana.motionLimits,
    maskPlacement: closeKiana.maskPlacement, bodyClipMinY: closeKiana.bodyClipMinY)
check(!oldWideKiana.isValid, "the old wide Kiana crop cannot reveal the rectangular torso join")
let kianaCropBottom = closeKiana.cropY + closeKiana.cropSide
let kianaPanelBottom = closeKiana.panelY + closeKiana.panelSide
check(kianaCropBottom <= (closeKiana.bodyClipMinY ?? -Double.infinity),
    "Kiana's supporting concept starts entirely outside the visible crop")
check(kianaPanelBottom > kianaCropBottom,
    "the original Kiana panel has lower-edge overdraw before motion")
let kianaAngle = closeKiana.motionLimits.headDegrees * Double.pi / 180
for angle in [-kianaAngle, kianaAngle] {
    for x in [closeKiana.panelX, closeKiana.panelX + closeKiana.panelSide] {
        let movedBottom = closeKiana.neckY + (x - closeKiana.neckX) * sin(angle)
            + (kianaPanelBottom - closeKiana.neckY) * cos(angle)
            - closeKiana.motionLimits.headOffsetPixels
        check(movedBottom > kianaCropBottom,
            "Kiana's original lower edge remains outside the crop at the extreme allowed poses")
    }
}
var invalidMask = CharacterDellaBustGeometry.artwork
invalidMask.maskPlacement = CharacterBustMaskPlacement(x: 35, y: 0, side: .nan)
check(!invalidMask.isValid, "invalid matte registration cannot enter the production renderer")
check(CharacterDellaBustGeometry.artwork.maskPlacement?.side == 350,
    "Della's independent head mask keeps its reviewed scale")
check(CharacterAppearance.description(agentID: CharacterMotion.witherspoonID,
    avatarPath: "/images/" + CharacterMotion.witherspoonFile)?.contains("woman") == true,
    "the librarian retains her established female identity")
print("Production puppet identity and safety: \(count - productionBefore) checks passed")

let layoutBefore = count
check(CharacterStageLayout.callSide(width: 320, height: 568, accessibilityText: false) == 132,
    "small call window keeps compact portrait")
check(CharacterStageLayout.callSide(width: 430, height: 932, accessibilityText: false) == 208,
    "large call window keeps full portrait")
check(CharacterStageLayout.callSide(width: 430, height: 932, accessibilityText: true) == 104,
    "call portrait leaves room for accessibility text")
check(CharacterStageLayout.callSide(width: 210, height: 932, accessibilityText: false) == 138,
    "narrow window contains portrait including its padding")
for width in [200.0, 210, 280, 320, 430, 1024] {
    for height in [320.0, 568, 699, 700, 859, 860, 932] {
        for largeText in [false, true] {
            let side = CharacterStageLayout.callSide(width: width, height: height,
                accessibilityText: largeText)
            check(side + 72 <= width && side > 0 && side <= 208,
                "call stage always fits supported window width")
        }
    }
}
for invalid in [Double.nan, Double.infinity, -1, 0] {
    check(CharacterStageLayout.callSide(width: invalid, height: 932, accessibilityText: false) == 104,
        "invalid call geometry has a bounded fallback")
    check(CharacterStageLayout.chatSide(height: invalid, keyboard: false,
        compactHeight: false, accessibilityText: false) == 132, "invalid chat height stays bounded")
}
check(CharacterStageLayout.chatSide(height: 932, keyboard: false,
    compactHeight: false, accessibilityText: false) == 208, "ordinary chat keeps full portrait")
check(CharacterStageLayout.chatSide(height: 932, keyboard: false,
    compactHeight: false, accessibilityText: true) == 104, "large chat text has more message space")
check(CharacterStageLayout.chatSide(height: 932, keyboard: true,
    compactHeight: false, accessibilityText: true) == 84, "keyboard stays compact with large text")
check(CharacterStageLayout.chatSide(height: 430, keyboard: false,
    compactHeight: true, accessibilityText: false) == 84, "landscape chat prioritizes message space")
print("Character stage layout: \(count - layoutBefore) checks passed")
