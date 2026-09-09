import Foundation
var count = 0
func check(_ value: Bool, _ name: String) { count += 1; if !value { fatalError(name) } }
check(CharacterMotion.prepared(id: CharacterMotion.kianaID, path: "/images/" + CharacterMotion.kianaFile), "prepared identity")
check(!CharacterMotion.prepared(id: "della", path: "/images/" + CharacterMotion.kianaFile), "no copied identity")
check(!CharacterMotion.prepared(id: CharacterMotion.kianaID, path: "/changed.png"), "changed portrait")
check(CharacterMotion.pose(id: "a", time: 2, level: 1, active: false).mouth == 0, "off is still")
check(CharacterMotion.pose(id: "a", time: 2, level: .nan, active: true).mouth == 0, "bad level")
check(CharacterMotion.pose(id: "a", time: .infinity, level: 1, active: true).mouth == 0, "bad clock")
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
