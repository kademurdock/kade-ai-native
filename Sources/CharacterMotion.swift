import Foundation

/// Pure, bounded presentation data. Never owns a player, microphone or request.
struct CharacterPose {
    let mouth: Double
    /// Eyelid closure 0...1 from CharacterFaceClock; the closed-eye patch
    /// fades in by this amount.
    var blink: Double
    let tilt: Double
    let lift: Double
    var brow: Double = 0
    /// Panel on the mouth sheet; 0 is closed and lets the face's own mouth show.
    var viseme: Int = 0
    var scale: Double = 1
    /// The expression being dissolved away and how far (0...1) the current
    /// one has replaced it. A blend of 1 shows only the current face.
    var priorFace: CharacterFace = .neutral
    var faceBlend: Double = 1
    static let still = CharacterPose(mouth: 0, blink: 0, tilt: 0, lift: 0)
}

enum CharacterMotion {
    static let kianaID = "agent_6llV0eMu4fmIaj8f2x1Sb"
    static let kianaFile = "agent-agent_6llV0eMu4fmIaj8f2x1Sb-avatar-1789863013865.png"
    static let dellaID = "agent_BSOLa3eNEZyjs-7abCjMt"
    static let dellaFile = "agent-agent_BSOLa3eNEZyjs-7abCjMt-avatar-1788941611099.png"
    /// Sep 25 2026 (Parts 291-292): the moving-faces Lilly everyone can talk
    /// to is the public agent; Skylee's private Lilly wears the same face and
    /// still moves for her. Each id matches only its own portrait file.
    static let lillyID = "agent_TOdYS8v-bRxeNw0dia_Md"
    static let lillyFile = "agent-agent_TOdYS8v-bRxeNw0dia_Md-avatar-1790323412634.png"
    static let skyleeLillyID = "agent_JhouuajXMYsfhCTVMQCv_"
    static let skyleeLillyFile = "agent-agent_JhouuajXMYsfhCTVMQCv_-avatar-1783012583668.png"
    static let harleyID = "agent_d26Mtu8mgOzkVGQECqO1a"
    static let harleyFile = "agent-agent_d26Mtu8mgOzkVGQECqO1a-avatar-1789921519491.png"
    static let witherspoonID = "agent_o7TKU3lK0Euo0MKgpNpvZ"
    static let witherspoonFile = "agent-agent_o7TKU3lK0Euo0MKgpNpvZ-avatar-1790252530815.png"
    static let angelID = "agent_NkG_Fb8_xLz8HFJyx4gNv"
    /// Filled only from the server's uploaded original Angel avatar receipt.
    static let angelFile = "agent-agent_NkG_Fb8_xLz8HFJyx4gNv-avatar-1791586815115.png"
    /// The characters with a full moving face, in the order the picker shows
    /// them. A new rigged character joins the picker's top shelf by joining this.
    static let animatedIDs = [harleyID, lillyID, skyleeLillyID, kianaID, dellaID, witherspoonID, angelID]
    /// Which drawn rig a character wears: Skylee's Lilly uses the public
    /// Lilly's sheets and timing; everyone else is their own.
    static func rigID(_ id: String?) -> String? {
        id == skyleeLillyID ? lillyID : id
    }
    static func blend(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let n = max(0, min(1, value))
        return (n * n * (3 - 2 * n) * 16).rounded() / 16
    }
    static func prepared(id: String?, path: String?) -> Bool {
        guard let path, let url = URL(string: path) else { return false }
        return (id == kianaID && url.lastPathComponent == kianaFile) || (id == dellaID && url.lastPathComponent == dellaFile) || (id == lillyID && url.lastPathComponent == lillyFile) || (id == skyleeLillyID && url.lastPathComponent == skyleeLillyFile) || (id == harleyID && url.lastPathComponent == harleyFile) || (id == witherspoonID && url.lastPathComponent == witherspoonFile) || (id == angelID && !angelFile.isEmpty && url.lastPathComponent == angelFile)
    }
    /// Mouth shapes without phonemes: a spoken clip has no word timings, so the
    /// shape follows how loud the sound is (how open) with a new pick about every
    /// syllable, so the lips keep moving between round, spread and open.
    /// Mouth sheet panels: 0 closed, 1 slightly open, 2 open, 3 round oh, 4 pursed
    /// oo, 5 spread ee, 6 pressed, 7 teeth together, 8 wide open.
    static func viseme(time: Double, strength: Double, seed: UInt32) -> Int {
        guard strength.isFinite, strength > 0.06, time.isFinite, time >= 0 else { return 0 }
        let slot = UInt32(min(4294967295, time.truncatingRemainder(dividingBy: 4294967296 * 0.14) / 0.14))
        var h: UInt32 = ((slot &+ 1) &* 2654435761) ^ seed
        h = (h ^ (h >> 15)) &* 2246822519
        let r = Double(h ^ (h >> 13)) / 4294967296.0
        if strength < 0.25 { return r < 0.6 ? 1 : (r < 0.8 ? 4 : 7) }
        if strength < 0.55 { return r < 0.45 ? 2 : (r < 0.75 ? 5 : 4) }
        return r < 0.4 ? 3 : (r < 0.75 ? 8 : 2)
    }
    /// Wrap each oscillator at its own natural period, before multiplying.
    /// A shared arbitrary time wrap makes unrelated breathing/head loops jump
    /// together after a long conversation. Huge finite clocks still stay safe.
    static func cycle(time: Double, rate: Double, period: Double, offset: Double = 0) -> Double {
        guard rate.isFinite, rate > 0, period.isFinite, period > 0, offset.isFinite else { return 0 }
        let seconds = period / rate
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let clock = time.isFinite && time >= 0 ? time : 0
        return (clock.truncatingRemainder(dividingBy: seconds) * rate + offset)
            .truncatingRemainder(dividingBy: period)
    }
    /// The blink, expression cross-fade and their timing come from the
    /// portrait's CharacterFaceClock sample; without one the eyes stay open.
    static func pose(id: String, time: Double, level: Double, active: Bool,
                     presentation: CharacterPresentation = .idle,
                     performance: CharacterBodyPerformanceSample? = nil,
                     facial: CharacterFaceClock.Sample? = nil) -> CharacterPose {
        guard active, time.isFinite, time >= 0 else { return .still }
        // Stable per-character phase; no synchronized marching portraits.
        let seed = id.utf8.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) }
        let phase = Double(seed % 1000) / 1000
        let holdsOutput = presentation.outputPhase == .queuedGap || presentation.outputPhase == .paused
            || presentation.outputPhase == .stopped
        let mouth = level.isFinite && !holdsOutput ? max(0, min(1, (level - 0.008) * 5)) : 0
        let rig = rigID(id)
        let tempo = rig == dellaID ? 0.72 : (rig == harleyID ? 0.83 : (rig == lillyID ? 1.18 : 1.0))
        // Sway reads the ambient clock, which an activity change or a long
        // reply never restarts (Oct 16 2026); the listening nod keeps the
        // activity's own clock so it still begins from rest.
        let ambient = performance?.ambientElapsed ?? time
        let motionTime = ambient.isFinite && ambient >= 0 ? ambient : time
        let offset = phase * (4.3 + phase * 0.8)
        func oscillation(_ frequency: Double) -> Double {
            sin(cycle(time: motionTime, rate: frequency, period: 2 * .pi, offset: offset * frequency))
        }
        let bodyEnergy = min(1, max(0, performance?.energy ?? mouth))
        var tilt = oscillation(0.3 * tempo) * 0.28 + oscillation(0.7 * tempo) * 0.32
        var lift = oscillation(1.1 * tempo) * (0.18 + bodyEnergy * 0.4)
        func attention(_ activity: CharacterActivity, elapsed: Double) -> (scale: Double, tilt: Double, lift: Double) {
            switch activity {
            case .listening:
                let variant = Double(performance?.attentionVariant ?? 0)
                let period = performance == nil ? 7.3 : 11.2 + variant * 1.8
                let nod = cycle(time: elapsed, rate: 1, period: period, offset: offset)
                let start = performance == nil ? 6.4 : 3.0 + variant * 1.4
                return (1.3, 0, CharacterFigureMotion.pulse(nod, start: start, rise: 0.24, hold: 0.10, fall: 0.72) * 0.75)
            case .thinking: return (1, 0.5 * tempo, 0)
            case .idle, .speaking: return (1, 0, 0)
            }
        }
        let rawBlend = performance?.activityBlend ?? 1
        let blend = rawBlend.isFinite ? min(1, max(0, rawBlend)) : 1
        let previousActivity = performance?.previousActivity ?? presentation.activity
        let now = attention(presentation.activity, elapsed: performance?.activityElapsed ?? time)
        // The activity that just ended hands its sway over across the blend.
        let ended = blend < 1 && previousActivity != presentation.activity
            ? attention(previousActivity, elapsed: performance?.previousActivityElapsed ?? 0) : now
        tilt = tilt * (ended.scale + (now.scale - ended.scale) * blend) + ended.tilt + (now.tilt - ended.tilt) * blend
        lift += ended.lift + (now.lift - ended.lift) * blend
        let gesture = performance.map { CharacterFigureMotion.gestureEnvelope(performance: $0, tempo: tempo) }
            ?? sin(min(max(0, presentation.elapsed.isFinite ? presentation.elapsed : 0), 1) * .pi)
        func authoredPosture(_ expression: CharacterExpression) -> (tilt: Double, lift: Double) {
            switch expression {
            case .amused: return (0, gesture * 0.75)
            case .skeptical: return (gesture * 0.8, 0)
            case .concerned: return (-gesture * 0.5, 0)
            default: return (0, 0)
            }
        }
        let old = authoredPosture(performance?.previousExpression ?? presentation.expression)
        let next = authoredPosture(presentation.expression)
        let mix = min(1, max(0, performance?.expressionBlend ?? 1))
        tilt += old.tilt + (next.tilt - old.tilt) * mix
        lift += old.lift + (next.lift - old.lift) * mix
        let energy = rig == dellaID ? 0.72 : (rig == harleyID ? 0.82 : (rig == lillyID ? 1.15 : 1.0))
        let quiet: Double = [.sad, .tired, .serious, .concerned, .afraid].contains(presentation.expression) ? 0.45 : 1
        let beat = cycle(time: motionTime, rate: tempo, period: 8.6, offset: offset * tempo)
        let nod = beat > 6.7 ? pow(sin((beat - 6.7) / 1.9 * .pi), 2) : 0
        if animatedIDs.contains(id) {
            tilt += (oscillation(tempo * 0.43) * 0.75 + oscillation(tempo * 0.19) * 0.45) * energy * quiet
            lift += (nod * 1.5 + oscillation(tempo * 1.25) * bodyEnergy * 0.65) * energy * quiet
        }
        tilt = max(-2.8, min(2.8, tilt))
        lift = max(-3.2, min(3.2, lift))
        let blink = facial.map { $0.blink.isFinite ? min(1, max(0, $0.blink)) : 0 } ?? 0
        let faceBlend = facial.map { $0.faceBlend.isFinite ? min(1, max(0, $0.faceBlend)) : 1 } ?? 1
        return CharacterPose(mouth: mouth, blink: blink, tilt: tilt, lift: lift,
            brow: presentation.expression == .neutral ? bodyEnergy * (0.35 + 0.25 * oscillation(0.65 * tempo)) + max(0, oscillation(0.43 * tempo)) * 0.12 * (1 - bodyEnergy) : 0,
            viseme: viseme(time: time, strength: mouth, seed: seed),
            scale: animatedIDs.contains(id) ? 1.012 + oscillation(tempo * 0.85) * 0.004 + bodyEnergy * 0.012 * quiet : 1,
            priorFace: facial?.priorFace ?? .neutral, faceBlend: faceBlend)
    }
}

/// Per-portrait facial timing on the portrait's own timeline (Oct 16 2026;
/// Kade's sister saw eyes snap shut for one frame on an otherwise still face).
/// A blink is a real eyelid movement: about 70 ms closing, 40 ms closed and
/// 110 ms opening, drawn as a fade of the authored closed-eye patch. Gaps are
/// irregular and seeded per character (1.1 to 11 s, mean about 4.2 s, 16%
/// doubles), and an expression change or a larger glance brings one forward.
/// A new expression cross-fades in over 0.2 s instead of snapping. Times are
/// the timeline's clock; call only from the portrait's main-thread timeline
/// and its frame schedule, like CharacterBodyPerformanceClock.
final class CharacterFaceClock {
    struct Sample: Equatable {
        var blink: Double = 0
        var face: CharacterFace = .neutral
        var priorFace: CharacterFace = .neutral
        var faceBlend: Double = 1
        static let still = Sample()
    }

    static let closing = 0.07
    static let closedHold = 0.04
    static let opening = 0.11
    static let blinkDuration = closing + closedHold + opening
    /// Faster frames begin this long before a blink: longer than the slowest
    /// resting frame interval (1/8 s), so the closing is never skipped.
    static let frameLead = 0.14
    static let frameTail = 0.04
    static let crossFade = 0.2
    static let shortestGap = 1.1
    static let longestGap = 11.0
    static let doubleBlinkChance = 0.16
    /// Scale of the exponential part of each gap; truncated to the range
    /// above, the mean gap is about 4.2 s.
    static let gapScale = 4.0
    /// An extra blink is skipped when another starts this close to it.
    static let crowding = 0.6

    private var identity: String?
    private var random: UInt64 = 0
    private var lastTime: Double?
    private var starts: [Double] = []
    private var face: CharacterFace?
    private var priorFace = CharacterFace.neutral
    private var faceChangedAt = -Double.infinity
    private var glancing = false

    func reset() {
        identity = nil
        random = 0
        lastTime = nil
        starts = []
        face = nil
        priorFace = .neutral
        faceChangedAt = -Double.infinity
        glancing = false
    }

    /// Eyelid closure for a blink that started `elapsed` seconds ago: an
    /// eased close, a brief hold, then a slightly slower eased opening.
    static func amount(sinceStart elapsed: Double) -> Double {
        guard elapsed.isFinite, elapsed > 0, elapsed < blinkDuration else { return 0 }
        func smooth(_ value: Double) -> Double {
            let value = min(1, max(0, value))
            return value * value * (3 - 2 * value)
        }
        if elapsed < closing { return smooth(elapsed / closing) }
        if elapsed < closing + closedHold { return 1 }
        return 1 - smooth((elapsed - closing - closedHold) / opening)
    }

    /// A shifted, truncated exponential: `unit` 0...1 maps to 1.1...11 s.
    static func gap(_ unit: Double) -> Double {
        let u = unit.isFinite ? min(1, max(0, unit)) : 0.5
        let tail = 1 - exp(-(longestGap - shortestGap) / gapScale)
        return min(longestGap, shortestGap - gapScale * log(1 - u * tail))
    }

    private func nextUnit() -> Double {
        random &+= 0x9E3779B97F4A7C15
        var z = random
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / 9007199254740992.0
    }

    /// Queue the next ordinary blink (sometimes a double) after `time`.
    private func scheduleBlink(after time: Double, first: Bool = false) {
        let start = time + (first ? 0.6 + 2.4 * nextUnit() : Self.gap(nextUnit()))
        starts.append(start)
        if nextUnit() < Self.doubleBlinkChance {
            starts.append(start + Self.blinkDuration + 0.08 + 0.06 * nextUnit())
        }
    }

    /// An expression change or a larger glance: blink just after it, unless
    /// one is already under way or about to start. Later blinks move back.
    private func bringBlinkForward(at time: Double) {
        let start = time + Self.frameLead
        if starts.contains(where: { abs($0 - start) < Self.crowding }) { return }
        let later = starts.filter { $0 > start }
        let shift = later.first.map { max(0, start + Self.shortestGap - $0) } ?? 0
        starts = starts.filter { $0 < start } + [start] + later.map { $0 + shift }
    }

    func sample(identity current: String, time: Double, face shown: CharacterFace,
                glance: Double, active: Bool) -> Sample {
        guard active, time.isFinite, time >= 0 else {
            reset()
            return .still
        }
        if identity != current || lastTime.map({ time < $0 }) == true {
            reset()
            identity = current
            let rig = CharacterMotion.rigID(String(current.split(separator: "|", maxSplits: 1).first ?? "")) ?? current
            random = UInt64(rig.utf8.reduce(UInt32(5381)) { ($0 &* 33) &+ UInt32($1) }) &* 0x2545F4914F6CDD1D
            scheduleBlink(after: time, first: true)
        }
        lastTime = time
        // Forget finished blinks; always keep the next ordinary one queued so
        // the frame schedule can see it coming.
        starts.removeAll { $0 + Self.blinkDuration < time - 1 }
        if let last = starts.last, last <= time { scheduleBlink(after: time) }
        if starts.isEmpty { scheduleBlink(after: time) }

        if let previous = face, previous != shown {
            // Keep whichever face is mostly visible beneath the new one.
            priorFace = faceBlend(at: time) >= 0.5 ? previous : priorFace
            faceChangedAt = time
            bringBlinkForward(at: time)
        }
        face = shown
        let turn = glance.isFinite ? abs(glance) : 0
        if !glancing, turn >= 0.5 {
            glancing = true
            bringBlinkForward(at: time)
        } else if glancing, turn < 0.3 {
            glancing = false
        }
        let blink = starts.map { Self.amount(sinceStart: time - $0) }.max() ?? 0
        return Sample(blink: blink, face: shown, priorFace: priorFace, faceBlend: faceBlend(at: time))
    }

    private func faceBlend(at time: Double) -> Double {
        let p = min(1, max(0, (time - faceChangedAt) / Self.crossFade))
        return p * p * (3 - 2 * p)
    }

    /// True while a blink is close enough that its frames must be sampled
    /// at the faster blink rate (CharacterAnimationBudget).
    func wantsBlinkFrames(at time: Double) -> Bool {
        guard time.isFinite else { return false }
        return starts.contains { time >= $0 - Self.frameLead && time <= $0 + Self.blinkDuration + Self.frameTail }
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
