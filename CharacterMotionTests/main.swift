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
