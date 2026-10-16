import Foundation

/// Oct 16 2026: the puppet motion engine, a line-for-line port of the web's
/// motion.mjs. It turns time, speech and expression into the 25 channel values a
/// puppet scene is driven by. Deterministic for a seed and the same sequence of
/// update() calls, frame-rate independent, no timers of its own. Any change here
/// must land in motion.mjs too, and both must keep matching motion-golden.json.
///
/// Layers, summed each frame:
///   idle     breathing, slow head drift, glances (saccade + fixation), coupled blinks,
///            occasional micro-expressions
///   speech   jaw from the audio level, shape changes per syllable, emphasis nods and
///            brow lifts, more eye contact
///   listen   attentive nods and a soft smile while the person is talking
///   emotion  eased channel targets for the current expression
///   physics  hair follow-through, wing flap, halo float
final class PuppetMotion {
    struct Options {
        var energy = "steady"
        var expressiveness = 0.6
        var blink = "normal"
        var baseSmile = 0.12
        /// A painted face (living paintings) draws each expression from its
        /// own painted panel, so the expression no longer pushes the facial
        /// channels; head, gaze, body and every moving layer stay.
        var artFace = false
    }

    /// The channels a painted expression panel already shows.
    static let paintedChannels: Set<PuppetChannel> = [
        .eyeBlink, .eyeSquint, .eyeWide, .browRaise, .browFurrow, .browSad, .browAsym,
        .mouthOpen, .mouthWide, .mouthRound, .mouthSmile, .mouthPress, .cheekRaise, .cheekBlush,
    ]
    struct Input {
        var speaking = false
        /// 0...1, already shaped like the mouth level (see `voiceLevel`).
        var level = 0.0
        var listening = false
        var reduceMotion = false
        var look: (Double, Double)? = nil
    }

    /// Channel targets per expression. Values are offsets from neutral.
    static let expressions: [String: [(PuppetChannel, Double)]] = [
        "neutral": [],
        "happy": [(.mouthSmile, 0.7), (.cheekRaise, 0.6), (.eyeSquint, 0.25), (.browRaise, 0.15)],
        "joyful": [(.mouthSmile, 1), (.mouthOpen, 0.35), (.cheekRaise, 1), (.eyeSquint, 0.55), (.browRaise, 0.3), (.headPitch, -0.15)],
        "laughing": [(.mouthSmile, 1), (.mouthOpen, 0.6), (.cheekRaise, 1), (.eyeSquint, 0.75), (.browRaise, 0.35), (.headRoll, 0.25), (.headPitch, -0.25)],
        "warm": [(.mouthSmile, 0.45), (.eyeSquint, 0.2), (.headRoll, 0.18), (.browSad, 0.12)],
        "excited": [(.mouthSmile, 0.8), (.mouthOpen, 0.3), (.eyeWide, 0.6), (.browRaise, 0.7), (.cheekRaise, 0.6)],
        "surprised": [(.browRaise, 1), (.eyeWide, 1), (.mouthOpen, 0.5), (.mouthRound, 0.6), (.headPitch, -0.2)],
        "curious": [(.browAsym, 0.7), (.headRoll, 0.35), (.mouthSmile, 0.15), (.eyeWide, 0.2)],
        "thinking": [(.browAsym, 0.4), (.mouthPress, 0.35), (.headRoll, -0.2), (.gazeX, -0.55), (.gazeY, -0.55)],
        "confused": [(.browFurrow, 0.35), (.browAsym, 0.55), (.mouthSmile, -0.2), (.headRoll, 0.3)],
        "skeptical": [(.browAsym, 0.9), (.mouthSmile, 0.25), (.eyeSquint, 0.35), (.mouthPress, 0.2)],
        "sad": [(.browSad, 1), (.mouthSmile, -0.7), (.gazeY, 0.45), (.headPitch, 0.35), (.eyeSquint, 0.1)],
        "worried": [(.browSad, 0.75), (.mouthPress, 0.4), (.mouthSmile, -0.25), (.eyeWide, 0.25)],
        "scared": [(.browSad, 0.5), (.browRaise, 0.6), (.eyeWide, 0.95), (.mouthOpen, 0.25), (.mouthWide, 0.3), (.bodyShrug, 0.4)],
        "angry": [(.browFurrow, 1), (.mouthPress, 0.6), (.mouthSmile, -0.45), (.eyeSquint, 0.35), (.headPitch, 0.15)],
        "annoyed": [(.browFurrow, 0.5), (.mouthPress, 0.45), (.mouthSmile, -0.2), (.gazeX, 0.45), (.eyeSquint, 0.2)],
        "disgusted": [(.browFurrow, 0.6), (.mouthSmile, -0.55), (.eyeSquint, 0.5), (.mouthWide, 0.3), (.headRoll, -0.15), (.headPitch, -0.1)],
        "embarrassed": [(.mouthSmile, 0.4), (.gazeY, 0.5), (.gazeX, 0.4), (.headPitch, 0.3), (.cheekBlush, 1), (.bodyShrug, 0.3)],
        "proud": [(.mouthSmile, 0.5), (.headPitch, -0.3), (.eyeSquint, 0.2), (.browRaise, 0.1)],
        "sleepy": [(.eyeBlink, 0.45), (.browRaise, -0.3), (.headPitch, 0.2), (.mouthPress, 0.1)],
        "playful": [(.mouthSmile, 0.6), (.headRoll, 0.25), (.browAsym, 0.4), (.eyeSquint, 0.2)],
        "affectionate": [(.mouthSmile, 0.55), (.eyeSquint, 0.3), (.headRoll, 0.3), (.browSad, 0.15), (.cheekBlush, 0.5)],
        "determined": [(.browFurrow, 0.35), (.mouthPress, 0.5), (.headPitch, 0.1)],
        "calm": [(.mouthSmile, 0.2), (.eyeSquint, 0.12)],
        "whisper": [(.mouthPress, 0.25), (.headPitch, 0.15), (.gazeX, 0.3), (.headRoll, -0.12)],
    ]

    private struct Energy {
        let breath: Double
        let drift: Double
        let glance: Double
        let nod: Double
    }
    private static let energies: [String: Energy] = [
        "calm": Energy(breath: 4.6, drift: 0.7, glance: 1.35, nod: 0.7),
        "steady": Energy(breath: 3.9, drift: 1, glance: 1, nod: 1),
        "lively": Energy(breath: 3.3, drift: 1.35, glance: 0.75, nod: 1.35),
    ]
    private static let blinkMeans: [String: Double] = ["normal": 4.2, "slow": 5.6, "quick": 2.8]

    /// The web's mulberry-style generator, on UInt32 wrapping arithmetic so it
    /// matches Math.imul and >>> exactly.
    private struct Random {
        var a: UInt32
        init(seed: UInt32) { a = 0x9e37_79b9 ^ seed }
        mutating func next() -> Double {
            a = a &+ 0x6d2b_79f5
            var t = (a ^ (a >> 15)) &* (1 | a)
            t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }
    }

    /// FNV-1a over UTF-16 code units, like hashSeed() on the web.
    static func hashSeed(_ text: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for scalar in text.unicodeScalars {
            let unit = scalar.value <= 0xffff ? scalar.value : 0xd800 + ((scalar.value - 0x10000) >> 10)
            h = (h ^ unit) &* 16_777_619
        }
        return h
    }

    /// Smooth deterministic noise in [-1, 1]: three detuned sines.
    private struct Noise {
        let f0: Double, f1: Double, f2: Double
        let p0: Double, p1: Double, p2: Double
        init(_ r: () -> Double) {
            f0 = 0.07 + r() * 0.05
            f1 = 0.13 + r() * 0.07
            f2 = 0.29 + r() * 0.1
            p0 = r() * 6.28
            p1 = r() * 6.28
            p2 = r() * 6.28
        }
        func value(_ t: Double) -> Double {
            sin(t * f0 * 6.283 + p0) * 0.55 + sin(t * f1 * 6.283 + p1) * 0.3 + sin(t * f2 * 6.283 + p2) * 0.15
        }
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v < lo ? lo : v > hi ? hi : v }
    private static func approach(_ cur: Double, _ target: Double, _ dt: Double, _ tau: Double) -> Double {
        cur + (target - cur) * (1 - exp(-dt / max(1e-3, tau)))
    }
    /// V8's Math.hypot for two numbers (scaled Kahan sum), not libm's.
    private static func hypot2(_ x: Double, _ y: Double) -> Double {
        let ax = abs(x), ay = abs(y)
        let biggest = max(ax, ay)
        if biggest.isInfinite { return .infinity }
        if biggest == 0 { return 0 }
        var sum = 0.0, compensation = 0.0
        for value in [ax, ay] {
            let n = value / biggest
            let summand = n * n - compensation
            let preliminary = sum + summand
            compensation = (preliminary - sum) - summand
            sum = preliminary
        }
        return sqrt(sum) * biggest
    }

    private let seed: Double
    private var random: Random
    private let energy: Energy
    private let expressiveness: Double
    private let blinkMean: Double
    private let baseSmile: Double
    private let artFace: Bool
    private let nYaw: Noise, nPitch: Noise, nRoll: Noise, nSmile: Noise, nBrow: Noise

    private var t = 0.0
    private var breath: Double
    private var gaze = (0.0, 0.0), gazeFrom = (0.0, 0.0), gazeTo = (0.0, 0.0)
    private var sacT = 1.0, sacDur = 0.07, fixUntil: Double
    private var blinkAt: Double, blinkT = -1.0, blinkDouble = false
    private var headFollow = (0.0, 0.0)
    private var emo = [Double](repeating: 0, count: PuppetChannel.count)
    private var emoTarget = [Double](repeating: 0, count: PuppetChannel.count)
    private var emoUntil = 0.0
    private var level = 0.0, prevLevel = 0.0, onsetCooldown = 0.0
    private var shape = [0.0, 0.0, 0.0], shapeTarget = [0.0, 0.0, 0.0]
    private var nod = 0.0, nodV = 0.0, browLift = 0.0
    private var nodAt: Double
    private var hair = 0.0, hairV = 0.0, prevYaw = 0.0, prevRoll = 0.0
    private var micro = 0.0, microAt: Double, microKind = 0
    private var winkAt: Double?
    private var out = [Double](repeating: 0, count: PuppetChannel.count)

    init(seed: UInt32 = 1, options: Options = Options()) {
        self.seed = Double(seed)
        var random = Random(seed: seed)
        func r() -> Double { random.next() }
        energy = PuppetMotion.energies[options.energy] ?? PuppetMotion.energies["steady"]!
        expressiveness = PuppetMotion.clamp(options.expressiveness, 0, 1)
        blinkMean = PuppetMotion.blinkMeans[options.blink] ?? 4.2
        baseSmile = options.baseSmile
        artFace = options.artFace
        nYaw = Noise(r)
        nPitch = Noise(r)
        nRoll = Noise(r)
        nSmile = Noise(r)
        nBrow = Noise(r)
        breath = r()
        fixUntil = 0.6 + r()
        blinkAt = 1 + r() * 2
        nodAt = 2 + r() * 3
        microAt = 4 + r() * 6
        self.random = random
    }

    private func r() -> Double { random.next() }

    private func scheduleBlink(_ now: Double) {
        let u = max(1e-4, r())
        blinkAt = now + Self.clamp(-log(u) * blinkMean, 1.1, blinkMean * 2.6)
    }

    private func startSaccade(_ target: (Double, Double), _ now: Double) {
        let dist = Self.hypot2(target.0 - gaze.0, target.1 - gaze.1)
        gazeFrom = gaze
        gazeTo = target
        sacT = 0
        sacDur = 0.045 + dist * 0.06
        // people often blink with a big gaze shift
        if dist > 0.45 && blinkT < 0 && r() < 0.6 { blinkAt = now + 0.02 }
        // and the brows sometimes lift a little with a fresh glance
        if dist > 0.5 && r() < 0.3 { browLift = 0.18 * (0.5 + expressiveness) }
    }

    func setExpression(_ name: String, strength: Double = 1, holdSeconds: Double = 4) {
        let e = Self.expressions[name] ?? []
        let k = Self.clamp(strength, 0, 1.2) * (0.55 + 0.6 * expressiveness)
        emoTarget = [Double](repeating: 0, count: PuppetChannel.count)
        for (c, v) in e where !(artFace && Self.paintedChannels.contains(c)) { emoTarget[c.rawValue] = v * k }
        emoUntil = t + holdSeconds
        if name == "playful" { winkAt = t + 0.25 }
    }

    /// dt in seconds. Returns all 25 channels, indexed by `PuppetChannel`.
    func update(dt rawDt: Double, input: Input = Input()) -> [Double] {
        let dt = Self.clamp(rawDt, 0, 0.1)
        self.t += dt
        let t = self.t
        let reduce = input.reduceMotion
        let speaking = input.speaking
        func E(_ c: PuppetChannel) -> Double { emo[c.rawValue] }

        // ---- breathing (inhale 40%, exhale 60%)
        breath = (breath + dt / energy.breath).truncatingRemainder(dividingBy: 1)
        let ph = breath
        let breathWave = ph < 0.4 ? sin((ph / 0.4) * Double.pi * 0.5) : cos(((ph - 0.4) / 0.6) * Double.pi * 0.5)
        out[PuppetChannel.bodyBreath.rawValue] = reduce ? 0 : breathWave * 2 - 1

        // ---- gaze: fixations and saccades
        if t >= fixUntil && sacT >= 1 {
            let target: (Double, Double)
            if let look = input.look { target = look }
            else if speaking { target = r() < 0.7 ? ((r() - 0.5) * 0.25, (r() - 0.5) * 0.15) : ((r() - 0.5) * 1.3, (r() - 0.6) * 0.8) }
            else if input.listening { target = ((r() - 0.5) * 0.2, (r() - 0.4) * 0.15) }
            else { target = r() < 0.45 ? ((r() - 0.5) * 0.3, (r() - 0.5) * 0.2) : ((r() - 0.5) * 1.5, (r() - 0.5) * 0.9) }
            startSaccade(target, t)
            fixUntil = t + (0.5 + r() * 2.6) * energy.glance * (speaking ? 1.3 : 1)
        }
        if sacT < 1 {
            sacT = min(1, sacT + dt / sacDur)
            let e = 1 - pow(1 - sacT, 3)
            gaze = (gazeFrom.0 + (gazeTo.0 - gazeFrom.0) * e, gazeFrom.1 + (gazeTo.1 - gazeFrom.1) * e)
        }
        // micro-saccade jitter during fixations
        let jitter = reduce ? 0 : 0.015
        let gx = gaze.0 + sin(t * 13.1 + seed) * jitter
        let gy = gaze.1 + sin(t * 11.3 + seed * 0.7) * jitter

        // ---- head: drift + follows the eyes + nods
        headFollow.0 = Self.approach(headFollow.0, gaze.0 * 0.38, dt, 0.42)
        headFollow.1 = Self.approach(headFollow.1, gaze.1 * 0.3, dt, 0.5)
        let d = reduce ? 0 : energy.drift
        let yaw = nYaw.value(t) * 0.11 * d + headFollow.0
        var pitch = nPitch.value(t) * 0.06 * d + headFollow.1
        let roll = nRoll.value(t) * 0.07 * d

        // ---- speech
        let inputLevel = Self.clamp(input.level.isNaN ? 0 : input.level, 0, 1)
        level = Self.approach(level, speaking ? inputLevel : 0, dt, inputLevel > level ? 0.035 : 0.085)
        onsetCooldown -= dt
        if speaking && level - prevLevel > 0.06 && onsetCooldown <= 0 && level > 0.18 {
            // a syllable onset: pick a new mouth shape, sometimes nod and lift the brows
            onsetCooldown = 0.11
            let pick = r()
            shapeTarget = pick < 0.3 ? [0.7, 0, 0] : pick < 0.52 ? [0, 0.75, 0] : pick < 0.66 ? [0, 0, 0.6] : [0.2, 0.2, 0]
            if r() < 0.35 * energy.nod && !reduce { nodV += 2.2 * (0.6 + expressiveness * 0.6) }
            if r() < 0.25 { browLift = max(browLift, 0.3 * expressiveness + 0.08) }
        }
        prevLevel = level
        if !speaking { shapeTarget = [0, 0, 0] }
        for i in 0..<3 { shape[i] = Self.approach(shape[i], shapeTarget[i], dt, 0.06) }
        // nod spring (pitch down then back)
        nodV += (-nod * 60 - nodV * 9) * dt
        nod += nodV * dt
        pitch += nod * 0.12

        // ---- listening nods
        if input.listening && !speaking && t >= nodAt && !reduce {
            nodV += 1.6
            nodAt = t + 2.5 + r() * 3.5
        }

        // ---- blinks
        if blinkT < 0 && t >= blinkAt { blinkT = 0 }
        var blink = 0.0
        if blinkT >= 0 {
            blinkT += dt
            let b = blinkT
            blink = b < 0.07 ? b / 0.07 : b < 0.11 ? 1 : b < 0.22 ? 1 - (b - 0.11) / 0.11 : 0
            pitch += blink * 0.025 // the head dips a hair with a blink
            if b >= 0.22 {
                blinkT = -1
                if !blinkDouble && r() < 0.16 {
                    blinkDouble = true
                    blinkAt = t + 0.09
                } else {
                    blinkDouble = false
                    scheduleBlink(t)
                }
            }
        }

        // ---- micro-expressions while idle: a small smile flicker, a lip press, a brow twitch
        if !speaking && t >= microAt && !reduce {
            microKind = 1 + Int(floor(r() * 3))
            micro = 0
            microAt = t + 5 + r() * 9
        }
        var microSmile = 0.0
        var microPress = 0.0
        var microBrow = 0.0
        if microKind != 0 {
            micro += dt
            let env = sin(min(1, micro / 1.4) * Double.pi)
            if microKind == 1 { microSmile = 0.22 * env }
            else if microKind == 2 { microPress = 0.3 * env }
            else { microBrow = 0.16 * env }
            if micro >= 1.4 { microKind = 0 }
        }

        // ---- emotion easing
        if t > emoUntil { emoTarget = [Double](repeating: 0, count: PuppetChannel.count) }
        for c in 0..<PuppetChannel.count {
            let target = emoTarget[c]
            emo[c] = Self.approach(emo[c], target, dt, target != 0 ? 0.22 : 0.6)
        }
        browLift = Self.approach(browLift, 0, dt, 0.35)

        // ---- compose
        func set(_ c: PuppetChannel, _ value: Double) { out[c.rawValue] = value }
        set(.headYaw, Self.clamp(yaw + E(.headYaw), -1, 1))
        set(.headPitch, Self.clamp(pitch + E(.headPitch), -1, 1))
        set(.headRoll, Self.clamp(roll + E(.headRoll), -1, 1))
        set(.bodyShrug, Self.clamp(E(.bodyShrug), 0, 1))
        set(.gazeX, Self.clamp(gx + E(.gazeX), -1, 1))
        set(.gazeY, Self.clamp(gy + E(.gazeY), -1, 1))
        set(.eyeBlink, Self.clamp(max(blink, E(.eyeBlink)), 0, 1))
        var wink = 0.0
        if let winkAt {
            let w = t - winkAt
            if w >= 0 && w < 0.45 { wink = w < 0.1 ? w / 0.1 : w < 0.3 ? 1 : 1 - (w - 0.3) / 0.15 }
            if w >= 0.45 { self.winkAt = nil }
        }
        set(.eyeWink, wink)
        set(.eyeSquint, Self.clamp(E(.eyeSquint) + level * 0.08, 0, 1))
        set(.eyeWide, Self.clamp(E(.eyeWide), 0, 1))
        set(.browRaise, Self.clamp(E(.browRaise) + browLift + microBrow + nBrow.value(t) * 0.03, -1, 1))
        set(.browFurrow, Self.clamp(E(.browFurrow), 0, 1))
        set(.browSad, Self.clamp(E(.browSad), 0, 1))
        set(.browAsym, Self.clamp(E(.browAsym), 0, 1))
        let jaw = pow(level, 0.75) * 0.95
        set(.mouthOpen, Self.clamp(jaw * (1 - shape[2] * 0.5) + E(.mouthOpen) * (speaking ? 0.4 : 1), 0, 1))
        set(.mouthWide, Self.clamp(shape[0] * jaw * 1.2 + E(.mouthWide), 0, 1))
        set(.mouthRound, Self.clamp(shape[1] * min(1, jaw * 1.6) + E(.mouthRound), 0, 1))
        set(.mouthPress, Self.clamp(shape[2] * 0.6 + E(.mouthPress) + microPress, 0, 1))
        set(.mouthSmile, Self.clamp(baseSmile + nSmile.value(t) * 0.04 + E(.mouthSmile) + microSmile + (input.listening ? 0.12 : 0), -1, 1))
        set(.cheekRaise, Self.clamp(E(.cheekRaise) + max(0, out[PuppetChannel.mouthSmile.rawValue] - 0.4) * 0.6, 0, 1))
        set(.cheekBlush, Self.clamp(E(.cheekBlush), 0, 1))

        // ---- physics: hair follows head motion with lag
        let headYaw = out[PuppetChannel.headYaw.rawValue]
        let headRoll = out[PuppetChannel.headRoll.rawValue]
        let vYaw = (headYaw - prevYaw) / max(dt, 1e-3)
        let vRoll = (headRoll - prevRoll) / max(dt, 1e-3)
        prevYaw = headYaw
        prevRoll = headRoll
        if !reduce {
            hairV += (-hair * 38 - hairV * 5.5 - (vYaw * 0.9 + vRoll * 1.4) * 9) * dt
            hair = Self.clamp(hair + hairV * dt, -1, 1)
        } else { hair = 0 }
        set(.hairSwing, hair + (reduce ? 0 : headRoll * 0.5))
        set(.extrasFlap, reduce ? 0 : sin(t * 1.4) * 0.5 + 0.5 * sin(t * 0.37))
        set(.extrasFloat, reduce ? 0 : sin(t * 0.9))
        return out
    }
}

extension PuppetMotion {
    /// The pose a still puppet holds: the expression at full ease with no breath,
    /// drift, glance, blink or speech. Used for Reduce Motion, paused stages and
    /// still faces in lists. The same composition as update() with every moving
    /// layer at rest.
    static func stillChannels(expression: String, options: Options, listening: Bool = false) -> [Double] {
        let k = 0.55 + 0.6 * clamp(options.expressiveness, 0, 1)
        var e = [Double](repeating: 0, count: PuppetChannel.count)
        for (c, v) in expressions[expression] ?? [] where !(options.artFace && paintedChannels.contains(c)) {
            e[c.rawValue] = v * k
        }
        func E(_ c: PuppetChannel) -> Double { e[c.rawValue] }
        var out = [Double](repeating: 0, count: PuppetChannel.count)
        func set(_ c: PuppetChannel, _ value: Double) { out[c.rawValue] = value }
        set(.headYaw, clamp(E(.headYaw), -1, 1))
        set(.headPitch, clamp(E(.headPitch), -1, 1))
        set(.headRoll, clamp(E(.headRoll), -1, 1))
        set(.bodyShrug, clamp(E(.bodyShrug), 0, 1))
        set(.gazeX, clamp(E(.gazeX), -1, 1))
        set(.gazeY, clamp(E(.gazeY), -1, 1))
        set(.eyeBlink, clamp(E(.eyeBlink), 0, 1))
        set(.eyeSquint, clamp(E(.eyeSquint), 0, 1))
        set(.eyeWide, clamp(E(.eyeWide), 0, 1))
        set(.browRaise, clamp(E(.browRaise), -1, 1))
        set(.browFurrow, clamp(E(.browFurrow), 0, 1))
        set(.browSad, clamp(E(.browSad), 0, 1))
        set(.browAsym, clamp(E(.browAsym), 0, 1))
        set(.mouthOpen, clamp(E(.mouthOpen), 0, 1))
        set(.mouthWide, clamp(E(.mouthWide), 0, 1))
        set(.mouthRound, clamp(E(.mouthRound), 0, 1))
        set(.mouthPress, clamp(E(.mouthPress), 0, 1))
        set(.mouthSmile, clamp(options.baseSmile + E(.mouthSmile) + (listening ? 0.12 : 0), -1, 1))
        set(.cheekRaise, clamp(E(.cheekRaise) + max(0, out[PuppetChannel.mouthSmile.rawValue] - 0.4) * 0.6, 0, 1))
        set(.cheekBlush, clamp(E(.cheekBlush), 0, 1))
        return out
    }

    /// The app's 22 delivery expressions in the engine's vocabulary. A laugh
    /// moment is its own face; a neutral reply being thought about looks away
    /// to think, like the painted faces' thoughtful panel.
    static func expressionName(_ expression: CharacterExpression) -> String {
        switch expression {
        case .neutral: return "neutral"
        case .warm: return "warm"
        case .amused: return "happy"
        case .serious: return "determined"
        case .concerned: return "worried"
        case .skeptical: return "skeptical"
        case .surprised: return "surprised"
        case .tender: return "affectionate"
        case .calm: return "calm"
        case .confident: return "proud"
        case .playful: return "playful"
        case .excited: return "excited"
        case .smug: return "proud"
        case .curious: return "curious"
        case .thoughtful: return "thinking"
        case .dry: return "skeptical"
        case .frustrated: return "annoyed"
        case .angry: return "angry"
        case .disgusted: return "disgusted"
        case .afraid: return "scared"
        case .sad: return "sad"
        case .tired: return "sleepy"
        }
    }

    static func expressionName(for presentation: CharacterPresentation) -> String {
        if presentation.laughing { return "laughing" }
        if presentation.expression == .neutral && presentation.activity == .thinking { return "thinking" }
        return expressionName(presentation.expression)
    }

    /// A laugh is a short moment; a delivery direction holds until the next one.
    static func holdSeconds(for name: String) -> Double { name == "laughing" ? 0.8 : 1e9 }

    /// The same mouth level the painted faces use: the raw output level,
    /// lifted off its noise floor and scaled into 0...1.
    static func voiceLevel(_ raw: Double) -> Double {
        raw.isFinite ? clamp((raw - 0.008) * 5, 0, 1) : 0
    }
}

/// Vector puppets redraw cheaply, so they get smoother clocks than the painted
/// sheets, and the same rule: no ticking clock when motion is paused, none at
/// serious thermal pressure.
struct PuppetFrameBudget {
    let active: Bool
    let activity: CharacterActivity
    var thermal: CharacterThermalPressure = .nominal

    var framesPerSecond: Double {
        guard active, thermal.permitsAnimation else { return 0 }
        switch (activity, thermal) {
        case (.speaking, .nominal): return 30
        case (.speaking, .fair): return 20
        case (.listening, .nominal), (.thinking, .nominal): return 24
        case (.listening, .fair), (.thinking, .fair): return 15
        case (.idle, .nominal): return 20
        case (.idle, .fair): return 12
        default: return 0
        }
    }

    var paused: Bool { framesPerSecond == 0 }

    /// TimelineView still needs a finite interval while its clock is paused.
    var minimumInterval: TimeInterval {
        let rate = framesPerSecond
        return rate > 0 ? 1 / rate : 1
    }

    /// Same sampling rule as the portrait: a held or finished voice rests.
    static func activity(_ offered: CharacterPresentation, playing: Bool) -> CharacterActivity {
        if offered.outputPhase == .paused || offered.outputPhase == .queuedGap
            || offered.outputPhase == .stopped && offered.activity == .speaking { return .idle }
        return playing ? .speaking : offered.activity
    }
}
