import SwiftUI
import UIKit
import WebKit
import AVFoundation
import CallKit

// MARK: - THE GAME COVER (Oct 18 2026, Milestone 1)
//
// One full-screen cover per game (never a new navigationDestination: the
// build-121 rule). It holds:
//   - a top strip of ordinary VoiceOver buttons: Leave game, Pause, Status,
//     Repeat, Settings. Magic tap pauses; the escape scrub asks
//     "Leave game?". Exit always lives here, because VoiceOver gestures do not
//     work inside the direct-touch pad;
//   - the game page in a WKWebView, served from the downloaded packs by
//     ArcadeSchemeHandler, hidden from VoiceOver (the page speaks through its
//     own cloned voice, and lines with no clip come back here as VoiceOver
//     announcements, or AVSpeechSynthesizer with VoiceOver off);
//   - the game pad (ArcadeTouchPad.swift) over everything below the strip.
// The host keeps the page's contract (Revival kit core/host.js and app.js):
// window.revivalKitHost is injected at document start; the app drives
// window.revivalKit (pad, info, press, setMode, suspend, resume) only through
// evaluateJavaScript, and only when something changed.

private enum ArcadeKeysStore {
    static let picture = "kade.arcade.showPicture"
    static let haptics = "kade.arcade.haptics"
    static let readAll = "kade.arcade.voiceOverReadsAll"
}

// MARK: - Before the game starts

/// A phone call owns the audio: the game waits. The app's own live audio
/// needs no check here: a Clubhouse room is left when its screen closes and
/// a voice call is a cover of its own, so neither can be live under the
/// Arcade list. The shared session's category is no guide either: it can
/// stay .playAndRecord after a Clubhouse room has closed, which would warn
/// about a microphone nobody is using.
enum ArcadeAudioGuard {
    enum Verdict { case clear, call }

    @MainActor
    static func check() -> Verdict {
        CXCallObserver().calls.contains(where: { !$0.hasEnded }) ? .call : .clear
    }
}

/// Whether a system call is active (WorldService's WorldPhoneCalls, again,
/// because that one is private to the World).
@MainActor
final class ArcadeCallWatch: NSObject, CXCallObserverDelegate {
    private let observer: CXCallObserver
    private(set) var active = false
    var onChange: (@MainActor (Bool) -> Void)?

    override init() {
        observer = CXCallObserver()
        super.init()
        active = observer.calls.contains { !$0.hasEnded }
        observer.setDelegate(self, queue: .main)
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        // Use the changed call itself when the observer's list is a tick behind.
        let uuid = call.uuid
        let next = !call.hasEnded || callObserver.calls.contains { $0.uuid != uuid && !$0.hasEnded }
        Task { @MainActor in self.update(next) }
    }

    private func update(_ next: Bool) {
        guard next != active else { return }
        active = next
        onChange?(next)
    }
}

/// The game's audio session: .playback with .mixWithOthers, so the game never
/// ducks VoiceOver and the ring switch never mutes it. The handling copies
/// WorldService's standing lesson: interruptions (including the late
/// "app was suspended" notice that never gets an end), route changes
/// (headphones gone), category changes (someone else took the shared
/// session) and media-services resets.
@MainActor
final class ArcadeAudioSession {
    var onInterruption: (@MainActor (Bool) -> Void)?
    var onRouteLost: (@MainActor () -> Void)?
    var onReset: (@MainActor () -> Void)?
    /// How often the session had to be taken back (WebKit or another lane changed it).
    private(set) var reasserted = 0
    private var reassertTimes: [Date] = []
    private var observers: [NSObjectProtocol] = []

    @discardableResult
    func activate() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playback || !session.categoryOptions.contains(.mixWithOthers) {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
            return true
        } catch {
            return false
        }
    }

    func start() {
        activate()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
                let wasSuspended = (note.userInfo?["AVAudioSessionInterruptionWasSuspendedKey"] as? Bool) ?? false
                Task { @MainActor in self?.interruption(raw: raw, reason: reason, wasSuspended: wasSuspended) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
                let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor in self?.routeChanged(reason: reason) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.activate()
                    self?.onReset?()
                }
            },
        ]
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func interruption(raw: UInt?, reason: UInt?, wasSuspended: Bool) {
        guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            // Reason 1 is .appWasSuspended (deprecated, so matched by value):
            // it arrives late, on the way back, and never ends. Not a real one.
            if reason == 1 || wasSuspended {
                activate()
                onInterruption?(false)
                return
            }
            onInterruption?(true)
        } else {
            activate()
            onInterruption?(false)
        }
    }

    private func routeChanged(reason: UInt?) {
        if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
            onRouteLost?()
            return
        }
        if reason == AVAudioSession.RouteChangeReason.categoryChange.rawValue {
            // Take the session back, but never fight more than three times a
            // minute (WebKit may set its own category for web audio).
            let now = Date()
            reassertTimes = reassertTimes.filter { now.timeIntervalSince($0) < 60 }
            guard reassertTimes.count < 3 else { return }
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback || !session.categoryOptions.contains(.mixWithOthers) {
                reassertTimes.append(now)
                reasserted += 1
                activate()
            }
        }
    }
}

// MARK: - The page bridge

/// WKUserContentController keeps its handlers strongly; this keeps the host
/// collectable (ClubhouseEngine's WeakScriptHandler, again).
private final class ArcadeScriptRelay: NSObject, WKScriptMessageHandler {
    weak var host: ArcadeGameHost?
    init(_ host: ArcadeGameHost) { self.host = host }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in
            self.host?.receive(message.body)
        }
    }
}

// MARK: - The host

@MainActor
final class ArcadeGameHost: NSObject, ObservableObject, WKNavigationDelegate {
    /// A short line for sighted family; VoiceOver hears it as the Status button's value.
    @Published private(set) var status = "Opening the game"
    @Published private(set) var mode = "menu"
    /// Set when the page kept stopping and the host gave up restarting it.
    @Published private(set) var stopped: String?
    /// "Leave game?" is up. Asked mid-fight, the game pauses first.
    @Published var askingLeave = false {
        didSet { if askingLeave && !oldValue { pauseIfFighting() } }
    }
    @Published var showPicture: Bool {
        didSet { UserDefaults.standard.set(showPicture, forKey: ArcadeKeysStore.picture) }
    }
    @Published var hapticsOn: Bool {
        didSet {
            UserDefaults.standard.set(hapticsOn, forKey: ArcadeKeysStore.haptics)
            pad?.hapticsOn = hapticsOn
        }
    }
    @Published var voiceOverReadsAll: Bool {
        didSet {
            UserDefaults.standard.set(voiceOverReadsAll, forKey: ArcadeKeysStore.readAll)
            evaluate(ArcadeJS.setMode(voiceOverReadsAll ? "native" : defaultSpeechMode))
        }
    }

    let launch: ArcadeLaunch
    private(set) var telemetry = ArcadeTelemetry()
    private var webView: WKWebView?
    private var schemeHandler: ArcadeSchemeHandler?
    private weak var pad: ArcadeTouchPadView?
    private let input: ArcadeInput
    private let audio: ArcadeAudioSession
    private let calls: ArcadeCallWatch
    private var speaker: AVSpeechSynthesizer?
    private var touchTable = ArcadeTouchTable.standard
    private var gamepadMap = ArcadeGamepadMap.standard
    /// The plain player's own words for its touch controls (systems.json help.touch).
    private var playHint: String?
    private var defaultSpeechMode = "clone"
    private var lastSent: [String: String] = [:]
    private var terminations: [Date] = []
    private var observers: [NSObjectProtocol] = []
    private var begun = false
    private var ended = false
    private var suspended = false
    /// The game's own save file, kept between pages and plays (ArcadeSaveStore).
    private let saves: ArcadeSaveStore?
    /// The input the page names buttons for ('touch', 'gamepad', 'keyboard').
    private var pageInputType: String?
    private var lastWake: Date?
    /// The page's process ended while she was away: restart it when she is back.
    private var needsReload = false
    /// The fight was paused because she went away (a call, Control Center, another app).
    private var pausedForAway = false
    private var suspendToken = 0
    /// Leaving waits (briefly) for the game's save.
    private var leaveWaiter: (() -> Void)?
    /// Oct 19 2026: every start is watched, so a stall is never silent
    /// (ArcadeStartWatch; build 340 sat at "Starting the emulator" for good).
    private var startWatch = ArcadeStartWatch()
    /// The current page load, so a failure of an older one is told apart.
    private var pageNavigation: WKNavigation?
    /// Oct 19 2026: the game's Settings sheet is up (and with it Report a
    /// problem's text field), so a keyboard's presses are typing, not play:
    /// no key goes down in the game and Escape does not ask to leave.
    /// Releases still pass, so nothing stays held.
    var keysElsewhere = false

    init(launch: ArcadeLaunch) {
        self.launch = launch
        let defaults = UserDefaults.standard
        showPicture = (defaults.object(forKey: ArcadeKeysStore.picture) as? Bool) ?? false
        hapticsOn = (defaults.object(forKey: ArcadeKeysStore.haptics) as? Bool) ?? true
        voiceOverReadsAll = defaults.bool(forKey: ArcadeKeysStore.readAll)
        input = ArcadeInput()
        audio = ArcadeAudioSession()
        calls = ArcadeCallWatch()
        saves = try? ArcadeSaveStore.standard()
        super.init()
        telemetry.title = launch.entry.title
        telemetry.gameId = launch.record.gameId
        telemetry.version = launch.record.version
        readProfile()
    }

    /// A game added from Files with no accessibility pack, in the kit's plain player.
    var isPlain: Bool { launch.isPlain }

    /// The game's own gesture and controller tables, from profile.json in its pack.
    private func readProfile() {
        if isPlain {
            readPlainControls()
            return
        }
        let path = launch.record.base + "profile.json"
        guard let found = ArcadeMount.locate(path, in: launch.game + launch.kit),
              let data = try? ArcadeBlobReader.read(found.mount.blob, offset: found.file.offset, length: found.file.length),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let inputs = root["input"] as? [String: Any] {
            if let touch = inputs["touch"] as? [String: Any] { touchTable = ArcadeTouchTable(json: touch) }
            if let gamepad = inputs["gamepad"] as? [String: Any] { gamepadMap = ArcadeGamepadMap(json: gamepad) }
        }
        if let page = root["page"] as? [String: Any], let defaults = page["defaults"] as? [String: Any],
           let speech = defaults["speechMode"] as? String, !speech.isEmpty, speech != "native" {
            // Passed on as the profile has it: the kit's own setMode turns its
            // older name for the cloned voice into 'clone' (core/speech.js).
            defaultSpeechMode = speech
        }
    }

    /// Oct 19 2026, the plain player: its controls for this system from the
    /// kit's games/_plain/systems.json (systems.<id> over the entry it is
    /// `like`), the ones its spoken help describes: on the left a floating
    /// control pad and a two-finger tap for Select, on the right A above B,
    /// held while touched (and the shoulders along the top on the Game Boy
    /// Advance); a controller's d-pad moves and its Back/View button is
    /// Select. The fighting game's defaults never apply here. It has no
    /// cloned voice, so its lines go to VoiceOver (or the phone's speech).
    private func readPlainControls() {
        defaultSpeechMode = "native"
        guard let system = launch.system,
              let found = ArcadeMount.locate(ArcadePlainControls.systemsPath, in: launch.kit + launch.game),
              let data = try? ArcadeBlobReader.read(found.mount.blob, offset: found.file.offset, length: found.file.length) else {
            telemetry.note(error: "the plain player's controls (systems.json) are missing from the kit")
            return
        }
        let tables = ArcadePlainControls.tables(data, system: system.rawValue)
        if let touch = tables.touch { touchTable = touch }
        if let gamepad = tables.gamepad { gamepadMap = gamepad }
        playHint = tables.touchHelp
    }

    // MARK: Opening and closing

    /// Called when the cover appears: pause other audio, take the session,
    /// start listening for controllers, keyboards, calls and the phone's state.
    func begin() {
        guard !begun else { return }
        begun = true
        LibraryNowPlaying.shared.pauseForOtherAudio("the Arcade")
        if FamilyStoryPlayer.shared.playing { FamilyStoryPlayer.shared.pause() }
        UIApplication.shared.isIdleTimerDisabled = true

        audio.onInterruption = { [weak self] began in self?.interrupted(began) }
        audio.onRouteLost = { [weak self] in self?.headphonesGone() }
        audio.onReset = { [weak self] in self?.mediaReset() }
        audio.start()
        calls.onChange = { [weak self] active in self?.callChanged(active) }

        input.onPad = { [weak self] state in self?.controllerPad(state) }
        input.onInfo = { [weak self] what in self?.info(what) }
        input.onKey = { [weak self] key, down in self?.key(key, down: down) }
        input.onEscape = { [weak self] in
            guard let self, !self.keysElsewhere else { return }
            self.askingLeave = true
        }
        input.onAnnounce = { [weak self] text in self?.speak(text, urgent: false, flush: false) }
        input.mode = mode
        input.start(map: gamepadMap)

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.powerChanged() }
            },
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.thermalChanged() }
            },
        ]
        telemetry.openedAt = Date()
        telemetry.environment = environment()
        // VoiceOver starts on the pad, not on Leave: the first double-tap
        // takes hold of the pad. After the cover has finished opening.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !self.ended, UIAccessibility.isVoiceOverRunning, let pad = self.pad else { return }
            UIAccessibility.post(notification: .screenChanged, argument: pad)
        }
        // After VoiceOver has said the new screen, not over it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !self.ended else { return }
            let lines = self.warnings()
            if !lines.isEmpty { self.speak(lines.joined(separator: " "), urgent: false, flush: false) }
        }
    }

    /// Leave game: the page is unloaded (its sound stops at once), every
    /// listener goes, the idle timer comes back.
    func leave() {
        guard !ended else { return }
        pad?.releaseAll()
        input.stop()
        evaluate(ArcadeJS.suspend)
        ended = true
        if let web = webView {
            web.configuration.userContentController.removeScriptMessageHandler(forName: "arcade")
            web.configuration.userContentController.removeAllUserScripts()
            web.stopLoading()
            web.navigationDelegate = nil
            web.loadHTMLString("", baseURL: nil)
        }
        webView = nil
        audio.stop()
        calls.onChange = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        speaker?.stopSpeaking(at: .immediate)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func makeWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        // The default, persistent store: EmulatorJS keeps the game's saves in
        // IndexedDB too (the app keeps its own copy, ArcadeSaveStore).
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let handler = ArcadeSchemeHandler(game: launch.game, kit: launch.kit, overlays: launch.overlays)
        handler.onMissing = { [weak self] path in self?.fileMissing(path) }
        config.setURLSchemeHandler(handler, forURLScheme: ArcadeRoute.scheme)
        config.userContentController.add(ArcadeScriptRelay(self), name: "arcade")
        // The document-start script is written by loadPage, fresh for every load.
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        // Touches belong to the native pad; VoiceOver never walks the page.
        web.isUserInteractionEnabled = false
        web.isAccessibilityElement = false
        web.accessibilityElementsHidden = true
        webView = web
        schemeHandler = handler
        // The first load waits for SwiftUI's current update to finish (this is
        // called from makeUIView): loading publishes the status line, and a
        // published change in the middle of a view update is not allowed.
        Task { @MainActor [weak self] in self?.loadPage() }
        return web
    }

    /// Loads (or reloads, after the page's process died) the game page with a
    /// fresh document-start script, so every start sees the current "VoiceOver
    /// reads every line" choice, the input in use and the latest save.
    private func loadPage() {
        guard !ended, let web = webView, let url = launch.pageURL else { return }
        lastSent.removeAll()
        let content = web.configuration.userContentController
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(source: hostScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        pad?.resetFirstTouch()
        status = "Loading the game"
        // A fresh start countdown for every load, from the load itself in
        // case the kit's 'started' never comes.
        startWatch.load(now: Date())
        scheduleStartCheck()
        pageNavigation = web.load(URLRequest(url: url))
    }

    /// window.revivalKitHost for the next page start (core/host.js).
    private func hostScript() -> String {
        var settings: [String: String] = [:]
        if voiceOverReadsAll { settings["speechMode"] = "native" }
        // Before her first press, the input at hand; after a restart, the one she used last.
        let type = pageInputType ?? ArcadeInput.connectedType()
        pageInputType = type
        // An added game with its pack: her ROM's URL (the overlay), absolute like base.
        return ArcadeJS.hostScript(base: launch.hostRoot + launch.record.base,
                                   emulatorData: launch.hostRoot + launch.record.emulatorData,
                                   settings: settings,
                                   inputType: type,
                                   saveData: saves?.base64(gameId: launch.saveId),
                                   romPath: launch.romPath.map { launch.hostRoot + $0 })
    }

    func attach(pad: ArcadeTouchPadView) {
        self.pad = pad
        pad.hapticsOn = hapticsOn
        pad.setTable(touchTable)
        pad.setPlayHint(playHint)
        pad.setMode(mode)
        pad.onOutputs = { [weak self] outputs in self?.handle(outputs) }
        // WebKit counts the app's evaluateJavaScript as a user gesture, so the
        // first touch after each (re)load also wakes any audio context left suspended.
        pad.onFirstTouch = { [weak self] in self?.evaluate(ArcadeJS.resume) }
        // The escape scrub and magic tap on the pad itself, not only on the strip.
        pad.onEscape = { [weak self] in self?.askingLeave = true }
        pad.onMagicTap = { [weak self] in self?.pauseGame() }
    }

    // MARK: Driving the page

    private func evaluate(_ script: String) {
        guard !ended else { return }
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    private func sendPad(source: String, state: ArcadePadState?) {
        let script = ArcadeJS.pad(source: source, state: state)
        if state != nil {
            guard lastSent[source] != script else { return }   // only what changed reaches the page
            lastSent[source] = script
        } else {
            lastSent[source] = nil
        }
        evaluate(script)
    }

    func handle(_ outputs: [ArcadeTouchOutput]) {
        for output in outputs {
            switch output {
            case .pad(let source, let state):
                telemetry.touchSends += 1
                if state != nil { useInput("touch") }
                sendPad(source: source, state: state)
            case .info(let what):
                useInput("touch")
                info(what)
            case .haptic:
                break
            }
        }
    }

    /// The page was told which input names the buttons ('inputType'), so it
    /// no longer follows the last one used by itself: the app says when that changes.
    private func useInput(_ type: String) {
        guard pageInputType != type else { return }
        pageInputType = type
        evaluate(ArcadeJS.setInputType(type))
    }

    func info(_ what: String) {
        telemetry.infoSends += 1
        evaluate(ArcadeJS.info(what))
    }

    /// Press and let go of one pad button (the strip's Pause is Start).
    func pulse(_ button: String) {
        sendPad(source: "touch-strip", state: ArcadePadState(buttons: [button]))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self?.sendPad(source: "touch-strip", state: nil)
        }
    }

    func pauseGame() { pulse("START") }

    /// The game's own pause, only during a fight (in menus and on its pause
    /// screen Start does something else): before Settings or "Leave game?",
    /// so she is not being hit while she reads them.
    func pauseIfFighting() {
        if mode == "fight" { pauseGame() }
    }

    private func controllerPad(_ state: ArcadePadState?) {
        telemetry.controllerSends += 1
        if state != nil { useInput("gamepad") }
        sendPad(source: "controller", state: state)
    }

    private func key(_ key: String, down: Bool) {
        if down && keysElsewhere { return }
        telemetry.keySends += 1
        if down { useInput("keyboard") }
        evaluate(ArcadeJS.press(key: key, down: down))
    }

    // MARK: What the page says

    fileprivate func receive(_ body: Any) {
        guard !ended, let message = body as? [String: Any], let kind = message["t"] as? String else { return }
        switch kind {
        case "say":
            speak((message["text"] as? String) ?? "", urgent: (message["urgent"] as? Bool) ?? false,
                  flush: (message["flush"] as? Bool) ?? false)
        case "event":
            event((message["name"] as? String) ?? "", detail: message["detail"] as? [String: Any])
        case "pageError":
            let text = (message["message"] as? String) ?? ""
            telemetry.note(error: "page: " + text + " at " + ((message["where"] as? String) ?? ""))
            // Before 'ready', an error that means EmulatorJS can never start
            // is said at once, as the kit's own 'error' would be.
            if startWatch.starting && ArcadeStartWatch.isStartError(text) { couldNotStart("emulator") }
        default:
            break
        }
    }

    private func event(_ name: String, detail: [String: Any]?) {
        telemetry.note(event: name, detail: detail)
        switch name {
        case "started":
            status = "Starting the emulator"
            startWatch.started(now: Date())
            scheduleStartCheck()
            wakeAudio(force: true)
        case "ready":
            status = "Playing"
            stopped = nil
            startWatch.becameReady()
            // Whatever changed while the page was starting reaches it now:
            // the speech choice, the input in use, and its sound.
            evaluate(ArcadeJS.setMode(voiceOverReadsAll ? "native" : defaultSpeechMode))
            if let type = pageInputType { evaluate(ArcadeJS.setInputType(type)) }
            wakeAudio(force: true)
        case "audio":
            let state = (detail?["state"] as? String) ?? ""
            if state == "suspended" || state == "interrupted" { wakeAudio(force: false) }
        case "saved":
            if let data = detail?["data"] as? String { keepSave(data) }
        case "mode":
            if let next = detail?["mode"] as? String { setMode(next) }
        case "error":
            let what = (detail?["what"] as? String) ?? "start"
            if ArcadeJS.cannotStart(what) {
                couldNotStart(what)
            } else {
                status = "The game hit a problem (\(what))"
            }
        default:
            break
        }
    }

    /// The kit's 'error' about a game that never started, or the same
    /// failure seen by the app (a page error or a missing EmulatorJS file
    /// before 'ready'): the status says so, and the line is said once per load.
    private func couldNotStart(_ what: String) {
        status = "The game hit a problem (\(what))"
        if startWatch.claim() {
            speak(ArcadeStartWatch.couldNotStartLine, urgent: true, flush: true)
        }
    }

    /// A file the page asked for is not in the packs: it got a 404 (never a
    /// failed load, which would send EmulatorJS to its public CDN for a
    /// different build) and the how-it-ran text lists it. Before 'ready', a
    /// missing EmulatorJS script or core means it can never start: said at once.
    private func fileMissing(_ path: String) {
        guard !ended, startWatch.starting,
              ArcadeStartWatch.isMissingEmulatorFile(path, emulatorData: launch.record.emulatorData) else { return }
        telemetry.note(error: "start: " + path + " is not in the packs")
        couldNotStart("emulator")
    }

    /// Wakes when the start countdown would run out. A countdown started over
    /// meanwhile has a later deadline, so an older wake finds nothing due.
    private func scheduleStartCheck() {
        guard let deadline = startWatch.deadline else { return }
        let wait = max(0, deadline.timeIntervalSinceNow) + 0.05
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            self?.checkStart()
        }
    }

    /// The countdown ran out with no 'ready': the game did not start. Never
    /// while she is away or the page waits to restart (her return starts the
    /// countdown over), and never after the page stopped for good.
    private func checkStart() {
        guard !ended, startWatch.due(now: Date()) else { return }
        if suspended || needsReload || stopped != nil { return }
        guard UIApplication.shared.applicationState == .active else {
            // Not in front, yet not counted as away: look again shortly.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.checkStart()
            }
            return
        }
        guard startWatch.claim() else { return }
        telemetry.note(error: "start: no ready after \(Int(ArcadeStartWatch.limit)) s (status: \(status))")
        status = ArcadeStartWatch.status
        speak(ArcadeStartWatch.line, urgent: true, flush: true)
    }

    private func setMode(_ next: String) {
        guard next != mode else { return }
        mode = next
        pad?.setMode(next)
        input.mode = next
    }

    /// The page's sound can sit suspended until a user gesture even with
    /// autoplay allowed (WebKit bug 256075), and the web view takes no touches
    /// of its own. evaluateJavaScript counts as a gesture, so the app wakes it:
    /// when the page starts, when it is ready (after every restart too), and
    /// when it says its sound stopped while the game should be playing (then
    /// at most once a second).
    private func wakeAudio(force: Bool) {
        guard !suspended, !ended else { return }
        let now = Date()
        if !force, let last = lastWake, now.timeIntervalSince(last) < 1 { return }
        lastWake = now
        evaluate(ArcadeJS.resume)
    }

    /// The game's save from the page (base64), kept for the next page start.
    private func keepSave(_ base64: String) {
        if saves?.keep(base64: base64, gameId: launch.saveId) != true {
            telemetry.note(error: "a save from the game could not be kept")
        }
    }

    /// Before leaving: the game's save is taken if it is paused or in its
    /// menus (a fight still going has none to take), then `done` runs. Waits
    /// at most a second and a half.
    func saveThenLeave(_ done: @escaping () -> Void) {
        guard leaveWaiter == nil else { return }   // already on the way out
        guard !ended, let web = webView else {
            done()
            return
        }
        leaveWaiter = done
        web.evaluateJavaScript(ArcadeJS.saveNowForLeaving) { [weak self] result, _ in
            guard let self else { return }
            if let data = result as? String, !data.isEmpty { self.keepSave(data) }
            self.finishLeaving()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.finishLeaving()
        }
    }

    private func finishLeaving() {
        guard let waiter = leaveWaiter else { return }
        leaveWaiter = nil
        waiter()
    }

    /// A line with no cloned clip: VoiceOver says it in her own voice and
    /// rate (queued, or at once when urgent or a menu move); with VoiceOver
    /// off the phone's own speech does.
    func speak(_ text: String, urgent: Bool, flush: Bool) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !ended else { return }
        if UIAccessibility.isVoiceOverRunning {
            if urgent {
                KadeAnnounce.high(clean)
            } else {
                UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
                    string: clean, attributes: [.accessibilitySpeechQueueAnnouncement: NSNumber(value: !flush)]))
            }
        } else {
            let synthesizer = speaker ?? AVSpeechSynthesizer()
            speaker = synthesizer
            if urgent || flush { synthesizer.stopSpeaking(at: .immediate) }
            let utterance = AVSpeechUtterance(string: clean)
            utterance.prefersAssistiveTechnologySettings = true
            synthesizer.speak(utterance)
        }
    }

    // MARK: The phone's side

    func scene(active: Bool) {
        guard begun, !ended else { return }
        if active { resumeGame() } else { suspendGame() }
    }

    /// Away (another app, Control Center, Siri, a call): a fight gets the
    /// game's own pause first, so she comes back to its pause screen rather
    /// than into a live fight, and the freeze follows once the game has seen
    /// the press. In menus the save is taken, then the freeze.
    private func suspendGame() {
        guard !suspended else { return }
        suspended = true
        startWatch.away()
        suspendToken += 1
        let token = suspendToken
        pad?.releaseAll()
        input.releaseAll()
        if mode == "fight" {
            pausedForAway = true
            pauseGame()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, self.suspended, self.suspendToken == token else { return }
                self.evaluate(ArcadeJS.suspend)
            }
        } else {
            evaluate(ArcadeJS.saveNow)
            evaluate(ArcadeJS.suspend)
        }
    }

    private func resumeGame() {
        guard suspended, !calls.active, UIApplication.shared.applicationState == .active else { return }
        suspended = false
        suspendToken += 1
        audio.activate()
        // A start still under way gets a fresh countdown (a reload below starts its own).
        startWatch.back(now: Date())
        if needsReload {
            // The page's process ended while she was away: start it now.
            needsReload = false
            pausedForAway = false
            telemetry.recoveries += 1
            speak("The game restarted while you were away.", urgent: false, flush: true)
            loadPage()
            return
        }
        scheduleStartCheck()
        evaluate(ArcadeJS.resume)
        if pausedForAway {
            pausedForAway = false
            speak("The game is paused. Press Pause on the strip, or tap the pad with three fingers, to play on.",
                  urgent: false, flush: false)
        }
    }

    private func interrupted(_ began: Bool) {
        if began { suspendGame() } else { resumeGame() }
    }

    private func callChanged(_ active: Bool) {
        if active { suspendGame() } else { resumeGame() }
    }

    private func headphonesGone() {
        if mode == "fight" { pauseGame() }
        speak("Headphones disconnected" + (mode == "fight" ? ", so the game is paused." : "."), urgent: true, flush: true)
    }

    private func mediaReset() {
        telemetry.note(error: "the phone's media services restarted")
        if !suspended { evaluate(ArcadeJS.resume) }
    }

    private func powerChanged() {
        telemetry.environment = environment()
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            speak("Low Power Mode is on, so the game may run at half speed.", urgent: false, flush: false)
        }
    }

    private func thermalChanged() {
        telemetry.environment = environment()
        switch ProcessInfo.processInfo.thermalState {
        case .serious: speak("The phone is getting warm, so the game may slow down.", urgent: false, flush: false)
        case .critical: speak("The phone is very hot. The game will stutter until it cools.", urgent: true, flush: false)
        default: break
        }
    }

    private var lockdownOn: Bool {
        webView?.configuration.defaultWebpagePreferences.isLockdownModeEnabled ?? false
    }

    private func warnings() -> [String] {
        var lines: [String] = []
        if lockdownOn {
            lines.append("Lockdown Mode is on. It turns off game sound and speed in web pages. To play, exclude Kade AI in Settings, Privacy and Security, Lockdown Mode.")
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { lines.append("Low Power Mode is on, so the game may run at half speed.") }
        switch ProcessInfo.processInfo.thermalState {
        case .serious: lines.append("The phone is warm, so the game may slow down.")
        case .critical: lines.append("The phone is very hot. Let it cool before playing.")
        default: break
        }
        return lines
    }

    private func environment() -> [String: String] {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: system.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "normal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: "+")
        return [
            "device": machine,
            "iOS": UIDevice.current.systemVersion,
            "app": "\(version) (\(build))",
            "low power": ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off",
            "thermal": thermal,
            "lockdown": lockdownOn ? "on" : "off",
            "VoiceOver": UIAccessibility.isVoiceOverRunning ? "on" : "off",
            "audio route": route.isEmpty ? "none" : route,
            "session taken back": String(audio.reasserted),
        ]
    }

    /// How the game ran: what "Copy how the game ran" puts on the clipboard,
    /// and what Report a problem with this game sends from Settings.
    func reportText() -> String {
        telemetry.environment = environment()
        var text = telemetry.report(now: Date())
        if let handler = schemeHandler {
            text += "\nFiles served: \(handler.served)."
            if !handler.missing.isEmpty { text += " Missing from the packs: " + handler.missing.joined(separator: ", ") + "." }
        }
        return text
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        decisionHandler([ArcadeRoute.scheme, "about", "blob", "data"].contains(scheme) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !ended else { return }
        telemetry.pageLoads += 1
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error, navigation: navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error, navigation: navigation)
    }

    private func loadFailed(_ error: Error, navigation: WKNavigation?) {
        guard !ended else { return }
        telemetry.note(error: "load: " + error.localizedDescription)
        status = "The game page did not load"
        speak("The game page did not load. Leave the game and try again, or delete the download and get it again.", urgent: true, flush: true)
        // This load's failure has said its own line: the start countdown has
        // nothing to add. An older load's failure leaves the current one's alone.
        if navigation == nil || navigation === pageNavigation { _ = startWatch.claim() }
    }

    /// iOS ended the page's process (usually memory). Restart it and say so,
    /// unless it keeps happening.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !ended else { return }
        telemetry.terminations += 1
        pad?.releaseAll()
        // Away: restart when she is back (resumeGame), so nothing starts
        // playing behind another app; and a process iOS ends in the
        // background does not count toward giving up.
        if suspended || UIApplication.shared.applicationState != .active {
            suspended = true
            startWatch.away()
            needsReload = true
            setMode("menu")
            status = "Waiting to restart"
            return
        }
        let now = Date()
        terminations = terminations.filter { now.timeIntervalSince($0) < 120 } + [now]
        if terminations.count >= 3 {
            let line = "The game stopped three times in two minutes, so it was not restarted. Open Settings and choose Report a problem with this game, then leave and try again."
            stopped = line
            status = "Stopped"
            // Said here; no start countdown speaks over it later.
            _ = startWatch.claim()
            speak(line, urgent: true, flush: true)
            return
        }
        speak("The game stopped to free memory. Starting it again.", urgent: true, flush: true)
        telemetry.recoveries += 1
        setMode("menu")
        loadPage()
    }
}

// MARK: - SwiftUI

/// The page inside SwiftUI. The host owns the web view, so changing the
/// picture's size never reloads the game.
struct ArcadeWebSurface: UIViewRepresentable {
    let host: ArcadeGameHost
    func makeUIView(context: Context) -> WKWebView { host.makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

struct ArcadeGameView: View {
    @StateObject private var host: ArcadeGameHost
    /// Oct 19 2026: for Report a problem with this game, in Settings.
    let apiClient: KadeAPIClient
    let onClose: (String) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @State private var showSettings = false

    init(launch: ArcadeLaunch, apiClient: KadeAPIClient, onClose: @escaping (String) -> Void) {
        _host = StateObject(wrappedValue: ArcadeGameHost(launch: launch))
        self.apiClient = apiClient
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            strip
            ZStack(alignment: .top) {
                Color.black
                ArcadeWebSurface(host: host)
                    .frame(width: host.showPicture ? nil : 96, height: host.showPicture ? nil : 72)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .frame(maxWidth: .infinity, alignment: host.showPicture ? .center : .trailing)
                    .accessibilityHidden(true)
                ArcadeTouchPadSurface(host: host)
                if let stopped = host.stopped {
                    Text(stopped)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding()
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityAction(.magicTap) { host.pauseGame() }
        .accessibilityAction(.escape) { host.askingLeave = true }
        .onAppear { host.begin() }
        .onDisappear { host.leave() }
        .onChange(of: scenePhase) { _, phase in host.scene(active: phase == .active) }
        .alert("Leave game?", isPresented: $host.askingLeave) {
            Button("Leave game", role: .destructive) { leave() }
            Button("Keep playing", role: .cancel) {}
        } message: {
            Text("The game's own saves stay on this iPhone, ready for next time. A fight still going is not saved.")
        }
        .sheet(isPresented: $showSettings) {
            ArcadeGameSettingsView(host: host, apiClient: apiClient)
        }
        .onChange(of: showSettings) { _, open in host.keysElsewhere = open }
    }

    /// The game's save is taken first (when it is paused or in its menus), then the cover closes.
    private func leave() {
        host.saveThenLeave {
            let report = host.reportText()
            host.leave()
            onClose(report)
        }
    }

    private var strip: some View {
        HStack(spacing: 2) {
            leaveControl
            stripButton("Pause", spoken: "Pause", symbol: "pause.fill",
                        hint: "Presses Start, the game's own pause. Magic tap does the same.") { host.pauseGame() }
            statusControl
            stripButton("Repeat", spoken: "Repeat", symbol: "arrow.counterclockwise",
                        hint: "Says the last line again.") { host.info("repeat") }
            stripButton("Settings", spoken: "Settings", symbol: "gearshape",
                        hint: "The picture, speech, haptics, and Report a problem with this game. Pauses a fight first.") {
                host.pauseIfFighting()
                showSettings = true
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(Color(white: 0.12))
    }

    /// Status: a pack's game says your health, with time, where everyone is,
    /// facing and help in the Actions rotor. A game with no accessibility pack
    /// (the plain player) has none of those to read: Status says whether it is
    /// running and why there is nothing more, and Help says its controls.
    @ViewBuilder
    private var statusControl: some View {
        if host.isPlain {
            stripButton("Status", spoken: "Status", symbol: "heart.text.square",
                        hint: "Says whether the game is running. The Actions rotor has help with the controls.") {
                host.speak(host.status + ". This game has no accessibility pack, so there is no health or position to read.",
                           urgent: false, flush: true)
            }
            .accessibilityValue(host.status)
            .accessibilityAction(named: "Help") { host.info("help") }
        } else {
            stripButton("Status", spoken: "Status", symbol: "heart.text.square",
                        hint: "Says your health. The Actions rotor has time, where everyone is, facing and help.") { host.info("health") }
                .accessibilityValue(host.status)
                .accessibilityAction(named: "Time") { host.info("time") }
                .accessibilityAction(named: "Where is everyone") { host.info("where") }
                .accessibilityAction(named: "Facing") { host.info("facing") }
                .accessibilityAction(named: "Help") { host.info("help") }
        }
    }

    @ViewBuilder
    private var leaveControl: some View {
        if voiceOverOn {
            // Asks first, like the escape scrub: a stray double-tap here must not end a fight.
            stripButton("Leave", spoken: "Leave game", symbol: "xmark",
                        hint: "Asks first, then closes the game. Its saves stay on this iPhone.") { host.askingLeave = true }
        } else {
            // With VoiceOver off the whole screen is for playing: leaving takes a one-second hold.
            stripLabel("Hold to leave", symbol: "xmark")
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 1) { leave() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Leave game")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { host.askingLeave = true }
        }
    }

    private func stripLabel(_ title: String, symbol: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
            Text(title)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 48)
    }

    private func stripButton(_ title: String, spoken: String, symbol: String, hint: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            stripLabel(title, symbol: symbol)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spoken)
        .accessibilityHint(hint)
    }
}

struct ArcadeGameSettingsView: View {
    @ObservedObject var host: ArcadeGameHost
    let apiClient: KadeAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    /// The game open right now, at the version on this iPhone (a game added
    /// from Files names itself by its No-Intro sha1).
    private var reportTarget: ArcadeReportTarget {
        host.launch.reportTarget ?? ArcadeReportTarget(gameId: host.launch.record.gameId, title: host.launch.entry.title,
                                                       version: host.launch.record.version)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Show the game picture", isOn: $host.showPicture)
                    Toggle("VoiceOver reads every line", isOn: $host.voiceOverReadsAll)
                    Toggle("Pad haptics", isOn: $host.hapticsOn)
                } footer: {
                    Text("With VoiceOver reading every line, the game's cloned voice stays quiet and VoiceOver says everything in your own voice and speed.")
                }
                // Oct 19 2026 (App Store 4.7.1): reports go to Kade through
                // the app's own feedback path, with this game's id and
                // version and how it ran (read when Send is pressed).
                Section {
                    NavigationLink {
                        ArcadeReportView(apiClient: apiClient, target: reportTarget,
                                         place: "Game settings", standalone: false,
                                         ran: { host.reportText() })
                    } label: {
                        Label(ArcadeReport.actionName, systemImage: "exclamationmark.bubble")
                    }
                } footer: {
                    Text("Something wrong with this game, its sound or its words? Tell Kade in a few words. The game's name and version, and how it ran on this iPhone (no account details), go with it.")
                }
                Section {
                    Button(copied ? "Copied" : "Copy how the game ran") {
                        UIPasteboard.general.string = host.reportText()
                        copied = true
                        UIAccessibility.post(notification: .announcement, argument: "Copied.")
                    }
                } footer: {
                    Text("How the game ran on this iPhone: speed, restarts, sound and inputs. No account details.")
                }
                Section("Tips") {
                    Text("Wired headphones are quicker than AirPods, by about a tenth of a second.")
                    Text("In the VoiceOver rotor, turn Audio Ducking off so VoiceOver does not lower the game.")
                    Text("Keep Mono Audio off, so sounds stay on their own side.")
                    Text("With a keyboard, press Left and Right arrows together once to turn Quick Nav off.")
                }
            }
            .navigationTitle("Game settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
