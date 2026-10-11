import Foundation

/// Source-clock and authored-cue contracts; no AVFoundation, audio, network,
/// transcript, wall-clock timer or generated emotion is involved.
func runCharacterOutputEpisodeChecks(_ check: (Bool, String) -> Void) {
    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
    let id = CharacterMotion.harleyID
    var scopes = CharacterReplyScope()
    let unscopedA = scopes.key(replyScopeKey: nil), unscopedB = scopes.key(replyScopeKey: nil)
    check(unscopedA != unscopedB, "Adjacent nil-key enqueues are independent replies unless explicitly grouped")
    check(scopes.key(replyScopeKey: "turn-a") == scopes.key(replyScopeKey: "turn-a")
        && scopes.key(replyScopeKey: "turn-a") != scopes.key(replyScopeKey: "turn-b"),
        "Only a caller's explicit local turn groups streamed sentence pieces")
    var carry = CharacterCueCarryState()
    let first = carry.cue(for: "%%%angry%%% First.", speakerID: id, messageKey: "reply-a")
    let firstKey = carry.outputEpisodeKey
    check(first.expression == .angry && firstKey != nil, "An authored reply owns a local output episode")
    check(carry.cue(for: "Second sentence.", speakerID: id, messageKey: "reply-a").expression == .angry,
        "A tagless sentence keeps only its own reply's direction")
    check(carry.outputEpisodeKey == firstKey, "Sentence boundaries do not replay a body's entrance")
    carry.finish()
    check(carry.presentation(phase: .queuedGap).outputPhase == .stopped,
        "A drained pump has no active held expression")
    check(carry.cue(for: "After this pump drained.", speakerID: id, messageKey: "reply-a").expression == .angry
        && carry.outputEpisodeKey == firstKey, "Only the same immutable streamed reply retains its cue and episode across pumps")
    let moment = carry.cue(for: "%%%laugh%%% Third.", speakerID: id, messageKey: "reply-a")
    check(moment.moment == .amused,
        "An authored short laugh overlays the reply's base direction")
    let pausedMoment = carry.presentation(phase: .paused, elapsed: 0.2, playingCue: moment)
    check(pausedMoment.expression == moment.expression(at: 0.2) && pausedMoment.laughing,
        "Pausing an authored moment preserves its current expression and static face")
    let gap = carry.presentation(phase: .queuedGap)
    check(gap.expression == .angry && !gap.laughing && gap.outputSpeakerID == id,
        "Queue gaps hold the owned base cue without repeating a moment")
    check(carry.cue(for: "New reply.", speakerID: id, messageKey: "reply-b").expression == .neutral,
        "A different message never inherits the previous anger")
    check(carry.outputEpisodeKey != firstKey, "Even adjacent same-owner messages have different episodes")
    _ = carry.cue(for: "%%%warm%%% Mine.", speakerID: id, messageKey: "reply-b")
    check(carry.cue(for: "Another speaker.", speakerID: CharacterMotion.dellaID, messageKey: "reply-b").expression == .neutral,
        "A different speaker cannot inherit an authored cue")
    carry.reset()
    let stoppedKey = carry.outputEpisodeKey
    check(stoppedKey == nil && carry.presentation(phase: .paused).outputPhase == .stopped,
        "Pump finish/stop removes the held output presentation")
    _ = carry.cue(for: "%%%tender%%% Streaming.", speakerID: id, messageKey: nil)
    let streamingKey = carry.outputEpisodeKey
    carry.adoptMessageKey("stored-reply")
    check(carry.cue(for: "Stored tail.", speakerID: id, messageKey: "stored-reply").expression == .tender
        && carry.outputEpisodeKey == streamingKey, "Adoption labels an existing streamed reply without replacing it")
    carry.reset()
    check(carry.cue(for: "Tagless after pump finish.", speakerID: id, messageKey: nil).expression == .neutral
        && carry.outputEpisodeKey != streamingKey, "A completed pump cannot carry a cue or reuse an episode")
    carry.reset()
    _ = carry.cue(for: "%%%warm%%% Scoped.", speakerID: id, messageKey: "immutable-turn", episodeKey: "reply-immutable-turn")
    let beforeStop = carry.outputEpisodeKey
    carry.finish()
    _ = carry.cue(for: "Natural resumed tail.", speakerID: id, messageKey: "immutable-turn", episodeKey: "reply-immutable-turn")
    check(carry.outputEpisodeKey == beforeStop && carry.baseCue.expression == .warm,
        "Natural pump finish retains the same immutable scoped episode")
    carry.reset()
    _ = carry.cue(for: "After explicit stop.", speakerID: id, messageKey: "immutable-turn", episodeKey: "reply-immutable-turn")
    check(carry.outputEpisodeKey != beforeStop && carry.baseCue.expression == .neutral,
        "Explicit stop/supersede creates a new generation even if a late chunk repeats its scope")

    let metadata = CharacterAudioIdentity(speakerID: id, speech: true, expression: "warm", moment: "amused")!
    let other = CharacterAudioIdentity(speakerID: CharacterMotion.dellaID, speech: true, expression: "concerned", moment: nil)!
    var timeline = CharacterPlaybackTimeline()
    timeline.append(identity: metadata, duration: 1, now: 10)
    let clipKey = timeline.presentation(at: 10.2, expectedID: id)?.outputEpisodeKey
    timeline.append(identity: metadata, duration: 1, now: 10.1)
    check(timeline.presentation(at: 11.2, expectedID: id)?.outputEpisodeKey == clipKey,
        "Contiguous owned call clips share a body performance")
    check(timeline.presentation(at: 10.2, expectedID: id)?.outputPhase == .playing,
        "The actual call source interval explicitly owns playback")
    let callGap = timeline.queuedGapPresentation(at: 12.2, expectedID: id)
    check(callGap?.outputEpisodeKey == clipKey && callGap?.expression == .warm && callGap?.laughing == false,
        "A drained call clip holds its base direction during a short owned queue gap")
    check(timeline.queuedGapPresentation(at: 12.2, expectedID: CharacterMotion.dellaID) == nil,
        "A call gap cannot lend another character its cue")
    check(timeline.queuedGapPresentation(at: 13.21, expectedID: id) == nil,
        "A long drained call does not display a stale speech direction")
    timeline.append(identity: metadata, duration: 1, now: 12.5)
    check(timeline.presentation(at: 12.6, expectedID: id)?.outputEpisodeKey == clipKey,
        "Evicting old call intervals retains only the short owned episode boundary")
    timeline.append(identity: other, duration: 1, now: 12.6)
    check(timeline.presentation(at: 13.6, expectedID: CharacterMotion.dellaID)?.outputEpisodeKey != clipKey,
        "A call speaker change starts a fresh performance")
    timeline.append(identity: nil, duration: 1, now: 15)
    check(timeline.queuedGapPresentation(at: 15.5, expectedID: CharacterMotion.dellaID) == nil,
        "An effect or unknown interval blocks a held speech cue")
    timeline.reset()
    timeline.append(identity: metadata, duration: 1, now: 0)
    check(timeline.presentation(at: 0.2, expectedID: id)?.outputEpisodeKey != clipKey,
        "Barge-in/reset changes the episode even if no idle frame was observed")
    timeline.reset()
    timeline.append(identity: metadata, duration: 1, now: .greatestFiniteMagnitude)
    check(timeline.clips.isEmpty, "An unrepresentable call interval fails closed")

    func speech(_ elapsed: Double, key: String = "episode-a", phase: CharacterOutputPhase = .playing,
                owner: String? = nil, expression: CharacterExpression = .warm) -> CharacterPresentation {
        CharacterPresentation(activity: .speaking, expression: expression, elapsed: elapsed,
            outputEpisodeKey: key, outputPhase: phase, outputSpeakerID: owner ?? id)
    }
    let clock = CharacterBodyPerformanceClock()
    func sample(_ time: Double, _ state: CharacterPresentation, level: Double = 0.25,
                active: Bool = true) -> CharacterBodyPerformanceSample {
        clock.sample(identity: id + "|original-art", time: time, level: level, active: active, presentation: state)
    }
    let beginning = sample(10, speech(0))
    let rising = sample(10.12, speech(0.12))
    let quiet = sample(10.24, speech(0.24), level: 0)
    check(beginning.elapsed == 0 && rising.energy > 0 && rising.energy < 0.31,
        "A body enters with a slow bounded attack instead of a full RMS jump")
    check(quiet.energy > 0 && quiet.energy < rising.energy,
        "A syllable gap releases the body gently instead of snapping both hands shut")
    let paused = sample(10.30, speech(0.30, phase: .paused), level: 0)
    let held = sample(1000, speech(0.30, phase: .paused), level: 0)
    check(paused == held, "A long pause spends neither gesture time nor body energy")
    let resumed = sample(1000.1, speech(0.40))
    check(close(resumed.elapsed, 0.40) && resumed.accentScale == paused.accentScale,
        "Resume follows the frozen source clock without replaying a greeting")
    let shortGap = sample(1000.2, speech(0, phase: .queuedGap), level: 0)
    _ = sample(1001, speech(0, phase: .queuedGap), level: 0)
    let nextSentence = sample(1001.1, speech(0.10))
    check(close(shortGap.elapsed, 0.40) && close(nextSentence.elapsed, 0.50),
        "A queue gap settles follow-through but does not spend the next sentence's body clock")
    let fresh = sample(1001.2, speech(0, key: "episode-b"))
    check(fresh.elapsed == 0 && fresh.accentElapsed == 0 && fresh.accentScale == 1,
        "An adjacent same-owner new reply restarts only its own finite recipe")
    check(sample(1001.3, speech(0.1, owner: CharacterMotion.dellaID)) == .still,
        "Explicit output from a foreign owner parks the entire shared sample")
    check(sample(1001.4, speech(.nan)) == .still, "Malformed explicit source time cannot drive body motion")
    check(sample(1001.5, speech(0), active: false) == .still, "Motion policy stop clears bounded decorative state")
    let caughtUp = sample(1001.6, speech(14.25))
    check(close(caughtUp.elapsed, 14.25) && CharacterFigureMotion.gestureEnvelope(performance: caughtUp, tempo: 0.67) == 0,
        "Appearing mid-clip catches up instead of waving again")
    check(sample(1001.7, CharacterPresentation(outputPhase: .stopped)).energy == 0,
        "A stopped output cannot hold body energy")
    let drainedResume = sample(1002, speech(0.1))
    check(close(drainedResume.elapsed, 14.35) && drainedResume.accentScale == 1
        && CharacterFigureMotion.gestureEnvelope(performance: drainedResume, tempo: 0.83) == 0,
        "A briefly drained same logical reply cannot buy another entrance")

    let late = CharacterBodyPerformanceClock()
    _ = late.sample(identity: id, time: 0, level: 0.22, active: true, presentation: speech(0))
    _ = late.sample(identity: id, time: 12, level: 0.22, active: true, presentation: speech(12))
    let one = late.sample(identity: id, time: 12.1, level: 0.22, active: true,
        presentation: speech(12.1, expression: .concerned))
    let refractory = late.sample(identity: id, time: 12.2, level: 0.22, active: true,
        presentation: speech(12.2, expression: .warm))
    let two = late.sample(identity: id, time: 16, level: 0.22, active: true,
        presentation: speech(16, expression: .serious))
    let exhausted = late.sample(identity: id, time: 20, level: 0.22, active: true,
        presentation: speech(20, expression: .warm))
    check(one.accentElapsed == 0 && one.accentScale == 0.5 && refractory.accentElapsed > 0,
        "A later authored cue gets one small accent, with an immediate-change refractory hold")
    check(two.accentElapsed == 0 && exhausted.accentElapsed > 0,
        "The second late accent exhausts the finite reply budget")
    check(one.expressionBlend == 0 && one.previousExpression == .warm,
        "A changed body direction begins at the previously authored posture")

    // The actual 24/12/8-Hz samplers remain finite, deterministic and bounded;
    // many audible onsets or authored cue changes cannot create an endless wave.
    for hz in [24, 12, 8] {
        for rig in CharacterMotion.animatedIDs {
            let a = CharacterBodyPerformanceClock(), b = CharacterBodyPerformanceClock()
            var extraAccents = 0
            var previous = CharacterBodyPerformanceSample.still
            for tick in 0...(30 * hz) {
                let time = Double(tick) / Double(hz)
                let cue: CharacterExpression = Int(time / 3).isMultiple(of: 2) ? .warm : .concerned
                let level = Int(time * 2).isMultiple(of: 3) ? 0.0 : 0.24
                let state = speech(time, owner: rig, expression: cue)
                let value = a.sample(identity: rig, time: time, level: level, active: true, presentation: state)
                check(value == b.sample(identity: rig, time: time, level: level, active: true, presentation: state),
                    "The same clock, authored cue and rig yield identical choreography")
                check(value.energy.isFinite && (0...1).contains(value.energy)
                    && abs(value.energy - previous.energy) <= 2.5 / Double(hz) + 0.000001,
                    "All frame budgets retain the body's energy velocity bound")
                if value.accentElapsed == 0 && previous.accentElapsed > 0 { extraAccents += 1 }
                previous = value
            }
            check(extraAccents <= 2, "Repeated silence/cues spend at most two late accents per reply")
            check(CharacterFigureMotion.gestureEnvelope(performance: previous,
                tempo: CharacterFigureMotion.profile(id: rig).tempo) == 0,
                "A long reply settles every finite hand recipe")
        }
    }
    for rig in CharacterMotion.animatedIDs {
        let sparse = CharacterBodyPerformanceClock()
        var value = CharacterBodyPerformanceSample.still
        for t in [0.0, 0.12, 0.35, 0.65, 1.3, 3.4, 6.8, 10.4, 14.25] {
            value = sparse.sample(identity: rig, time: t, level: 0.22, active: true,
                presentation: speech(t, owner: rig))
        }
        check(close(value.elapsed, 14.25) && CharacterFigureMotion.gestureEnvelope(performance: value,
            tempo: CharacterFigureMotion.profile(id: rig).tempo) == 0,
            "Sparse native capture primes actual source time and fully settles all rigs")
    }
    for time in [Double.greatestFiniteMagnitude, 0, 1] {
        let pose = CharacterMotion.pose(id: id, time: time, level: 0.25, active: true)
        check([pose.mouth, pose.blink, pose.tilt, pose.lift, pose.brow, pose.scale].allSatisfy(\.isFinite),
            "Huge finite clock values cannot overflow mouth slots or decorative geometry")
    }
}
