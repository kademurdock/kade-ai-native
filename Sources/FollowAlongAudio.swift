import AVFoundation
import Combine
import MediaPlayer
import UIKit
import UserNotifications

// MARK: - Tellavision "Follow along": the microphone, the speech, the session
//
// Nov 14 2026. Her phone listens to the film playing on her TV, finds its
// place, and speaks the description lines in the gaps, in her own VoiceOver
// voice (design TELLAVISION_SYNC_DESIGN_2026-11-13.md, Part 5.3).
//
// How it hangs together:
// - FollowAlongPlayer (main thread) owns the audio session, the microphone
//   engine, the speech engine, the lock screen and earbud buttons, calls and
//   route changes. The sheet (FollowAlongView.swift) shows it.
// - FollowAlongCapture turns the microphone's sound into 8 kHz mono on the
//   tap's own thread and hands it to the loop.
// - FollowAlongLoop runs on ONE background queue: the 16-second memory, the
//   matcher (FollowAlongEngine, the one doorway to syncprint.js), the rules
//   (FollowJudge) and the planner. The schedule runs from the arrival of
//   microphone sound, not from a timer: sound keeps arriving with the phone
//   locked, timers may not fire.
//
// Privacy: the microphone's sound lives only in the 16-second memory. It is
// never written to a file, never sent and never logged; the trail and the
// test report hold numbers only (FollowAlongTests checks the source).
//
// The audio session (KadeAudioSession, the Nov 14 keeper): Follow along
// takes the session as its own, like a film, holds it for as long as it
// listens or speaks, and holds the microphone lane (KadeAudioLanes), so the
// keeper never switches the session off under it. When it stops it hands
// both back, after its last sentence, and the keeper lets the session go a
// moment later so VoiceOver is back at its own level.
//
// Phone switch: kade.switch.followAlong. Server switch: KADE_DESCRIPTION_FOLLOW.

/// The phone's audio clock in seconds (the same clock as the microphone's
/// timestamps), for "now" everywhere in Follow along.
enum FollowClock {
    static func now() -> Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time())
    }
}

/// Shared by the main thread and the loop's queue: whether the phone is
/// speaking, and when VoiceOver is likely quiet again. Nothing talks over
/// VoiceOver: after she moves VoiceOver or presses a button, the phone waits
/// as the voice auditions do (KadeAudioSessionPolicy.voiceOverSettle).
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
enum FollowLoopOutput {
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

// MARK: - The loop (one background queue)

final class FollowAlongLoop {
    private let queue: DispatchQueue
    private let gate: FollowSpeechGate
    private let deliver: (FollowLoopOutput) -> Void

    // Everything below is touched on `queue` only.
    private var engine: FollowAlongEngine?
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
    private var nextPlanAt = 0.0
    private var lastReportAt = 0.0
    private var startedAt = 0.0
    private var listenedBefore = 0.0
    private var creditSaid = false
    private var levelSum = 0.0
    private var levelCount = 0

    init(queue: DispatchQueue, gate: FollowSpeechGate, deliver: @escaping (FollowLoopOutput) -> Void) {
        self.queue = queue
        self.gate = gate
        self.deliver = deliver
    }

    /// Reads the track, loads syncprint.js and the fingerprint, and builds
    /// the matcher (a second or so for a long film, so it is done when the
    /// sheet opens, before she presses Start).
    func prepare(trackData: Data, print: Data, settings: FollowAlongSettings) {
        queue.async { [self] in
            let began = FollowClock.now()
            self.settings = settings
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
                KadeBreadcrumbs.drop("follow along: syncprint.js is not in the app")
                deliver(.failed(FollowWords.couldNotStart))
                return
            }
            do {
                let made = try FollowAlongEngine(script: script)
                try made.load(print: print)
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
                report = FollowReport()
                report.printSeconds = made.printSeconds
                report.cues = parsed.cues.count
                let millis = (FollowClock.now() - began) * 1000
                report.loadMillis = millis
                KadeBreadcrumbs.drop("follow along: ready, syncprint \(made.version), \(Int(made.printSeconds)) s, \(parsed.cues.count) lines, \(Int(millis)) ms")
                deliver(.prepared(millis: millis, printSeconds: made.printSeconds, language: parsed.language, warning: parsed.warning))
            } catch FollowAlongEngine.Failure.print {
                deliver(.failed(FollowWords.damagedOnPhone))
            } catch {
                KadeBreadcrumbs.drop("follow along: could not start: \(error)")
                deliver(.failed(FollowWords.couldNotStart))
            }
        }
    }

    /// She pressed Start (or Listen again).
    func start(now: Double) {
        queue.async { [self] in
            guard let engine, let track else { return }
            engine.reset()
            ring.clear()
            judge = FollowJudge(now: now, endSec: track.endInPrint(printSeconds: engine.printSeconds), part: !track.reachesFilmEnd)
            holder = FollowHolder(cues: track.cues, offset: offset)
            watch = FollowLevelWatch()
            ownSounds = []
            levelSum = 0
            levelCount = 0
            descriptionsOn = true
            nextPlanAt = 0
            startedAt = now
            lastReportAt = now
            running = true
        }
    }

    func stop() {
        queue.async { [self] in
            if running { listenedBefore += max(0, FollowClock.now() - startedAt) }
            running = false
            ring.clear()
            snapshot(now: FollowClock.now())
        }
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

    /// Sound from the microphone, ending at `end` on the audio clock.
    func receive(_ samples: [Int16], endingAt end: Double) {
        queue.async { [self] in
            guard running else { return }
            ring.append(samples, endingAt: end)
            measureLevel(samples)
            tick(now: FollowClock.now())
        }
    }

    // MARK: The schedule

    private func tick(now: Double) {
        guard running, let engine else { return }
        let listen = engine.nextListen(now: now)
        if listen.wait <= 0, let clip = cleanClip(listen.clip, now: now) {
            runCheck(clip, now: now)
        }
        guard running else { return }
        let state = engine.state(now: now)
        handle(judge.tick(state: state, now: now), now: now)
        guard running else { return }
        describe(state, now: now)
        if now - lastReportAt >= 2 {
            lastReportAt = now
            snapshot(now: now)
        }
    }

    /// One check: the clip against the fingerprint, then what the rules make of it.
    private func runCheck(_ clip: (samples: [Int16], start: Double), now: Double) {
        guard let engine else { return }
        let result = engine.check(clip.samples, clipStart: clip.start, now: now)
        report.checked(result)
        // Read at once, so a jump is never missed (reading clears it).
        let state = engine.state(now: now)
        handle(judge.checked(result, state: state, now: now), now: now)
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
                running = false
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
    /// the planner for the line to say now.
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
        var at = film
        // Design 5.3: before a line, when the last good check is more than
        // 15 seconds old, check the last 6 seconds first (no waiting: the
        // sound is already in memory). This is how a pause is caught.
        if let since = state.sinceLastFixSec, since > 15, let clip = cleanClip(6, now: now) {
            runCheck(clip, now: now)
            let again = engine.state(now: now)
            guard running, descriptionsOn, judge.phase == .inStep, again.status == .locked, let now2 = again.filmSec else { return }
            at = now2
            plan = engine.plan(again, shift: lead, options: options)
            guard plan.action == .speak, gate.canSpeak(now: FollowClock.now()) else { return }
        }
        gate.speaking = true
        engine.spoke(plan.id, now: now, filmSec: at)
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

// MARK: - The microphone, to 8 kHz mono

/// Lives on the microphone tap's own thread. One converter, one bulk copy
/// per piece of sound, then on to the loop's queue.
final class FollowAlongCapture {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let loop: FollowAlongLoop

    init?(from source: AVAudioFormat, loop: FollowAlongLoop) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else { return nil }
        converter.downmix = true
        self.target = target
        self.converter = converter
        self.loop = loop
    }

    func take(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) {
        let frames = Double(buffer.frameLength)
        let rate = buffer.format.sampleRate
        guard frames > 0, rate > 0 else { return }
        let start = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : FollowClock.now() - frames / rate
        let end = start + frames / rate
        let capacity = AVAudioFrameCount(frames * target.sampleRate / rate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var given = false
        var problem: NSError?
        let status = converter.convert(to: out, error: &problem) { _, inputStatus in
            if given {
                inputStatus.pointee = .noDataNow
                return nil
            }
            given = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, problem == nil, out.frameLength > 0, let channels = out.int16ChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: channels[0], count: Int(out.frameLength)))
        loop.receive(samples, endingAt: end)
    }
}

// MARK: - The player (main thread)

@MainActor
final class FollowAlongPlayer: NSObject, ObservableObject {
    enum Phase: Equatable {
        /// No track open.
        case closed
        /// Reading the track and building the matcher.
        case preparing
        /// Start listening is ready.
        case ready
        case listening
        /// The microphone is off; the last sentence is being said.
        case stopping
        case stoppedByCall
        case micDenied
        case failed
    }

    /// The name it owns and holds the audio session under (KadeAudioSession).
    static let sessionName = "Follow along"
    /// The name it holds the microphone lane under (KadeAudioLanes).
    static let laneName = "Follow along"

    @Published private(set) var phase: Phase = .closed
    /// The last thing said (the sheet shows it; it is not a live region).
    @Published private(set) var status = FollowWords.ready
    /// The words being spoken now, for anyone watching with her.
    @Published private(set) var nowSaying = ""
    @Published private(set) var descriptionsOn = true
    @Published private(set) var trackTitle = ""
    @Published private(set) var trackWarning: String?
    /// The recorded narrator needs a track that carries clips; none do yet.
    @Published private(set) var narratorAvailable = false
    @Published var settings = FollowAlongSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            loop?.update(settings: settings)
            updateRoute()
        }
    }

    private(set) var report = FollowReport()
    private var stored: FollowStoredTrack?
    private var loop: FollowAlongLoop?
    private let queue = DispatchQueue(label: "com.kademurdock.kadeai.followAlong", qos: .userInitiated)
    private let gate = FollowSpeechGate()
    private var engine: AVAudioEngine?
    private var chimeNode: AVAudioPlayerNode?
    private var capture: FollowAlongCapture?
    private var speaker: AVSpeechSynthesizer?
    private var current: AVSpeechUtterance?
    private var saying: Saying?
    private var sayingStarted: Double?
    private var pendingSentence: (text: String, sound: FollowSoundKind?, stops: Bool)?
    private var flushTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var stopSafety: Task<Void, Never>?
    private var holdsSession = false
    private var holdsLane = false
    private var closeWhenStopped = false
    private var observers: [NSObjectProtocol] = []
    private var focusObserver: NSObjectProtocol?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var batteryStart: Double?
    private var language = "en"
    /// Stops the other sounds of the screen that opened it (listen-while-made, a voice sample).
    private var stopOthers: (() -> Void)?

    private enum Saying: Equatable {
        case sentence(stops: Bool)
        case cue(String)
    }

    deinit {
        let lane = holdsLane
        let session = holdsSession
        if lane || session {
            Task { @MainActor in
                if lane { KadeAudioLanes.endRecording(FollowAlongPlayer.laneName) }
                if session { KadeAudioSession.shared.handBack(FollowAlongPlayer.sessionName) }
            }
        }
    }

    // MARK: Opening and closing (the sheet)

    /// The sheet opened on `item`: read it and build the matcher now, so
    /// Start listening is instant.
    func open(_ item: FollowStoredTrack, stopOthers: @escaping () -> Void) {
        self.stopOthers = stopOthers
        if stored?.id == item.id, phase != .closed, phase != .failed { return }
        if phase == .listening || phase == .stopping { return }
        stored = item
        trackTitle = item.title
        trackWarning = nil
        phase = .preparing
        status = FollowWords.preparing
        nowSaying = ""
        descriptionsOn = true
        report = FollowReport()
        loop?.release()
        let made = FollowAlongLoop(queue: queue, gate: gate, deliver: Self.deliverer(to: self))
        loop = made
        watchVoiceOver()
        let settingsNow = settings
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> (track: Data, print: Data)? in
                try? FollowAlongStore.files(of: item)
            }.value
            guard self.stored?.id == item.id, self.loop === made else { return }
            guard let files = loaded else {
                self.fail(FollowWords.damagedOnPhone, phase: .failed)
                return
            }
            made.prepare(trackData: files.track, print: files.print, settings: settingsNow)
        }
    }

    /// The sheet is closing. Listening stops first (with its sentence), so
    /// the microphone is never left on behind a closed screen.
    func close() {
        switch phase {
        case .listening:
            closeWhenStopped = true
            stop()
        case .stopping:
            closeWhenStopped = true
        default:
            finishClose()
        }
    }

    private func finishClose() {
        loop?.release()
        loop = nil
        stored = nil
        phase = .closed
        status = FollowWords.ready
        nowSaying = ""
        stopOthers = nil
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
    }

    /// Made where no actor is assumed: the loop calls it on its own queue,
    /// and the main queue keeps the order.
    nonisolated private static func deliverer(to player: FollowAlongPlayer) -> (FollowLoopOutput) -> Void {
        { [weak player] output in
            DispatchQueue.main.async { [weak player] in
                MainActor.assumeIsolated { player?.handle(output) }
            }
        }
    }

    // MARK: Her buttons

    /// The big button: Start listening, Pause descriptions, Turn descriptions
    /// on, Listen again, or Open Settings.
    func mainButton() async {
        switch phase {
        case .ready, .stoppedByCall:
            await start()
        case .listening:
            toggleDescriptions()
        case .micDenied:
            openSettings()
        default:
            break
        }
    }

    func start() async {
        guard phase == .ready || phase == .stoppedByCall || phase == .micDenied, loop != nil else { return }
        noteVoiceOver()
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .denied:
            showMicDenied()
            return
        case .undetermined:
            let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                session.requestRecordPermission { allowed in continuation.resume(returning: allowed) }
            }
            guard granted else {
                showMicDenied()
                return
            }
        case .granted:
            break
        @unknown default:
            break
        }
        // She may have closed the sheet while the phone asked.
        guard phase == .ready || phase == .stoppedByCall || phase == .micDenied, let loop else { return }
        if KadeAudioLanes.duplexActive {
            fail(FollowWords.micBusy, phase: .ready)
            return
        }
        // Everything else stops first: the film player and listen-while-made
        // (the screen's own), the Library, and chat speech (claiming the lane
        // stops every voice at once).
        stopOthers?()
        LibraryNowPlaying.shared.pauseForOtherAudio("Follow along")
        KadeAudioLanes.beginRecording(Self.laneName)
        holdsLane = true
        do {
            try KadeAudioSession.setCategory(for: .followAlong)
            try session.setActive(true)
        } catch {
            KadeBreadcrumbs.drop("follow along: the session would not start: \(error.localizedDescription)")
            releaseLane()
            fail(FollowWords.micBusy, phase: .ready)
            return
        }
        KadeAudioSession.shared.take(Self.sessionName)
        KadeAudioSession.shared.hold(Self.sessionName)
        holdsSession = true
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        guard usePhoneMicrophone(session) else {
            tearDown()
            fail(FollowWords.notPhoneMic, phase: .ready)
            return
        }
        guard startEngine(loop: loop) else {
            tearDown()
            fail(FollowWords.couldNotStart, phase: .ready)
            return
        }
        watchSession()
        wireRemote()
        UIDevice.current.isBatteryMonitoringEnabled = true
        let battery = Double(UIDevice.current.batteryLevel)
        batteryStart = battery >= 0 ? battery : nil
        descriptionsOn = true
        phase = .listening
        // The big button's words just changed and VoiceOver reads them.
        noteVoiceOver()
        updateRoute()
        loop.update(settings: settings)
        loop.start(now: FollowClock.now())
        say(FollowWords.listening, sound: nil, stops: false)
        updateNowPlaying()
    }

    func toggleDescriptions() {
        noteVoiceOver()
        setDescriptions(on: !descriptionsOn)
    }

    func whereAmI() {
        guard phase == .listening else { return }
        noteVoiceOver()
        loop?.whereAmI(now: FollowClock.now())
    }

    /// Stop: the microphone goes off at once, then the last sentence.
    func stop(sentence: String = FollowWords.stopped) {
        guard phase == .listening else { return }
        noteVoiceOver()
        stopListening()
        phase = .stopping
        say(sentence, sound: nil, stops: true)
        armStopSafety()
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Back from the Settings app: a microphone she has just allowed makes
    /// the big button Start listening again.
    func appBecameActive() {
        guard phase == .micDenied, AVAudioSession.sharedInstance().recordPermission == .granted else { return }
        phase = .ready
        status = FollowWords.ready
    }

    /// Copy test report: numbers only.
    func copyReport() {
        var copy = report
        copy.nudgeSeconds = settings.nudge
        copy.batteryStart = batteryStart
        let battery = Double(UIDevice.current.batteryLevel)
        if UIDevice.current.isBatteryMonitoringEnabled, battery >= 0 { copy.batteryNow = battery }
        UIPasteboard.general.string = copy.text()
        UIAccessibility.post(notification: .announcement, argument: "Test report copied. It holds numbers only.")
    }

    /// VoiceOver moved, or she pressed a button (VoiceOver may read its new
    /// words): nothing is spoken until VoiceOver has had time to finish.
    func noteVoiceOver() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        gate.voiceOverBusy(until: FollowClock.now() + KadeAudioSessionPolicy.voiceOverSettle)
        if pendingSentence != nil { flushSentence() }
    }

    func setDescriptions(on: Bool, sentence: String? = nil) {
        guard phase == .listening, descriptionsOn != on else { return }
        descriptionsOn = on
        loop?.setDescriptions(on: on)
        if !on, case .cue = saying { speaker?.stopSpeaking(at: .immediate) }
        say(sentence ?? (on ? FollowWords.descriptionsOn : FollowWords.descriptionsPaused), sound: nil, stops: false)
        updateNowPlaying()
    }

    // MARK: What the loop says

    private func handle(_ output: FollowLoopOutput) {
        switch output {
        case .prepared(_, _, let spoken, let warning):
            guard phase == .preparing else { return }
            language = spoken
            trackWarning = warning
            phase = .ready
            status = FollowWords.ready
        case .failed(let words):
            guard phase == .preparing else { return }
            fail(words, phase: .failed)
        case .sentence(let text, let sound, let stops):
            guard phase == .listening else { return }
            if stops {
                stopListening()
                phase = .stopping
                armStopSafety()
            }
            say(text, sound: sound, stops: stops)
        case .speak(let id, let text):
            speakLine(id: id, text: text)
        case .chime:
            guard phase == .listening else { return }
            play(.held)
        case .report(let fresh):
            report = fresh
        case .place(let film):
            guard phase == .listening else { return }
            say(FollowWords.whereAmI(film), sound: nil, stops: false)
        }
    }

    // MARK: Speaking (the phone's own voice: her VoiceOver voice and speed)

    private var soundsOn: Bool {
        settings.soundsOn(soundEffects: FeedbackPrefs.shared.soundEffects)
    }

    private func synthesizer() -> AVSpeechSynthesizer {
        if let speaker { return speaker }
        let made = AVSpeechSynthesizer()
        made.delegate = self
        speaker = made
        return made
    }

    /// A status sentence. It never stacks: a newer one replaces one still
    /// waiting, and it takes over from a description being spoken.
    private func say(_ text: String, sound: FollowSoundKind?, stops: Bool) {
        status = text
        pendingSentence = (text: text, sound: sound, stops: stops)
        // No new line is planned while a sentence waits its turn.
        gate.speaking = true
        if case .cue = saying { speaker?.stopSpeaking(at: .immediate) }
        flushSentence()
    }

    private func flushSentence() {
        guard let pending = pendingSentence, saying == nil else { return }
        let wait = gate.voiceOverQuietAt - FollowClock.now()
        if wait > 0 {
            gate.speaking = true
            scheduleFlush(after: wait)
            return
        }
        pendingSentence = nil
        let kind = Saying.sentence(stops: pending.stops)
        if let sound = pending.sound, soundsOn, phase == .listening, play(sound) {
            // The notes first, then the words.
            saying = kind
            gate.speaking = true
            flushTask?.cancel()
            let delay = FollowSounds.seconds(sound) + 0.08
            flushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled, self.saying == kind, self.current == nil else { return }
                self.startUtterance(pending.text, as: kind)
            }
            return
        }
        startUtterance(pending.text, as: kind)
    }

    private func scheduleFlush(after seconds: Double) {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.flushSentence()
        }
    }

    /// A description line from the planner.
    private func speakLine(id: String, text: String) {
        guard phase == .listening, descriptionsOn, saying == nil, pendingSentence == nil else {
            gate.speaking = saying != nil || pendingSentence != nil
            loop?.finished(cue: id, started: false, seconds: nil, characters: text.count, now: FollowClock.now())
            return
        }
        startUtterance(text, as: .cue(id))
    }

    private func startUtterance(_ text: String, as kind: Saying) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        if let speed = settings.speed {
            // A speed she chose: the phone's standard voice at that speed.
            utterance.prefersAssistiveTechnologySettings = false
            utterance.rate = FollowAlongSettings.speechRate(for: speed, usual: AVSpeechUtteranceDefaultSpeechRate,
                                                            slowest: AVSpeechUtteranceMinimumSpeechRate,
                                                            fastest: AVSpeechUtteranceMaximumSpeechRate)
        } else {
            // Her decision: with VoiceOver on, its voice and its speed.
            utterance.prefersAssistiveTechnologySettings = true
        }
        current = utterance
        saying = kind
        sayingStarted = nil
        gate.speaking = true
        nowSaying = text
        synthesizer().speak(utterance)
        armWatchdog(for: utterance, characters: text.count)
    }

    /// Speech that never reports its end (reported on some phones when the
    /// screen locks) must not hold everything up.
    private func armWatchdog(for utterance: AVSpeechUtterance, characters: Int) {
        watchdog?.cancel()
        let id = ObjectIdentifier(utterance)
        let limit = 8 + Double(characters) * 0.15
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            KadeBreadcrumbs.drop("follow along: speech did not report its end; moved on")
            self.speaker?.stopSpeaking(at: .immediate)
            self.utteranceEnded(id, at: FollowClock.now(), cancelled: true)
        }
    }

    fileprivate func utteranceStarted(_ id: ObjectIdentifier, at time: Double) {
        guard let utterance = current, ObjectIdentifier(utterance) == id else { return }
        sayingStarted = time
        loop?.soundStarted(at: time, until: nil)
    }

    fileprivate func utteranceEnded(_ id: ObjectIdentifier, at time: Double, cancelled: Bool) {
        guard let utterance = current, ObjectIdentifier(utterance) == id, let kind = saying else { return }
        let characters = utterance.speechString.count
        let began = sayingStarted
        current = nil
        saying = nil
        sayingStarted = nil
        watchdog?.cancel()
        nowSaying = ""
        gate.speaking = false
        if began != nil { loop?.soundEnded(at: time) }
        let seconds = began.map { time - $0 }
        switch kind {
        case .cue(let cueId):
            loop?.finished(cue: cueId, started: began != nil, seconds: cancelled ? nil : seconds, characters: characters, now: time)
        case .sentence(let stops):
            if !cancelled, let seconds { loop?.sentenceSpoken(characters: characters, seconds: seconds) }
            if stops {
                finishStop()
                return
            }
        }
        flushSentence()
    }

    // MARK: Sounds (in the engine, on the same session)

    private static let soundFormat = AVAudioFormat(standardFormatWithSampleRate: Double(FollowSounds.sampleRate), channels: 1)
    private static var soundBuffers: [FollowSoundKind: AVAudioPCMBuffer] = [:]

    private static func buffer(for kind: FollowSoundKind) -> AVAudioPCMBuffer? {
        if let made = soundBuffers[kind] { return made }
        let samples = FollowSounds.samples(kind)
        guard let format = soundFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { channels[0][index] = Float(sample) / 32768 }
        soundBuffers[kind] = buffer
        return buffer
    }

    /// True when it played.
    @discardableResult
    private func play(_ kind: FollowSoundKind) -> Bool {
        guard let engine, engine.isRunning, let node = chimeNode, let buffer = Self.buffer(for: kind) else { return false }
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !node.isPlaying { node.play() }
        let now = FollowClock.now()
        loop?.soundStarted(at: now, until: now + FollowSounds.seconds(kind) + 0.1)
        return true
    }

    // MARK: The microphone

    private func usePhoneMicrophone(_ session: AVAudioSession) -> Bool {
        if let phoneMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(phoneMic)
        }
        return session.currentRoute.inputs.contains { $0.portType == .builtInMic }
    }

    private func startEngine(loop: FollowAlongLoop) -> Bool {
        let made = AVAudioEngine()
        let input = made.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let fresh = FollowAlongCapture(from: format, loop: loop) else { return false }
        Self.installTap(on: input, format: format, capture: fresh)
        let node = AVAudioPlayerNode()
        made.attach(node)
        if let soundFormat = Self.soundFormat {
            made.connect(node, to: made.mainMixerNode, format: soundFormat)
        }
        made.prepare()
        do {
            try made.start()
        } catch {
            input.removeTap(onBus: 0)
            KadeBreadcrumbs.drop("follow along: the microphone would not start: \(error.localizedDescription)")
            return false
        }
        engine = made
        chimeNode = node
        capture = fresh
        return true
    }

    /// Made where no actor is assumed: the tap runs on its own thread.
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, capture: FollowAlongCapture) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            capture.take(buffer, at: when)
        }
    }

    /// The route changed (earbuds in or out) or the hardware rate moved: the
    /// engine stopped itself, so the tap is made again for the new sound.
    private func engineChanged() {
        guard phase == .listening, let engine, let loop else { return }
        engine.inputNode.removeTap(onBus: 0)
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let fresh = FollowAlongCapture(from: format, loop: loop) else {
            stopForProblem("the microphone changed and could not be read")
            return
        }
        capture = fresh
        Self.installTap(on: engine.inputNode, format: format, capture: fresh)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopForProblem("the microphone would not start again: \(error.localizedDescription)")
            return
        }
        updateRoute()
    }

    /// Where the sound goes: the output delay (Bluetooth arrives late, so
    /// lines start that much early, plus her nudge), and whether the
    /// microphone can hear the phone (its own speaker).
    private func updateRoute() {
        guard phase == .listening else { return }
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        let onPhoneSpeaker = outputs.isEmpty || outputs.contains { $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver }
        let delay = max(0, min(0.5, session.outputLatency + session.ioBufferDuration))
        loop?.update(lead: delay + settings.nudge, outputDelay: delay, echoRisk: onPhoneSpeaker)
    }

    private static let personalOutputs: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE]

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?, previous: AVAudioSessionRouteDescription?) {
        guard phase == .listening else { return }
        updateRoute()
        // Earbuds gone: descriptions pause; they never jump to the loudspeaker by themselves.
        if reason == .oldDeviceUnavailable, descriptionsOn, let previous,
           previous.outputs.contains(where: { Self.personalOutputs.contains($0.portType) }) {
            setDescriptions(on: false, sentence: FollowWords.earbudsGone)
        }
        let session = AVAudioSession.sharedInstance()
        if !session.currentRoute.inputs.contains(where: { $0.portType == .builtInMic }), !usePhoneMicrophone(session) {
            stop(sentence: FollowWords.notPhoneMic)
        }
    }

    // MARK: Calls and other interruptions

    private func interrupted(_ type: AVAudioSession.InterruptionType?) {
        guard let type else { return }
        switch type {
        case .began:
            if phase == .stopping {
                speaker?.stopSpeaking(at: .immediate)
                finishStop()
                return
            }
            guard phase == .listening else { return }
            // Speech stops at once. Nothing resumes by itself (her Library rule).
            speaker?.stopSpeaking(at: .immediate)
            stopListening()
            handBackSession()
            phase = .stoppedByCall
            status = FollowWords.stoppedByCall
            KadeBreadcrumbs.drop("follow along: stopped by an interruption")
            if UIApplication.shared.applicationState != .active { notifyCall(active: false) }
        case .ended:
            guard phase == .stoppedByCall else { return }
            if UIApplication.shared.applicationState != .active { notifyCall(active: true) }
        @unknown default:
            break
        }
    }

    /// "Follow along stopped for a call. Open Kade-AI to carry on." Quietly
    /// while the call is on (it waits in Notification Centre), then once more,
    /// with a sound, when the call ends and the app is still away.
    private func notifyCall(active: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Follow along"
        content.body = FollowWords.callNotification
        content.interruptionLevel = active ? .active : .passive
        if active { content.sound = .default }
        let request = UNNotificationRequest(identifier: "kade.followAlong.call", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func stopForProblem(_ why: String) {
        guard phase == .listening else { return }
        KadeBreadcrumbs.drop("follow along: stopped: \(why)")
        stop(sentence: FollowWords.stoppedForProblem)
    }

    // MARK: Watching the session, VoiceOver and the buttons

    private func watchSession() {
        unwatchSession()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let type = AVAudioSession.InterruptionType(rawValue: raw)
            MainActor.assumeIsolated { self?.interrupted(type) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            MainActor.assumeIsolated { self?.routeChanged(reason, previous: previous) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopForProblem("the phone's media services were reset") }
        })
        if let engine {
            observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engineChanged() }
            })
        }
    }

    private func unwatchSession() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func watchVoiceOver() {
        guard focusObserver == nil else { return }
        focusObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.elementFocusedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteVoiceOver() }
        }
    }

    /// The lock screen and earbud buttons pause and resume the descriptions.
    private func wireRemote() {
        unwireRemote()
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        remoteTargets.append((center.playCommand, center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.setDescriptions(on: true) }
            return .success
        }))
        center.pauseCommand.isEnabled = true
        remoteTargets.append((center.pauseCommand, center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.setDescriptions(on: false) }
            return .success
        }))
        center.togglePlayPauseCommand.isEnabled = true
        remoteTargets.append((center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.setDescriptions(on: !self.descriptionsOn)
            }
            return .success
        }))
    }

    /// Removes only these targets, never another player's.
    private func unwireRemote() {
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets = []
    }

    private func updateNowPlaying() {
        guard phase == .listening else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: trackTitle,
            MPMediaItemPropertyArtist: "Following along, described by Kade-AI",
            MPNowPlayingInfoPropertyPlaybackRate: descriptionsOn ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
    }

    // MARK: Stopping

    /// The microphone, the engine, the lane and the buttons go now. The
    /// session stays held until the last sentence has been said.
    private func stopListening() {
        loop?.stop()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            chimeNode?.stop()
            engine.stop()
        }
        engine = nil
        chimeNode = nil
        capture = nil
        releaseLane()
        unwatchSession()
        unwireRemote()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        pendingSentence = nil
        flushTask?.cancel()
        if current == nil, saying != nil {
            // A sentence still waiting for its notes never started: let it go.
            saying = nil
        }
        if saying != nil {
            speaker?.stopSpeaking(at: .immediate)
        } else {
            gate.speaking = false
        }
        let battery = Double(UIDevice.current.batteryLevel)
        if UIDevice.current.isBatteryMonitoringEnabled, battery >= 0 { report.batteryNow = battery }
        UIDevice.current.isBatteryMonitoringEnabled = false
        descriptionsOn = true
    }

    /// If the last sentence never gets said, the session is handed back anyway.
    private func armStopSafety() {
        stopSafety?.cancel()
        stopSafety = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !Task.isCancelled, self.phase == .stopping else { return }
            self.speaker?.stopSpeaking(at: .immediate)
            self.finishStop()
        }
    }

    private func finishStop() {
        stopSafety?.cancel()
        watchdog?.cancel()
        flushTask?.cancel()
        current = nil
        saying = nil
        pendingSentence = nil
        gate.speaking = false
        nowSaying = ""
        handBackSession()
        if closeWhenStopped {
            closeWhenStopped = false
            finishClose()
        } else if phase == .stopping {
            phase = .ready
        }
    }

    /// A start that failed after it took the session.
    private func tearDown() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        chimeNode = nil
        capture = nil
        releaseLane()
        handBackSession()
    }

    private func handBackSession() {
        guard holdsSession else { return }
        holdsSession = false
        KadeAudioSession.shared.handBack(Self.sessionName)
    }

    private func releaseLane() {
        guard holdsLane else { return }
        holdsLane = false
        KadeAudioLanes.endRecording(Self.laneName)
    }

    private func showMicDenied() {
        phase = .micDenied
        status = FollowWords.micDenied
        UIAccessibility.post(notification: .announcement, argument: FollowWords.micDenied)
    }

    private func fail(_ words: String, phase next: Phase) {
        phase = next
        status = words
        UIAccessibility.post(notification: .announcement, argument: words)
    }
}

// The phone's speech engine reports here, on its own thread.
extension FollowAlongPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        let time = FollowClock.now()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.utteranceStarted(id, at: time) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        let time = FollowClock.now()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.utteranceEnded(id, at: time, cancelled: false) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        let time = FollowClock.now()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.utteranceEnded(id, at: time, cancelled: true) }
        }
    }
}
