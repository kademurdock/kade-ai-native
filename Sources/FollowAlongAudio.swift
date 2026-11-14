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
// - FollowAlongPlayer (here, main thread) owns the audio session, the
//   microphone engine, the speech engine, the lock screen and earbud
//   buttons, calls and route changes. The sheet (FollowAlongView.swift)
//   shows it.
// - FollowAlongCapture (FollowAlongCapture.swift) turns the microphone's
//   sound into 8 kHz mono on the tap's own thread and hands it to the loop.
// - FollowAlongLoop (FollowAlongLoop.swift) runs on ONE background queue:
//   the 16-second memory, the matcher (FollowAlongEngine, the one doorway to
//   syncprint.js), the rules (FollowJudge) and the planner. The schedule runs
//   from the arrival of microphone sound, not from a timer: sound keeps
//   arriving with the phone locked, timers may not fire.
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
    /// The call notification's one identifier: a newer one replaces it.
    static let callNotice = "kade.followAlong.call"
    /// The microphone engine rebuilt this many times within 10 seconds means
    /// something keeps changing under it: Follow along stops instead.
    static let mostRebuilds = 5

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
    /// A track opened again while the last sentence was being said: it gets
    /// ready once that sentence is done.
    private var reopen: FollowStoredTrack?
    private var loop: FollowAlongLoop?
    /// Which loop's answers count. A loop that was let go (another track, a
    /// closed sheet) may still answer from its queue; those answers are dropped.
    private var generation = 0
    private let queue = DispatchQueue(label: "com.kademurdock.kadeai.followAlong", qos: .userInitiated)
    private let gate = FollowSpeechGate()
    private var engine: AVAudioEngine?
    private var chimeNode: AVAudioPlayerNode?
    private var capture: FollowAlongCapture?
    /// When the microphone engine was rebuilt lately (earbuds in or out).
    private var rebuilds: [Double] = []
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
    /// Route changes and media resets: only while listening.
    private var observers: [NSObjectProtocol] = []
    /// The microphone engine's own configuration changes.
    private var engineObserver: NSObjectProtocol?
    /// Calls: for as long as the sheet is open, so the end of a call is heard
    /// too (Nov 14 review: this went with the microphone, so a call's end
    /// never reached the app).
    private var callObserver: NSObjectProtocol?
    private var focusObserver: NSObjectProtocol?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    /// The battery when this track first started listening.
    private var batteryStart: Double?
    /// The battery when listening stopped: the phone stops measuring it then.
    private var batteryAtStop: Double?
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
        watchVoiceOver()
        watchCalls()
        switch phase {
        case .stopping:
            // Opened again while the last sentence is said (Done, then the
            // button again): the sheet stays open, and this track gets ready
            // when the sentence is done (Nov 14 review: the sheet was left on
            // "Getting ready" for good).
            closeWhenStopped = false
            reopen = item
            return
        case .listening:
            return
        default:
            break
        }
        if stored?.id == item.id, phase != .closed, phase != .failed { return }
        prepare(item)
    }

    /// Reads the track and builds a fresh loop for it.
    private func prepare(_ item: FollowStoredTrack) {
        stored = item
        trackTitle = item.title
        trackWarning = nil
        phase = .preparing
        status = FollowWords.preparing
        nowSaying = ""
        descriptionsOn = true
        report = FollowReport()
        batteryStart = nil
        batteryAtStop = nil
        loop?.release()
        generation &+= 1
        let made = FollowAlongLoop(queue: queue, gate: gate, clock: FollowClock.now, trail: KadeBreadcrumbs.drop,
                                   deliver: Self.deliverer(to: self, generation: generation))
        loop = made
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
        reopen = nil
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
        // Anything the old loop still says is not for the next sheet.
        generation &+= 1
        stored = nil
        reopen = nil
        phase = .closed
        status = FollowWords.ready
        nowSaying = ""
        stopOthers = nil
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
        unwatchCalls()
        forgetCallNotice()
    }

    /// Made where no actor is assumed: the loop calls it on its own queue,
    /// and the main queue keeps the order. Each answer carries the loop it
    /// came from.
    nonisolated private static func deliverer(to player: FollowAlongPlayer, generation: Int) -> (FollowLoopOutput) -> Void {
        { [weak player] output in
            DispatchQueue.main.async { [weak player] in
                MainActor.assumeIsolated { player?.handle(output, from: generation) }
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
        rebuilds = []
        guard startEngine(loop: loop) else {
            tearDown()
            fail(FollowWords.couldNotStart, phase: .ready)
            return
        }
        watchSession()
        watchEngine()
        wireRemote()
        forgetCallNotice()
        UIDevice.current.isBatteryMonitoringEnabled = true
        let battery = Double(UIDevice.current.batteryLevel)
        // The minutes in the report add up every run on this track, so the
        // battery is counted from the first run too.
        if batteryStart == nil, battery >= 0 { batteryStart = battery }
        batteryAtStop = nil
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

    /// Copy test report: numbers only. After Stop the phone no longer
    /// measures the battery, so the level from when listening stopped is
    /// used (Nov 14 review: it went missing from every report after Stop).
    func copyReport() {
        let battery = Double(UIDevice.current.batteryLevel)
        let live: Double? = UIDevice.current.isBatteryMonitoringEnabled && battery >= 0 ? battery : nil
        let copy = report.copied(nudge: settings.nudge, batteryStart: batteryStart, batteryNow: live, batteryAtStop: batteryAtStop)
        UIPasteboard.general.string = copy.text()
        announce("Test report copied. It holds numbers only.")
    }

    /// She pressed a button (VoiceOver may read its new words): nothing is
    /// spoken for a moment.
    func noteVoiceOver() {
        holdForVoiceOver(KadeAudioSessionPolicy.voiceOverSettle)
    }

    /// VoiceOver landed on something: nothing is spoken until it has read it
    /// out, its label and then its hint, at her own voice's speed (Nov 14
    /// review: a flat 1.5 seconds was shorter than a hint).
    private func voiceOverLanded(on element: Any?) {
        let item = element as? NSObject
        let seconds = FollowVoiceOverTime.reading(label: item?.accessibilityLabel, value: item?.accessibilityValue,
                                                  hint: item?.accessibilityHint, secPerChar: voiceOverPace)
        holdForVoiceOver(seconds)
    }

    /// One of the app's own VoiceOver announcements: nothing else is spoken
    /// while VoiceOver says it.
    private func announce(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
        holdForVoiceOver(FollowVoiceOverTime.announcement(text, secPerChar: voiceOverPace))
    }

    private func holdForVoiceOver(_ seconds: Double) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        gate.voiceOverBusy(until: FollowClock.now() + seconds)
        if pendingSentence != nil { flushSentence() }
    }

    /// Her VoiceOver voice's seconds per letter, as Follow along measured it:
    /// its own lines use her VoiceOver voice and speed, unless she chose a
    /// speed of her own (then the usual guess).
    private var voiceOverPace: Double {
        settings.speed == nil ? (report.secondsPerLetter ?? FollowPace.fallback) : FollowPace.fallback
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

    private func handle(_ output: FollowLoopOutput, from sender: Int) {
        // A loop already let go answers nothing here (Nov 14 review: a late
        // "ready" from the last track could make this sheet ready on the
        // wrong track, with the microphone on and nothing listening).
        guard sender == generation else { return }
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

    /// A fresh engine: its tap on the microphone, and the node for the little
    /// sounds. Used at Start and again whenever the hardware changes.
    private func startEngine(loop: FollowAlongLoop) -> Bool {
        let made = AVAudioEngine()
        let input = made.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let fresh = FollowAlongCapture(from: format, sink: loop) else { return false }
        Self.installTap(on: input, capture: fresh)
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

    /// Made where no actor is assumed: the tap runs on its own thread. The
    /// tap takes the microphone's own format (format nil): a format read a
    /// moment before the hardware changed would stop the app, and the
    /// capture adapts to whatever format arrives (Nov 14 review).
    nonisolated private static func installTap(on input: AVAudioInputNode, capture: FollowAlongCapture) {
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, when in
            capture.take(buffer, at: when)
        }
    }

    /// The engine, its tap and its node go.
    private func dropEngine() {
        unwatchEngine()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            chimeNode?.stop()
            engine.stop()
        }
        engine = nil
        chimeNode = nil
        capture = nil
    }

    /// The route changed (earbuds in or out) or the hardware rate moved: the
    /// engine stopped itself, and its formats may no longer agree, so a bare
    /// restart can fail (StreamingCallService found it throws). A fresh
    /// engine is built instead, from the hardware as it is now (Nov 14
    /// review).
    private func engineChanged() {
        guard phase == .listening, let loop else { return }
        let now = FollowClock.now()
        rebuilds = rebuilds.filter { now - $0 < 10 } + [now]
        dropEngine()
        guard rebuilds.count < Self.mostRebuilds, startEngine(loop: loop) else {
            stopForProblem("the microphone could not start again after the hardware changed")
            return
        }
        watchEngine()
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
            // Heard because calls are watched for as long as the sheet is
            // open, not only while the microphone is on.
            guard phase == .stoppedByCall else { return }
            if UIApplication.shared.applicationState != .active { notifyCall(active: true) }
        @unknown default:
            break
        }
    }

    /// "Follow along stopped for a call. Open Kade-AI to carry on." Quietly
    /// while the call is on (it waits in Notification Centre), then once more,
    /// with a sound, when the call ends and the app is still away. Only when
    /// notifications are already allowed; this never asks.
    private func notifyCall(active: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Follow along"
        content.body = FollowWords.callNotification
        content.interruptionLevel = active ? .active : .passive
        if active { content.sound = .default }
        let request = UNNotificationRequest(identifier: Self.callNotice, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Listening again, or the sheet closed: the call notification is old news.
    private func forgetCallNotice() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.callNotice])
    }

    private func stopForProblem(_ why: String) {
        guard phase == .listening else { return }
        KadeBreadcrumbs.drop("follow along: stopped: \(why)")
        stop(sentence: FollowWords.stoppedForProblem)
    }

    // MARK: Watching the session, calls, VoiceOver and the buttons

    /// Route changes and media resets, while listening.
    private func watchSession() {
        unwatchSession()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            MainActor.assumeIsolated { self?.routeChanged(reason, previous: previous) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopForProblem("the phone's media services were reset") }
        })
    }

    private func unwatchSession() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    /// The engine's configuration changes, for the engine running now.
    private func watchEngine() {
        unwatchEngine()
        guard let engine else { return }
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engineChanged() }
        }
    }

    private func unwatchEngine() {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
    }

    /// Calls, for as long as the sheet is open: the start of a call stops
    /// listening, and the end of the call must still be heard, for the
    /// notification with a sound (design 5.3 item 16).
    private func watchCalls() {
        guard callObserver == nil else { return }
        callObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let type = AVAudioSession.InterruptionType(rawValue: raw)
            MainActor.assumeIsolated { self?.interrupted(type) }
        }
    }

    private func unwatchCalls() {
        if let callObserver { NotificationCenter.default.removeObserver(callObserver) }
        callObserver = nil
    }

    private func watchVoiceOver() {
        guard focusObserver == nil else { return }
        focusObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.elementFocusedNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.voiceOverLanded(on: note.userInfo?[UIAccessibility.focusedElementUserInfoKey]) }
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
    /// session stays held until the last sentence has been said. Calls stay
    /// watched (the sheet is still open).
    private func stopListening() {
        loop?.stop()
        dropEngine()
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
        if UIDevice.current.isBatteryMonitoringEnabled, battery >= 0 { batteryAtStop = battery }
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
        // The sheet was opened again while the sentence was said: the same
        // track is ready as it is; another one gets ready now.
        if let item = reopen {
            reopen = nil
            if stored?.id != item.id || loop == nil || phase != .ready { prepare(item) }
        }
    }

    /// A start that failed after it took the session.
    private func tearDown() {
        dropEngine()
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
        announce(FollowWords.micDenied)
    }

    private func fail(_ words: String, phase next: Phase) {
        phase = next
        status = words
        announce(words)
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
