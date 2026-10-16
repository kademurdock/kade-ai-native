import Foundation

/// Oct 16 2026 (Kade's sister: the large faces blinked while everything else
/// stayed frozen). These checks measure resting life in points and degrees on
/// the 208 pt stage, through the same clock and limits every renderer uses,
/// rather than only checking that values change.
func runCharacterRestingLifeChecks(_ check: (Bool, String) -> Void) {
    let side = 208.0
    let people: [(String, String)] = [
        (CharacterMotion.harleyID, CharacterMotion.harleyFile),
        (CharacterMotion.kianaID, CharacterMotion.kianaFile),
        (CharacterMotion.lillyID, CharacterMotion.lillyFile),
        (CharacterMotion.skyleeLillyID, CharacterMotion.skyleeLillyFile),
        (CharacterMotion.dellaID, CharacterMotion.dellaFile),
        (CharacterMotion.witherspoonID, CharacterMotion.witherspoonFile),
        (CharacterMotion.angelID, CharacterMotion.angelFile)]
    // Tight crops (Kiana, Witherspoon) turn less; every other head at least
    // 0.8 degrees from side to side within a resting minute.
    func turnFloor(_ id: String) -> Double {
        id == CharacterMotion.kianaID || id == CharacterMotion.witherspoonID ? 0.6 : 0.8
    }
    struct Track {
        var head: [Double] = []
        var vertical: [Double] = []
        var breath: [Double] = []
        mutating func add(head: Double, vertical: Double, breath: Double) {
            self.head.append(head); self.vertical.append(vertical); self.breath.append(breath)
        }
    }
    func span(_ values: [Double]) -> Double { (values.max() ?? 0) - (values.min() ?? 0) }

    for (id, file) in people {
        let path = "/images/" + file
        let limits: CharacterBustMotionLimits
        let unit: Double
        if id == CharacterMotion.angelID {
            limits = CharacterAngelVectorArt.motionLimits
            unit = side / 1024
        } else {
            let artwork = CharacterBustArtwork.approved(stage: true, side: side, agentID: id, avatarPath: path)!
            limits = artwork.motionLimits
            unit = side / artwork.cropSide
        }
        let tall = CharacterConversationBodyArtwork.approved(stage: true, side: side, agentID: id, avatarPath: path)
        for activity in [CharacterActivity.idle, .listening, .thinking] {
            let clock = CharacterBodyPerformanceClock()
            let state = CharacterPresentation(activity: activity)
            var bust = Track(), body = Track()
            var breaths = [Double]()
            var previousBreath = 0.0
            var glances = 0
            var glancing = false
            for frame in 0...(120 * 12) {
                let time = Double(frame) / 12
                let sample = clock.sample(identity: id + "|" + path, time: time, level: 0, active: true, presentation: state)
                let figure = CharacterFigureMotion.pose(id: id, time: time, level: 0, active: true,
                    presentation: state, performance: sample)
                guard time >= 60 else { continue }
                // Square bust, Della's articulated body and Angel share these limits.
                let motion = CharacterBustMotion.pose(figure, limits: limits)
                bust.add(head: motion.headAngle, vertical: (motion.headOffsetY + motion.breathOffsetY) * unit,
                    breath: -motion.breathOffsetY * unit)
                if let tall {
                    let pose = CharacterConversationBodyGeometry.pose(artwork: tall, active: true,
                        presentation: state, figurePose: figure, elapsed: 0, outputLevel: 0, performance: sample)
                    body.add(head: pose.headDegrees, vertical: (pose.headLift - pose.breathLift) * side,
                        breath: pose.breathLift * side)
                }
                if previousBreath < 0.5 && figure.breath >= 0.5 { breaths.append(time) }
                previousBreath = figure.breath
                if !glancing && abs(figure.glance) >= 0.5 { glances += 1; glancing = true }
                if glancing && abs(figure.glance) < 0.3 { glancing = false }
            }
            for (track, renderer) in [(bust, "square stage"), (body, "tall body")] where !track.head.isEmpty {
                check(track.head.allSatisfy { abs($0) <= limits.headDegrees + 1e-9 },
                    "resting turns stay inside each character's reviewed crop limit (\(renderer))")
                check(span(track.head) >= (activity == .idle ? turnFloor(id) : 0.3),
                    "a resting head visibly turns, not a 0.1 degree tremor (\(renderer))")
                check(span(track.vertical) >= 0.6 && span(track.vertical) <= 2,
                    "a resting head visibly rises and settles by 0.6 to 2 points (\(renderer))")
                check(span(track.breath) >= 0.6,
                    "breathing lifts the shoulders at least 0.6 points on the 208 pt stage (\(renderer))")
            }
            let cycles = zip(breaths.dropFirst(), breaths).map { $0 - $1 }
            check(breaths.count >= 11 && breaths.count <= 18 && cycles.allSatisfy { $0 > 3.2 && $0 < 5.6 },
                "one breath every 3.5 to 5 seconds")
            check(Set(cycles.map { ($0 * 20).rounded() }).count >= 3,
                "no two breaths are quite the same length")
            if activity == .idle {
                check(glances >= 2, "a resting head makes small glance-follow turns every minute")
            }
        }
    }

    // Changing activity hands the posture over instead of restarting every
    // cycle at the same start pose (Oct 16 2026).
    for (id, _) in people {
        let clock = CharacterBodyPerformanceClock()
        let identity = id + "|/images/a.png"
        let plan: [(until: Double, activity: CharacterActivity)] = [
            (20, .idle), (35, .listening), (47, .thinking), (75, .speaking), (90, .idle),
            (101, .listening), (112, .idle)]
        var previous: (head: Double, tilt: Double, ambient: Double, activity: CharacterActivity)?
        var speechStart = 0.0
        for frame in 0...(112 * 12) {
            let time = Double(frame) / 12
            let activity = plan.first { time < $0.until }?.activity ?? .idle
            if activity == .speaking && previous?.activity != .speaking { speechStart = time }
            let state = CharacterPresentation(activity: activity, elapsed: activity == .speaking ? time - speechStart : 0)
            let sample = clock.sample(identity: identity, time: time, level: 0, active: true, presentation: state)
            let figure = CharacterFigureMotion.pose(id: id, time: time, level: 0, active: true,
                presentation: state, performance: sample)
            let face = CharacterMotion.pose(id: id, time: time, level: 0, active: true,
                presentation: state, performance: sample)
            if let previous {
                check(abs(sample.ambientElapsed - previous.ambient - 1.0 / 12) < 1e-9,
                    "the ambient clock never restarts on an activity change")
                if previous.activity != activity {
                    check(sample.activityBlend == 0 && sample.previousActivity == previous.activity,
                        "a new activity starts blending from the one that ended")
                    // A glance alone may move about one degree in a frame; a
                    // restarted cycle would jump several.
                    check(abs(figure.headAngle - previous.head) < 1.6 && abs(face.tilt - previous.tilt) < 0.35,
                        "an activity change does not snap the head to a new start pose")
                }
            }
            previous = (figure.headAngle, face.tilt, sample.ambientElapsed, activity)
        }
    }

    // Finding 23: one spoken reply longer than two minutes keeps breathing and
    // swaying; only the finite speech gestures keep their 120 s ceiling.
    for id in [CharacterMotion.harleyID, CharacterMotion.kianaID, CharacterMotion.angelID] {
        let clock = CharacterBodyPerformanceClock()
        var heads = [Double](), tilts = [Double](), breaths = [Double]()
        var last = CharacterBodyPerformanceSample.still
        for frame in 0...(200 * 12) {
            let time = Double(frame) / 12
            let state = CharacterPresentation(activity: .speaking, elapsed: time.truncatingRemainder(dividingBy: 9),
                outputEpisodeKey: "one-long-story", outputPhase: .playing, outputSpeakerID: id)
            last = clock.sample(identity: id + "|/images/a.png", time: time, level: 0, active: true, presentation: state)
            guard time >= 150 && time <= 180 else { continue }
            let figure = CharacterFigureMotion.pose(id: id, time: time, level: 0, active: true,
                presentation: state, performance: last)
            heads.append(figure.headAngle)
            breaths.append(figure.breath)
            tilts.append(CharacterMotion.pose(id: id, time: time, level: 0, active: true,
                presentation: state, performance: last).tilt)
        }
        check(abs(last.ambientElapsed - 200) < 1e-6 && last.elapsed <= 120,
            "the ambient clock runs through a long reply while gestures keep their cap")
        check(span(heads) > 0.5 && span(tilts) > 0.2 && span(breaths) > 0.5,
            "breathing and sway continue past two minutes of one spoken reply")
    }
    check(CharacterFigureMotion.resting(id: CharacterMotion.harleyID, time: .nan) == .still
        && CharacterFigureMotion.resting(id: CharacterMotion.harleyID, time: -1) == .still,
        "an invalid clock produces no resting motion")
    let huge = CharacterFigureMotion.resting(id: CharacterMotion.lillyID, time: .greatestFiniteMagnitude)
    check([huge.head, huge.nod, huge.torso, huge.breath, huge.glance].allSatisfy(\.isFinite)
        && abs(huge.head) <= 1 && (0...1).contains(huge.breath), "huge finite clocks keep resting life bounded")
}
