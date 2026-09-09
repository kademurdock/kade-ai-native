import Foundation

/// Pure, bounded presentation data. Never owns a player, microphone or request.
struct CharacterPose {
    let mouth: Double
    let blink: Double
    let tilt: Double
    let lift: Double
    var brow: Double = 0
    static let still = CharacterPose(mouth: 0, blink: 0, tilt: 0, lift: 0)
}

enum CharacterMotion {
    static let kianaID = "agent_6llV0eMu4fmIaj8f2x1Sb"
    static let kianaFile = "agent-agent_6llV0eMu4fmIaj8f2x1Sb-avatar-1788871984269.png"
    static let dellaID = "agent_BSOLa3eNEZyjs-7abCjMt"
    static let dellaFile = "agent-agent_BSOLa3eNEZyjs-7abCjMt-avatar-1788941611099.png"
    static func blend(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let n = max(0, min(1, value))
        return (n * n * (3 - 2 * n) * 16).rounded() / 16
    }
    static func prepared(id: String?, path: String?) -> Bool {
        guard let path, let url = URL(string: path) else { return false }
        return (id == kianaID && url.lastPathComponent == kianaFile) || (id == dellaID && url.lastPathComponent == dellaFile)
    }
    static func pose(id: String, time: Double, level: Double, active: Bool) -> CharacterPose {
        guard active, time.isFinite, time >= 0 else { return .still }
        // Stable per-character phase; no synchronized marching portraits.
        let seed = id.utf8.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) }
        let phase = Double(seed % 1000) / 1000
        let period = 4.3 + phase * 0.8
        let t = time + phase * period
        let blinkPhase = t.truncatingRemainder(dividingBy: period)
        let secondBlink = floor(t / period).truncatingRemainder(dividingBy: 3) == 1 && blinkPhase > period - 0.52 && blinkPhase < period - 0.36
        let blink = secondBlink ? sin((blinkPhase - period + 0.52) / 0.16 * .pi) : (blinkPhase > period - 0.2 ? sin((blinkPhase - period + 0.2) / 0.2 * .pi) : 0)
        let mouth = level.isFinite ? max(0, min(1, (level - 0.008) * 5)) : 0
        let tempo = id == dellaID ? 0.8 : 1.0
        return CharacterPose(mouth: mouth, blink: blink,
            tilt: sin(t * 0.3 * tempo) * 0.28 + sin(t * 0.7 * tempo) * 0.32,
            lift: sin(t * 1.1 * tempo) * (0.18 + mouth * 0.4),
            brow: mouth * (0.35 + 0.25 * sin(t * 0.65 * tempo)) + max(0, sin(t * 0.43 * tempo)) * 0.12 * (1 - mouth))
    }
}

/// PCM summaries follow the player's source clock, including pause/rate changes.
/// Old frames are evicted; gaps and out-of-range reads produce a closed mouth.
struct CharacterEnvelope {
    struct Window { let start: Double; let end: Double; let level: Double }
    private(set) var windows: [Window] = []
    static let capacity = 6000
    mutating func reset() { windows.removeAll(keepingCapacity: true) }
    mutating func append(samples: [Float], sampleRate: Double, start: Double) {
        guard sampleRate.isFinite, (8000...192000).contains(sampleRate),
              start.isFinite, start >= 0, !samples.isEmpty else { return }
        let stride = max(1, Int(sampleRate * 0.02))
        // At most two minutes per append; avoid unbounded presentation work.
        guard samples.count <= Int(sampleRate * 120) else { return }
        for i in Swift.stride(from: 0, to: samples.count, by: stride) {
            let end = min(samples.count, i + stride)
            var sum = 0.0
            for j in i..<end { let v = samples[j]; if v.isFinite { sum += Double(v) * Double(v) } }
            windows.append(Window(start: start + Double(i) / sampleRate,
                end: start + Double(end) / sampleRate, level: sqrt(sum / Double(end - i))))
        }
        if windows.count > Self.capacity { windows.removeFirst(windows.count - Self.capacity) }
    }
    func level(at time: Double) -> Double {
        guard time.isFinite, time >= 0 else { return 0 }
        var lo = 0, hi = windows.count
        while lo < hi { let mid = (lo + hi) / 2; if windows[mid].end <= time { lo = mid + 1 } else { hi = mid } }
        guard lo < windows.count, windows[lo].start <= time else { return 0 }
        return windows[lo].level
    }
}

/// Output-only meter. No audio is stored, transmitted, or sent to the main actor.
final class CharacterOutputMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    private var sampledAt = -Double.infinity
    func observe(sumSquares: Double, count: Int, now: Double) {
        guard sumSquares.isFinite, sumSquares >= 0, count > 0, now.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        value = min(1, sqrt(sumSquares / Double(count)))
        sampledAt = now
    }
    func level(now: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard now.isFinite, now >= sampledAt, now - sampledAt < 0.18 else { return 0 }
        return value
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        value = 0; sampledAt = -Double.infinity
    }
}
