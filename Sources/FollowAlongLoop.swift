import Foundation

// MARK: - Tellavision "Follow along": the loop (one background queue)
//
// Nov 14 2026. Moved out of FollowAlongAudio.swift after the review, so the
// tests run it on a made-up film: Foundation only. The matcher comes through
// the FollowMatching doorway (FollowAlongEngine in the app), and the clock and
// the diagnostics trail are handed in. FollowAlongAudio.swift's player owns
// the microphone, the speech and the audio session; this loop owns the
// 16-second memory, the matcher, the rules (FollowJudge) and the planner, on
// ONE background queue.
//
// The schedule runs from the arrival of microphone sound, not from a timer:
// sound keeps arriving with the phone locked, timers may not fire. Only the
// newest block of sound runs the schedule. When a slow check holds the queue
// up, the blocks that pile up behind it go into the memory without each
// running a check of its own, so the loop never falls behind the room.
//
// Privacy: the microphone's sound lives only in the 16-second memory. It is
// never written to a file, never sent and never logged; the trail and the
// test report hold numbers only (FollowAlongTests checks the source).

/// Shared by the main thread and the loop's queue: whether the phone is
/// speaking, and when VoiceOver is likely quiet again. Nothing talks over
/// VoiceOver: after she moves VoiceOver or presses a button, the phone waits
/// until VoiceOver has had time to read (FollowVoiceOverTime).
final class FollowSpeechGate {
    private let lock = NSLock()
    private var busy = false
    private var quietAt = 0.0

    var speaking: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return busy
        }
        set {
            lock.lock()
            busy = newValue
            lock.unlock()
        }
    }

    var voiceOverQuietAt: Double {
        lock.lock()
        defer { lock.unlock() }
        return quietAt
    }

    func voiceOverBusy(until time: Double) {
        lock.lock()
        quietAt = max(quietAt, time)
        lock.unlock()
    }

    func canSpeak(now: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !busy && now >= quietAt
    }
}

/// What the loop tells the main thread.
enum FollowLoopOutput: Equatable {
    case prepared(millis: Double, printSeconds: Double, language: String, warning: String?)
    case failed(String)
    /// A status sentence; `stops` when Follow along ends after it.
    case sentence(String, sound: FollowSoundKind?, stops: Bool)
    /// A description line to say now.
    case speak(id: String, text: String)
    /// The soft chime: a line did not fit; pause the TV to hear it.
    case chime
    case report(FollowReport)
    /// Where am I: film seconds, or nil when not in step.
    case place(Double?)
}

/// Where the microphone's sound goes: the loop (the tests use their own).
protocol FollowSoundSink: AnyObject {
    /// Sound at 8 kHz mono, ending at `end` on the audio clock.
    func receive(_ samples: [Int16], endingAt end: Double)
}

/// Blocks of sound handed to the loop and not yet taken. Counted on any
/// thread, so the loop's queue knows whether a block is the newest one.
final class FollowBlockCount {
    private let lock = NSLock()
    private var waiting = 0

    func add() {
        lock.lock()
        waiting += 1
        lock.unlock()
    }

    /// Takes one block. True when no newer block is waiting behind it.
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        waiting = max(0, waiting - 1)
        return waiting == 0
    }
}

final class FollowAlongLoop: FollowSoundSink {
    private let queue: DispatchQueue
    private let gate: FollowSpeechGate
    /// The audio clock: FollowClock.now in the app, the tests' own clock in the tests.
    private let clock: () -> Double
    /// The diagnostics trail (KadeBreadcrumbs in the app): states and numbers only.
    private let trail: (String) -> Void
    private let deliver: (FollowLoopOutput) -> Void
    private let blocks = FollowBlockCount()

    // Everything below is touched on `queue` only.
    private var engine: FollowMatching?
    private var track: FollowTrack?
    private var offset = 0.0
    private var cuesById: [String: FollowCue] = [:]
    private var ring = FollowRing(seconds: 16)
    private var judge = FollowJudge(now: 0, endSec: 0, part: false)
    private var holder = FollowHolder(cues: [], offset: 0)
    private var watch = FollowLevelWatch()
    private var pace = FollowPace()
    private var settings = FollowAlongSettings()
    private var report = FollowReport()
    private var running = false
    private var descriptionsOn = true
    /// Seconds a line starts early: the output delay plus her nudge.
    private var lead = 0.0
    /// The phone's own speaker is in use, so the microphone hears the phone.
    private var echoRisk = true
    private var ownSounds: [(start: Double, end: Double)] = []
    private var spokenIds: Set<String> = []
    /// The line the film was last checked for before speaking it: syncprint's
    /// README loop allows one such check per line (its `checkedFor`), so a
    /// quiet stretch of the film does not start a match on every tick.
    private var checkedFor: String?
    private var nextPlanAt = 0.0
    private var lastReportAt = 0.0
    private var startedAt = 0.0
    private var listenedBefore = 0.0
    private var creditSaid = false
    private var levelSum = 0.0
    private var levelCount = 0

    init(queue: DispatchQueue, gate: FollowSpeechGate, clock: @escaping () -> Double,
         trail: @escaping (String) -> Void, deliver: @escaping (FollowLoopOutput) -> Void) {
        self.queue = queue
        self.gate = gate
        self.clock = clock
        self.trail = trail
        self.deliver = deliver
    }

    /// Reads the track, loads syncprint.js and the fingerprint, and builds
    /// the matcher (a second or so for a long film, so it is done when the
    /// sheet opens, before she presses Start).
    func prepare(trackData: Data, print: Data, settings: FollowAlongSettings) {
        queue.async { [self] in
            let began = clock()
            let parsed: FollowTrack
            do {
                parsed = try FollowTrack.read(trackData)
            } catch let problem as FollowTrack.Problem {
                deliver(.failed(problem.words))
                return
            } catch {
                deliver(.failed(FollowWords.damagedOnPhone))
                return
            }
            guard let script = FollowAlongEngine.bundledScript() else {
                trail("follow along: syncprint.js is not in the app")
                deliver(.failed(FollowWords.couldNotStart))
                return
            }
            do {
                let made = try FollowAlongEngine(script: script)
                try made.load(print: print)
                let millis = ready(parsed, matcher: made, settings: settings, began: began)
                trail("follow along: ready, syncprint \(made.version), \(Int(made.printSeconds)) s, \(parsed.cues.count) lines, \(Int(millis)) ms")
            } catch FollowAlongEngine.Failure.print {
                deliver(.failed(FollowWords.damagedOnPhone))
            } catch {
                trail("follow along: could not start: \(error)")
                deliver(.failed(FollowWords.couldNotStart))
            }
        }
    }

    /// The same with a matcher made elsewhere (the tests hand in their own).
    func prepare(track parsed: FollowTrack, matcher: FollowMatching, settings: FollowAlongSettings) {
        queue.async { [self] in
            ready(parsed, matcher: matcher, settings: settings, began: clock())
        }
    }

    /// Everything a new track starts with. Returns how long getting ready
    /// took, in milliseconds.
    @discardableResult
    private func ready(_ parsed: FollowTrack, matcher made: FollowMatching, settings fresh: FollowAlongSettings,
                       began: Double) -> Double {
        settings = fresh
        let shift = parsed.printOffset(printSeconds: made.printSeconds)
        made.setCues(parsed.cues, offset: shift)
        engine = made
        track = parsed
        offset = shift
        var byId: [String: FollowCue] = [:]
        for cue in parsed.cues where byId[cue.id] == nil { byId[cue.id] = cue }
        cuesById = byId
        creditSaid = false
        listenedBefore = 0
        spokenIds = []
        report = FollowReport()
        report.printSeconds = made.printSeconds
        report.cues = parsed.cues.count
        let millis = (clock() - began) * 1000
        report.loadMillis = millis
        deliver(.prepared(millis: millis, printSeconds: made.printSeconds, language: parsed.language, warning: parsed.warning))
        return millis
    }

    /// She pressed Start (or Listen again). The film may be anywhere now, so
    /// the place, the memory and the record of the lines said all start
    /// afresh: a line she hears again after going back is said again (Nov 14
    /// review: the old record kept every line of the last run silent).
    func start(now: Double) {
        queue.async { [self] in
            guard let engine, let track else {
                // No track behind this loop: it would listen and never say
                // anything, so it says so and stops.
                deliver(.sentence(FollowWords.couldNotStart, sound: nil, stops: true))
                return
            }
            // The doorway forgets the place and the lines said together.
            engine.reset()
            spokenIds = []
            ring.clear()
            judge = FollowJudge(now: now, endSec: track.endInPrint(printSeconds: engine.printSeconds), part: !track.reachesFilmEnd)
            holder = FollowHolder(cues: track.cues, offset: offset)
            watch = FollowLevelWatch()
            ownSounds = []
            levelSum = 0
            levelCount = 0
            descriptionsOn = true
            checkedFor = nil
            nextPlanAt = 0
            startedAt = now
            lastReportAt = now
            running = true
        }
    }

    func stop() {
        queue.async { [self] in
            let now = clock()
            endRun(now: now)
            ring.clear()
            snapshot(now: now)
        }
    }

    /// This run's minutes count, whatever ended it: Stop, the film's end, or
    /// ten minutes without the film (Nov 14 review: a film that ended lost
    /// its minutes from the test report).
    private func endRun(now: Double) {
        if running { listenedBefore += max(0, now - startedAt) }
        running = false
    }

    /// The sheet closed: the matcher's memory goes.
    func release() {
        queue.async { [self] in
            running = false
            engine = nil
            track = nil
            ring.clear()
        }
    }

    func update(settings fresh: FollowAlongSettings) {
        queue.async { [self] in settings = fresh }
    }

    func update(lead seconds: Double, outputDelay: Double, echoRisk risk: Bool) {
        queue.async { [self] in
            lead = seconds
            echoRisk = risk
            report.outputDelayMillis = outputDelay * 1000
        }
    }

    func setDescriptions(on: Bool) {
        queue.async { [self] in descriptionsOn = on }
    }

    /// The phone made a sound (speech or a chime) from `time`, to `end` when known.
    func soundStarted(at time: Double, until end: Double?) {
        queue.async { [self] in ownSounds.append((start: time, end: end ?? .infinity)) }
    }

    func soundEnded(at time: Double) {
        queue.async { [self] in
            if let index = ownSounds.lastIndex(where: { $0.end == .infinity }) { ownSounds[index].end = time }
        }
    }

    /// A description ended. `started` false: it never made a sound, so it is
    /// not counted as said.
    func finished(cue id: String, started: Bool, seconds: Double?, characters: Int, now: Double) {
        queue.async { [self] in
            guard let engine else { return }
            if !started {
                engine.forget(id)
                spokenIds.remove(id)
                report.linesSpoken = max(0, report.linesSpoken - 1)
                return
            }
            if let seconds { pace.measured(characters: characters, seconds: seconds) }
            guard running, let cue = cuesById[id] else { return }
            let state = engine.state(now: now)
            guard state.status == .locked, let film = state.filmSec else { return }
            if film + lead > cue.endSec - offset + FollowHolder.toleranceSec {
                pace.overran()
            } else {
                pace.inTime()
            }
        }
    }

    /// A status sentence was said: its timing teaches the voice speed.
    func sentenceSpoken(characters: Int, seconds: Double) {
        queue.async { [self] in pace.measured(characters: characters, seconds: seconds) }
    }

    func whereAmI(now: Double) {
        queue.async { [self] in
            guard running, let engine else {
                deliver(.place(nil))
                return
            }
            let state = engine.state(now: now)
            if judge.phase == .inStep, state.status == .locked, let film = state.filmSec {
                deliver(.place(film + offset))
            } else {
                deliver(.place(nil))
            }
        }
    }

    /// Sound from the microphone, ending at `end` on the audio clock. Every
    /// block goes into the memory, but only the newest runs the schedule:
    /// after a slow check, the blocks that queued up behind it are stored,
    /// not each checked again on almost the same sound (Nov 14 review: the
    /// loop could fall behind for good, one processor core busy).
    func receive(_ samples: [Int16], endingAt end: Double) {
        blocks.add()
        queue.async { [self] in
            let newest = blocks.take()
            guard running else { return }
            ring.append(samples, endingAt: end)
            measureLevel(samples)
            if newest { tick(now: clock()) }
        }
    }

    // MARK: The schedule

    private func tick(now start: Double) {
        guard running, let engine else { return }
        var now = start
        let listen = engine.nextListen(now: now)
        if listen.wait <= 0, let clip = cleanClip(listen.clip, now: now) {
            // A check takes time: what follows is decided as of its end.
            now = runCheck(clip, now: now)
        }
        guard running else { return }
        let state = engine.state(now: now)
        // syncprint's README: the playing rate belongs in the test report.
        if state.status == .locked { report.playingRate = state.rate }
        handle(judge.tick(state: state, now: now), now: now)
        guard running else { return }
        describe(state, now: now)
        if now - lastReportAt >= 2 {
            lastReportAt = now
            snapshot(now: now)
        }
    }

    /// One check: the clip against the fingerprint, then what the rules make
    /// of it. Returns the clock time after the match: syncprint's README loop
    /// tells the tracker about a match, and reads it, as of then (the doorway
    /// passes the same time to onMatch), not as of when the check began.
    private func runCheck(_ clip: (samples: [Int16], start: Double), now: Double) -> Double {
        guard let engine else { return now }
        let result = engine.check(clip.samples, clipStart: clip.start, now: now)
        report.checked(result)
        let after = max(clock(), now + max(0, result.millis) / 1000)
        // Read at once, so a jump is never missed (reading clears it).
        let state = engine.state(now: after)
        handle(judge.checked(result, state: state, now: after), now: after)
        return after
    }

    /// Every half second of sound, measured as it arrives: a room gone quiet
    /// gets a check now instead of at the next turn, so a pause is caught fast.
    private func measureLevel(_ samples: [Int16]) {
        for sample in samples {
            let value = Double(sample) / 32768
            levelSum += value * value
            levelCount += 1
            if levelCount >= 4000 {
                let rms = (levelSum / Double(levelCount)).squareRoot()
                let db = rms > 1e-6 ? 20 * log10(rms) : -120
                levelSum = 0
                levelCount = 0
                if judge.phase == .inStep, watch.block(db: db, heard: judge.heard.level) { engine?.hurry() }
            }
        }
    }

    /// The last `seconds` of sound, unless the phone's own speaker was
    /// sounding in it (with earbuds the microphone never hears the phone).
    private func cleanClip(_ seconds: Double, now: Double) -> (samples: [Int16], start: Double)? {
        guard let clip = ring.last(seconds) else { return nil }
        guard echoRisk else { return clip }
        if gate.speaking { return nil }
        let end = clip.start + seconds
        ownSounds.removeAll { $0.end < now - 30 }
        for sound in ownSounds where sound.start < end + 0.3 && sound.end > clip.start - 0.3 {
            return nil
        }
        return clip
    }

    private func handle(_ events: [FollowEvent], now: Double) {
        guard let track, !events.isEmpty else { return }
        for event in events {
            report.note(event)
            var held: [String] = []
            var stops = false
            switch event {
            case .found(let film):
                if report.secondsToLock == nil { report.secondsToLock = now - startedAt }
                holder.moved(to: film)
            case .backInStep(let film), .skipped(let film, _):
                holder.moved(to: film)
            case .paused:
                // Her choice: the lines that did not fit are read while the film is paused.
                let lines = holder.takeAll()
                if descriptionsOn {
                    held = lines.map { $0.text }
                    report.heldLinesRead += lines.count
                    for line in lines {
                        spokenIds.insert(line.id)
                        engine?.spoke(line.id, now: now, filmSec: line.startSec)
                    }
                }
            case .ended, .noFilm:
                stops = true
                endRun(now: now)
            default:
                break
            }
            let words = FollowJudge.words(for: event, track: track, offset: offset, held: held, firstCredit: !creditSaid)
            if case .found = event { creditSaid = true }
            deliver(.sentence(words.text, sound: words.sound, stops: stops))
            if stops { break }
        }
    }

    /// Descriptions: hold the lines whose window closed unspoken, then ask
    /// the planner for the line to say now. The rules are syncprint's README
    /// loop, line by line: before a line, when the last good check is more
    /// than 15 seconds old, check the film first, once for that line; and say
    /// a line only while the tracker's misses are 0, that is when the check
    /// found the film or the film is in a quiet stretch of its own. One
    /// silent check over a paused TV holds the line (the tracker checks again
    /// at once, and after two misses it holds too).
    private func describe(_ state: FollowTrackerState, now: Double) {
        guard let engine, judge.phase == .inStep, state.status == .locked, let film = state.filmSec else { return }
        let heardAt = film + lead
        guard descriptionsOn else {
            holder.pass(filmSec: heardAt)
            return
        }
        let important = settings.amount == .important
        let fresh = holder.sweep(filmSec: heardAt, spoken: spokenIds, importantOnly: important)
        if !fresh.isEmpty {
            report.linesHeld += fresh.count
            if settings.heldChime, !gate.speaking, holder.mayChime(now: now) { deliver(.chime) }
        }
        guard now >= nextPlanAt else { return }
        nextPlanAt = now + 0.25
        guard gate.canSpeak(now: now) else { return }
        let options = FollowPlanOptions(secPerChar: pace.secPerChar, leadSec: 0.15, toleranceSec: FollowHolder.toleranceSec,
                                        importantOnly: important)
        var plan = engine.plan(state, shift: lead, options: options)
        guard plan.action == .speak else { return }
        var current = state
        var saidAt = now
        // Design 5.3 and syncprint's README: before a line, when the last
        // good check is more than 15 seconds old, check the film first, once
        // for this line. The README hurries the tracker and matches on the
        // next tick; the last 6 seconds are already in memory, so the check
        // runs now instead. This is how a pause is caught.
        if let since = state.sinceLastFixSec, since > 15, checkedFor != plan.id {
            checkedFor = plan.id
            guard let clip = cleanClip(6, now: now) else {
                // The phone's own speaker sounded in those seconds: the
                // tracker checks at its first clean chance (the README's
                // hurry), and the line waits for a later tick.
                engine.hurry()
                return
            }
            saidAt = runCheck(clip, now: now)
            current = engine.state(now: saidAt)
            guard running, descriptionsOn, judge.phase == .inStep, current.status == .locked else { return }
            plan = engine.plan(current, shift: lead, options: options)
            guard plan.action == .speak, gate.canSpeak(now: saidAt) else { return }
        }
        // syncprint's README: speak only when misses is 0. A single missed
        // check over a paused TV must not let the line through; while the
        // tracker checks again, the line waits.
        guard current.misses == 0, let at = current.filmSec else { return }
        gate.speaking = true
        engine.spoke(plan.id, now: saidAt, filmSec: at)
        spokenIds.insert(plan.id)
        report.linesSpoken += 1
        if plan.short { report.shortLines += 1 }
        deliver(.speak(id: plan.id, text: plan.text))
    }

    private func snapshot(now: Double) {
        let listening = running ? max(0, now - startedAt) : 0
        report.minutesListened = (listenedBefore + listening) / 60
        report.secondsPerLetter = pace.median
        deliver(.report(report))
    }
}
