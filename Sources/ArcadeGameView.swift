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
//     Repeat, Screen text (a game with its accessibility pack), Settings.
//     Magic tap pauses; the escape scrub asks
//     "Leave game?". Exit always lives here, because VoiceOver gestures do not
//     work inside the direct-touch pad;
//   - the game page in a WKWebView, served from the downloaded packs by
//     ArcadeSchemeHandler, hidden from VoiceOver (the page speaks through its
//     own cloned voice, and lines with no clip come back here as VoiceOver
//     announcements, or AVSpeechSynthesizer with VoiceOver off);
//   - the game pad (ArcadeTouchPad.swift) over everything below the strip.
// Touch play (Oct 20 2026): the strip is at least 64 points tall and reaches
// the very top of the screen (touching there brings VoiceOver back), and
// adds How to play and Pad practice; the kit's lines with no clip are said
// one at a time and acknowledged (ArcadeSpeechQueue); the app's own lines go
// through the kit's one queue; the kit's voice waits until 1.8 s after
// VoiceOver lands on the pad (speechGo); its game cues buzz; and while the
// pad is held in a fight the screen edges' own gestures wait.
// The host keeps the page's contract (Revival kit core/host.js and app.js):
// window.revivalKitHost is injected at document start; the app drives
// window.revivalKit (pad, info, press, setMode, suspend, resume, and since
// Oct 19 2026 setOutput and setSettings) only through evaluateJavaScript,
// and only when something changed. The kit's 'settings' are kept per game
// and given back at the next start; its 'lines' fill the Screen text sheet.

private enum ArcadeKeysStore {
    static let picture = "kade.arcade.showPicture"
    static let haptics = "kade.arcade.haptics"
    static let readAll = "kade.arcade.voiceOverReadsAll"
    // Oct 20 2026, touch play: the app's own touch switches, for every game
    // (her touch timing is ArcadeTouchTimingStore.key; the kit's own touch
    // choices are kept with its settings).
    static let chimes = "kade.arcade.padChimes"
    static let pauseOnLeave = "kade.arcade.pauseOnLeave"
    static let holdAtOnce = "kade.arcade.padTakesHoldAtOnce"
    static let speakerWarnings = "kade.arcade.speakerWarnings"
    static let practiceOffered = "kade.arcade.padPracticeOffered"
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
    /// Any route change at all (Oct 19 2026): the host tells the kit where
    /// the sound goes now, once the route has settled.
    var onRouteChange: (@MainActor () -> Void)?
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
        onRouteChange?()
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
        didSet {
            UserDefaults.standard.set(showPicture, forKey: ArcadeKeysStore.picture)
            // Oct 19 2026: the kit draws a small picture in No-vision mode
            // unless told the full one is wanted (a sighted watcher). Only a
            // ready page is told: one still starting may not have
            // window.revivalKit yet, and its 'ready' sends the picture if it
            // differs from the one it started with (pictureSent).
            if showPicture != oldValue && pageReady { sendPicture() }
        }
    }
    /// Oct 19 2026: the sound world, position calls and route the kit is
    /// using, for the game's Settings. Nil until the running page says (an
    /// older game player never does: it has no sound choices).
    @Published private(set) var kitSound: ArcadeKitSound?
    /// The page is up and 'ready' (false again while it reloads).
    @Published private(set) var pageReady = false
    /// The game screen's text, from the kit's latest 'lines' event (Screen text).
    @Published private(set) var screenText: ArcadeScreenText?
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
    /// Oct 20 2026: the pad is held (VoiceOver's direct touch is on it):
    /// while it is, in a fight, the screen edges' own gestures wait.
    @Published private(set) var padHeld = false
    /// Pad chimes: the rising and falling chimes when the pad is taken and let go.
    @Published var chimesOn: Bool {
        didSet {
            UserDefaults.standard.set(chimesOn, forKey: ArcadeKeysStore.chimes)
            pad?.chimesOn = chimesOn
        }
    }
    /// Pause when I leave the pad: a live fight pauses as VoiceOver leaves the pad.
    @Published var pauseOnLeave: Bool {
        didSet {
            UserDefaults.standard.set(pauseOnLeave, forKey: ArcadeKeysStore.pauseOnLeave)
            pad?.pauseOnLeave = pauseOnLeave && !isPlain
            if pageReady && !isPlain { evaluate(ArcadeJS.setSettings(["pauseOnLeave": pauseOnLeave])) }
        }
    }
    /// Pad takes hold: at once (true), or after VoiceOver's double-tap (false, the default).
    @Published var takesHoldAtOnce: Bool {
        didSet {
            UserDefaults.standard.set(takesHoldAtOnce, forKey: ArcadeKeysStore.holdAtOnce)
            pad?.takesHoldAtOnce = takesHoldAtOnce
        }
    }
    /// Warnings on the phone speaker (the kit's calls there, and the telegraph buzz).
    @Published var speakerWarnings: ArcadeSpeakerWarnings {
        didSet {
            UserDefaults.standard.set(speakerWarnings.rawValue, forKey: ArcadeKeysStore.speakerWarnings)
            applySpeakerCalls()
        }
    }
    /// Her touch timing (Fitted to me, Relaxed, Quick), for every game.
    @Published private(set) var timing: ArcadeTouchTimingStore
    /// The kit's own touch choices (Fight controls, Walk in for me, Less damage, Skip the demo fight).
    @Published private(set) var touchChoices = ArcadeTouchChoices()
    /// The first-open offer of Pad practice is up.
    @Published var offeringPractice = false
    /// Pad practice is open.
    @Published var practicing = false

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
    /// The one wake for the start countdown, cancelled when the countdown
    /// stops (leave, 'ready', away, a line said) or is set again.
    private var startCheck: Task<Void, Never>?
    /// A start failure's line that came while she was away (another app,
    /// Control Center, a call): said on her return, not into the background.
    private var startLinePending: String?
    /// Oct 19 2026: the game's Settings sheet is up (and with it Report a
    /// problem's text field), so a keyboard's presses are typing, not play:
    /// no key goes down in the game and Escape does not ask to leave.
    /// Releases still pass, so nothing stays held.
    var keysElsewhere = false
    /// Oct 19 2026: the kit's own settings for this game as it last sent
    /// them ('settings'), kept beside the save and given back at every start.
    private var kitSettings: [String: Any]?
    /// The route word the kit was last told on this page (nil: not yet).
    private var routeSent: ArcadeAudioRoute?
    /// The one wait for a route change to settle (300 ms).
    private var routeCheck: Task<Void, Never>?
    /// The game's own names for its screens (profile.screenNames), for the Screen text title.
    private var screenNames: [String: String] = [:]
    /// The game has its own words for a route change (profile
    /// page.outputLines), which a kit told the route says itself.
    private var gameSaysRoutes = false
    /// Show the game picture as the page last had it: the value its
    /// document-start script carried, or the last one sent to it.
    private var pictureSent: Bool?
    /// Oct 20 2026: the lines said here, one at a time (speech rule R1).
    private var speech = ArcadeSpeechQueue()
    /// The one wake for the line being said, in case it never ends.
    private var speechCheck: Task<Void, Never>?
    /// The kit's native items already taken (a line may come both as the native route and as a 'say' event).
    private var speechIds: [String] = []
    /// The one wait before the kit's voice goes again with VoiceOver focus back on the pad.
    private var voiceCheck: Task<Void, Never>?
    /// The start-up warnings said at 'ready' (Lockdown Mode, Low Power Mode,
    /// heat), also in the Status button's value so they can be found later.
    @Published private(set) var startWarnings: [String] = []
    /// VoiceOver landed on the pad and the kit was told it may speak (speechGo).
    private var speechOpen = false
    /// The start-up warnings went to the kit's queue (once per open).
    private var warningsSent = false
    /// The pad isn't held line was said in this fight.
    private var watchdogWarned = false
    /// The last Start the app pressed to pause a fight: a second one before
    /// the kit says 'pause' would unpause it.
    private var lastPausePress: Date?
    /// The pack's own Pad practice table (input.touch.practice), when it has one.
    private(set) var practiceJSON: [String: Any]?
    /// Pad practice was opened and has not been closed yet.
    private var practiceShown = false

    /// She plays by touch (the page names buttons for touch).
    var isTouchPlayer: Bool { pageInputType == "touch" }

    init(launch: ArcadeLaunch) {
        self.launch = launch
        let defaults = UserDefaults.standard
        showPicture = (defaults.object(forKey: ArcadeKeysStore.picture) as? Bool) ?? false
        hapticsOn = (defaults.object(forKey: ArcadeKeysStore.haptics) as? Bool) ?? true
        voiceOverReadsAll = defaults.bool(forKey: ArcadeKeysStore.readAll)
        chimesOn = (defaults.object(forKey: ArcadeKeysStore.chimes) as? Bool) ?? true
        pauseOnLeave = (defaults.object(forKey: ArcadeKeysStore.pauseOnLeave) as? Bool) ?? true
        takesHoldAtOnce = defaults.bool(forKey: ArcadeKeysStore.holdAtOnce)
        speakerWarnings = ArcadeSpeakerWarnings(rawValue: defaults.string(forKey: ArcadeKeysStore.speakerWarnings) ?? "") ?? .buzzAndWords
        timing = ArcadeTouchTimingStore.decode(defaults.data(forKey: ArcadeTouchTimingStore.key))
        input = ArcadeInput()
        audio = ArcadeAudioSession()
        calls = ArcadeCallWatch()
        saves = try? ArcadeSaveStore.standard()
        super.init()
        telemetry.title = launch.entry.title
        telemetry.gameId = launch.record.gameId
        telemetry.version = launch.record.version
        telemetry.player = launch.record.kitVersion ?? ""
        telemetry.newerPlayerReady = launch.newerPlayer != nil
        kitSettings = settingsKey.flatMap { saves?.settings(gameId: $0) }
        touchChoices = ArcadeTouchChoices(settings: kitSettings)
        readProfile()
    }

    /// The gesture tables in use (How to play, Pad practice).
    var touchTableInUse: ArcadeTouchTable { touchTable }

    /// Whether this game offers Easy and Full fight controls (a pack with touch v2 tables).
    var hasFightTiers: Bool { !isPlain && touchTable.hasTiers }

    /// How to play: the controls for menus and the fight tier in use, from the table's own words.
    var howToPlay: [ArcadeHowToPlaySection] {
        ArcadeHowToPlay.sections(table: touchTable, plainHelp: playHint)
    }

    /// The Screen text sheet's title: the game's own name for the screen.
    var screenTitle: String {
        screenText?.title(names: screenNames) ?? ArcadeScreenText.defaultTitle
    }

    /// A game added from Files with no accessibility pack, in the kit's plain player.
    var isPlain: Bool { launch.isPlain }

    /// Where the kit's settings are kept: under the save's id for a game's
    /// page, nowhere for the plain player (an added game's plain player and
    /// its accessibility pack share the save's id, not their settings).
    private var settingsKey: String? {
        ArcadeKitSettings.storeKey(saveId: launch.saveId, isPlain: isPlain)
    }

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
            if let touch = inputs["touch"] as? [String: Any] {
                touchTable = ArcadeTouchTable(json: touch)
                practiceJSON = touch["practice"] as? [String: Any]
            }
            if let gamepad = inputs["gamepad"] as? [String: Any] { gamepadMap = ArcadeGamepadMap(json: gamepad) }
        }
        // Oct 20 2026: the fight tier she chose (the kit keeps it), Easy by default.
        touchTable.tier = touchChoices.fightControls
        if let names = root["screenNames"] as? [String: Any] {
            screenNames = names.compactMapValues { $0 as? String }
        }
        gameSaysRoutes = ArcadeAudioRoute.gameSaysRoutes(page: root["page"] as? [String: Any])
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
        audio.onRouteChange = { [weak self] in self?.routeChanged() }
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
        // A controller come or gone: through the kit's one queue, never over the game's voice.
        input.onAnnounce = { [weak self] text in self?.say(text, cls: "flow") }
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
            // Oct 20 2026: a line said here ends when VoiceOver says so.
            center.addObserver(forName: UIAccessibility.announcementDidFinishNotification, object: nil, queue: .main) { [weak self] note in
                let text = note.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String
                let ok = (note.userInfo?[UIAccessibility.announcementWasSuccessfulUserInfoKey] as? Bool) ?? true
                Task { @MainActor in self?.speechEnded(text: text, ok: ok) }
            },
        ]
        telemetry.openedAt = Date()
        telemetry.environment = environment()
        // VoiceOver starts on the pad, not on Leave: the first double-tap
        // takes hold of the pad. After the cover has finished opening. Oct 20
        // 2026: the first time a touch player opens any game, Pad practice is
        // offered first; the kit's voice waits for the answer.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !self.ended else { return }
            if self.shouldOfferPractice() {
                UserDefaults.standard.set(true, forKey: ArcadeKeysStore.practiceOffered)
                self.evaluate(ArcadeJS.holdSpeech(true))
                self.offeringPractice = true
                return
            }
            self.focusPad()
        }
        // The start-up warnings join the kit's queue at 'ready', as screen
        // lines after its first line (sendWarnings), never over VoiceOver.
    }

    /// The first time a touch player opens any game (no controller or keyboard).
    private func shouldOfferPractice() -> Bool {
        !UserDefaults.standard.bool(forKey: ArcadeKeysStore.practiceOffered) && ArcadeInput.connectedType() == "touch"
    }

    /// First time with the game pad?: learn it now, or play.
    func answerOffer(learn: Bool) {
        offeringPractice = false
        if learn {
            openPractice()
            return
        }
        // Once the alert has gone: focus posted while it is still up goes
        // back to the element it came from, the strip's first button (Leave game).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.focusPad()
        }
    }

    /// VoiceOver focus to the pad, then the kit may speak 1.8 s later (at
    /// once with VoiceOver off), so VoiceOver reading the pad and the game's
    /// first line never overlap.
    func focusPad() {
        guard !ended else { return }
        if UIAccessibility.isVoiceOverRunning, let pad {
            UIAccessibility.post(notification: .screenChanged, argument: pad)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                self?.openSpeech()
            }
        } else {
            openSpeech()
        }
    }

    /// VoiceOver focus has left the pad (for the strip, a sheet or an
    /// alert): the kit holds everything but answers (speech rule R10).
    private var voiceOffPad: Bool {
        pad?.hold.offPad(voiceOver: UIAccessibility.isVoiceOverRunning) ?? false
    }

    /// revivalKit.speechGo(), and its voice let go unless she has already
    /// moved off the pad; said again at 'ready' (the page may not have been there yet).
    private func openSpeech() {
        guard !ended, !practicing, !offeringPractice else { return }
        speechOpen = true
        evaluate(ArcadeJS.speechGo)
        evaluate(ArcadeJS.holdSpeech(voiceOffPad))
    }

    /// VoiceOver focus came back to the pad without taking it: the kit's
    /// voice goes again once VoiceOver has read the pad (1.5 s), if focus is
    /// still there and neither the offer nor Pad practice is up.
    private func voiceBackOnPad() {
        voiceCheck?.cancel()
        voiceCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, !self.ended, self.speechOpen, !self.practicing, !self.offeringPractice,
                  self.pad?.hold.focused == true else { return }
            self.evaluate(ArcadeJS.holdSpeech(false))
        }
    }

    /// Pad practice (the strip, Settings or the first-open offer): a fight is
    /// paused first, the kit's voice waits and the game is frozen while it is open.
    func openPractice() {
        guard !ended, !practicing else { return }
        offeringPractice = false
        pauseFight()
        evaluate(ArcadeJS.holdSpeech(true))
        runSpeech(speech.quiet())
        practiceShown = true
        practicing = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, self.practicing else { return }
            self.evaluate(ArcadeJS.suspend)
        }
    }

    /// From Settings: once its sheet has gone.
    func openPracticeSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.openPractice()
        }
    }

    /// Pad practice closed (its Done, or the cover gone): the game goes on,
    /// and VoiceOver lands on the pad again. Once per opening.
    func practiceClosed() {
        guard practiceShown else { return }
        practiceShown = false
        practicing = false
        if !suspended { evaluate(ArcadeJS.resume) }
        focusPad()
    }

    /// Pad practice fitted her touch: kept as Fitted to me, and used from now on.
    func keepFit(_ fit: ArcadeTouchFit) {
        timing.fitted = fit
        timing.choice = .fitted
        applyTiming()
    }

    /// Touch timing from Settings.
    func chooseTiming(_ choice: ArcadeTouchTiming) {
        guard choice != timing.choice else { return }
        timing.choice = choice
        applyTiming()
    }

    private func applyTiming() {
        if let data = timing.encoded() { UserDefaults.standard.set(data, forKey: ArcadeTouchTimingStore.key) }
        pad?.setFit(timing.overlay)
        if pageReady && !isPlain { evaluate(ArcadeJS.setSettings(["touchTiming": timing.kitValue])) }
    }

    /// Fight controls from Settings ('easy' or 'full'): the pad's table and the kit both change.
    func chooseFightControls(_ tier: String) {
        guard tier == "easy" || tier == "full", tier != touchChoices.fightControls else { return }
        setKitTouch("fightControls", tier)
    }

    /// One of the kit's own touch choices (fightControls, walkIn, lessDamage, skipDemo).
    func setKitTouch(_ key: String, _ value: Any) {
        guard !isPlain else { return }
        var settings = kitSettings ?? [:]
        settings[key] = value
        touchChoices = ArcadeTouchChoices(settings: settings)
        if touchTable.tier != touchChoices.fightControls {
            touchTable.tier = touchChoices.fightControls
            pad?.setTable(touchTable)
        }
        if pageReady { evaluate(ArcadeJS.setSettings([key: value])) }
    }

    /// Teach me again: the kit's teach pause comes back at the next Easy fight.
    func teachAgain() {
        guard !isPlain, pageReady else { return }
        evaluate(ArcadeJS.setSettings(["coached": [String: Any]()]))
        // Her own button: an answer in the kit's queue (answers pass while VoiceOver is on the sheet).
        say("The lesson comes back at your next fight.", cls: "answer")
    }

    /// Leave game: the page is unloaded (its sound stops at once), every
    /// listener goes, the idle timer comes back.
    func leave() {
        guard !ended else { return }
        pad?.releaseAll()
        input.stop()
        evaluate(ArcadeJS.suspend)
        ended = true
        stopStartCheck()
        routeCheck?.cancel()
        routeCheck = nil
        startLinePending = nil
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
        speechCheck?.cancel()
        speechCheck = nil
        voiceCheck?.cancel()
        voiceCheck = nil
        speech = ArcadeSpeechQueue()
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
        // A new page knows nothing yet: it is told the route at 'ready', and
        // its sound and screen text come from it again.
        pageReady = false
        routeSent = nil
        kitSound = nil
        screenText = nil
        // The new page numbers its native items from the start again: the old
        // page's ids and items mean nothing to it (the app's own lines stay).
        speechIds.removeAll()
        runSpeech(speech.dropKit(now: speechClock))
        let content = web.configuration.userContentController
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(source: hostScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        pad?.resetFirstTouch()
        status = "Loading the game"
        // A fresh start countdown for every load, from the load itself in
        // case the kit's 'started' never comes. A line held from the last
        // load is dropped: this start begins again.
        startWatch.load(now: Date())
        startLinePending = nil
        scheduleStartCheck()
        pageNavigation = web.load(URLRequest(url: url))
    }

    /// window.revivalKitHost for the next page start (core/host.js).
    private func hostScript() -> String {
        // The kit's own settings as it last sent them (its per-route choices
        // included), under the app's switches: VoiceOver reads every line,
        // Show the game picture, and headphones starting on Stereo.
        var settings = ArcadeKitSettings.hostSettings(saved: kitSettings, readsAll: voiceOverReadsAll,
                                                      showPicture: showPicture, hasSoundWorld: !isPlain)
        // Before her first press, the input at hand; after a restart, the one she used last.
        let type = pageInputType ?? ArcadeInput.connectedType()
        pageInputType = type
        // Oct 20 2026: the touch defaults (Easy, Walk in for me; for touch
        // input Skip the demo fight and her Pause when I leave the pad) where
        // she has not chosen, and her touch timing. The plain player keeps none.
        if !isPlain {
            ArcadeTouchChoices.fillDefaults(&settings, pauseOnLeave: pauseOnLeave, touch: type == "touch")
            settings["touchTiming"] = timing.kitValue
        }
        // The picture this page starts with: 'ready' sends it again if she
        // changed it while the page was starting.
        pictureSent = showPicture
        // The kit's voice is held from its first line while the first-open
        // offer or Pad practice is up, or the offer is about to be (begin()
        // asks 0.7 s after the cover opens; openSpeech lets the voice go if it is not).
        let hold = practicing || offeringPractice || shouldOfferPractice()
        // An added game with its pack: her ROM's URL (the overlay), absolute like base.
        return ArcadeJS.hostScript(base: launch.hostRoot + launch.record.base,
                                   emulatorData: launch.hostRoot + launch.record.emulatorData,
                                   settings: settings,
                                   inputType: type,
                                   saveData: saves?.base64(gameId: launch.saveId),
                                   romPath: launch.romPath.map { launch.hostRoot + $0 },
                                   holdSpeech: hold)
    }

    func attach(pad: ArcadeTouchPadView) {
        self.pad = pad
        pad.hapticsOn = hapticsOn
        pad.chimesOn = chimesOn
        pad.pauseOnLeave = pauseOnLeave && !isPlain
        pad.takesHoldAtOnce = takesHoldAtOnce
        pad.setTable(touchTable)
        pad.setFit(timing.overlay)
        pad.setMode(mode)
        pad.onOutputs = { [weak self] outputs in self?.handle(outputs) }
        // WebKit counts the app's evaluateJavaScript as a user gesture, so the
        // first touch after each (re)load also wakes any audio context left suspended.
        pad.onFirstTouch = { [weak self] in
            guard let self, !self.practicing else { return }
            self.evaluate(ArcadeJS.resume)
        }
        // The escape scrub and magic tap on the pad itself (focused, not
        // held): Back in menus and pause in fights; Start. Leave game is
        // only on the strip.
        pad.onEscape = { [weak self] in self?.padEscape() }
        pad.onMagicTap = { [weak self] in self?.padMagicTap() }
        pad.onHold = { [weak self] effects in self?.padHold(effects) }
        pad.onPadLog = { [weak self] on, how in self?.padLog(on: on, how: how) }
        pad.onActivate = { [weak self] in self?.telemetry.touch.activates += 1 }
    }

    // MARK: The pad held (Oct 20 2026)

    private func padEscape() {
        if mode == "fight" {
            pauseFight()
            pad?.play(ArcadeFeel.start)
        } else {
            pulse("B")
            pad?.play(ArcadeFeel.back)
        }
    }

    private func padMagicTap() {
        pauseGame()
        pad?.play(ArcadeFeel.start)
    }

    /// The held state's effects: lines through the kit's queue, its voice held or let go, a fight paused.
    private func padHold(_ effects: [ArcadePadEffect]) {
        for effect in effects {
            switch effect {
            case .say(let text, let cls):
                say(text, cls: cls)
            case .holdSpeech(let on):
                // While the offer or Pad practice is up the kit's voice stays held.
                if on || (!practicing && !offeringPractice) { evaluate(ArcadeJS.holdSpeech(on)) }
            case .pauseGame:
                if pauseFight() { telemetry.touch.autoPauses += 1 }
            case .focusedNotHeld:
                voiceBackOnPad()
            default:
                break
            }
        }
        padHeld = pad?.hold.held ?? false
    }

    private func padLog(on: Bool, how: String) {
        telemetry.touch.note(pad: on, seconds: Date().timeIntervalSince(telemetry.openedAt), how: how)
        padHeld = pad?.hold.held ?? false
    }

    /// The kit's 'idleHurt': she lost health with no presses. Said only when
    /// the pad itself had no touches in those five seconds, once per fight.
    private func watchdog() {
        guard !isPlain, let pad else { return }
        guard ArcadeWatchdog.shouldWarn(mode: mode, lastTouch: pad.lastTouch, now: pad.clock,
                                        warnedThisFight: watchdogWarned) else { return }
        watchdogWarned = true
        telemetry.touch.watchdogFires += 1
        say(ArcadeTouchLines.watchdog, cls: "teach")
    }

    /// The telegraph buzz on the speaker follows Warnings on the phone speaker.
    private var telegraphBuzz: Bool {
        kitSound?.output == .speaker ? speakerWarnings.buzz : true
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
                // Quiet stops the app's own speech at once too (the kit's 'quiet' follows).
                if what == "quiet" { runSpeech(speech.quiet()) }
            case .gesture(let report):
                telemetry.touch.note(gesture: report, seconds: Date().timeIntervalSince(telemetry.openedAt),
                                     held: pad?.hold.held ?? false, tier: touchTable.tier)
            case .dud(let dud):
                telemetry.touch.note(dud: dud, seconds: Date().timeIntervalSince(telemetry.openedAt),
                                     held: pad?.hold.held ?? false, tier: touchTable.tier)
            case .haptic, .lifted:
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
        pauseFight()
    }

    /// Oct 20 2026: the pause pressed once. Leaving the pad pauses a fight
    /// and so may the strip's next button; a second Start before the kit
    /// says 'pause' would unpause it, so one within 1.5 s is not pressed.
    @discardableResult
    private func pauseFight() -> Bool {
        guard mode == "fight" else { return false }
        if let last = lastPausePress, Date().timeIntervalSince(last) < 1.5 { return false }
        lastPausePress = Date()
        pauseGame()
        return true
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
            // Oct 20 2026: the kit's native item, with its id and class, said
            // in turn and acknowledged; an older kit's line (no id) in turn too.
            let id = message["id"] as? String
            if let id {
                if speechIds.contains(id) { return }
                speechIds.append(id)
                if speechIds.count > 64 { speechIds.removeFirst(speechIds.count - 64) }
            }
            let urgent = (message["urgent"] as? Bool) ?? false
            // Her answers (the kit marks them urgent and has cut its own line for them) cut the line being said here too.
            let interrupts = ArcadeSpeechQueue.kitInterrupts(flush: (message["flush"] as? Bool) ?? false, urgent: urgent, id: id)
            nativeLine((message["text"] as? String) ?? "", id: id, cls: (message["cls"] as? String) ?? (urgent ? "alert" : "flow"),
                       interrupts: interrupts)
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
            // The offer or Pad practice is up: the kit's voice stays held, and
            // under Pad practice the game is frozen from its start.
            if offeringPractice || practicing { evaluate(ArcadeJS.holdSpeech(true)) }
            if practicing { evaluate(ArcadeJS.suspend) }
        case "ready":
            status = "Playing"
            stopped = nil
            startWatch.becameReady()
            stopStartCheck()
            // It did start after all: a failure line held while she was away
            // would be wrong now.
            startLinePending = nil
            // Whatever changed while the page was starting reaches it now:
            // the speech choice, the input in use, and its sound.
            evaluate(ArcadeJS.setMode(voiceOverReadsAll ? "native" : defaultSpeechMode))
            if let type = pageInputType { evaluate(ArcadeJS.setInputType(type)) }
            wakeAudio(force: true)
            pageReady = true
            // Show the game picture, if she changed it while the page was starting.
            if pictureSent != showPicture { sendPicture() }
            // Where the sound goes, once per page (then on every route change).
            sendRoute()
            // Oct 20 2026: the touch choices; the kit's voice gate (it may
            // have missed speechGo while it was starting); the warnings in its queue.
            sendTouchSettings()
            if offeringPractice || practicing {
                evaluate(ArcadeJS.holdSpeech(true))
            } else if speechOpen {
                evaluate(ArcadeJS.speechGo)
                // A restarted page knows no hold: held again while VoiceOver is off the pad.
                if voiceOffPad { evaluate(ArcadeJS.holdSpeech(true)) }
            }
            // A page that became ready under Pad practice is frozen too (wakeAudio above waits for it to close).
            if practicing { evaluate(ArcadeJS.suspend) }
            sendWarnings()
        case "settings":
            if let detail { keepKitSettings(detail) }
        case "cue":
            // Oct 20 2026: the kit's game cues are haptics (on the speaker they never compete with speech).
            let cue = (detail?["k"] as? String) ?? ""
            if cue != "telegraph" || telegraphBuzz { pad?.feel(cue: cue) }
        case "idleHurt":
            watchdog()
        case "quiet":
            runSpeech(speech.quiet())
        case "cut":
            // The kit cut its own line for her answer (the host script sends this with every answer it queues).
            runSpeech(speech.cutKit(now: speechClock))
        case "lines":
            screenText = ArcadeScreenText(detail: detail)
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
                // The RAM finder gave up: the kit has said its own line and no
                // 'ready' follows, so the start is over and the countdown does
                // not say a second, different failure a minute later.
                if ArcadeStartWatch.kitEndedStart(what) { _ = claimStart() }
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
        guard claimStart() else { return }
        // Oct 19 2026: on an older game player than the shelf's, the line
        // names the newer one (build 340 went on starting the old one).
        sayStartLine(ArcadeStartWatch.failureLine(couldNotStart: true, newerPlayer: launch.newerPlayer))
    }

    /// Takes this load's one start line (ArcadeStartWatch.claim) and stops the
    /// countdown's wake with it.
    private func claimStart() -> Bool {
        let claimed = startWatch.claim()
        stopStartCheck()
        return claimed
    }

    /// A start failure's line: said now, or, while she is away (another app,
    /// Control Center, a call), held and said on her return. In the
    /// background VoiceOver drops it or says it over the call, and her
    /// return would bring no line, so the stall would be silent again.
    private func sayStartLine(_ line: String) {
        startLinePending = line
        sayHeldStartLine()
    }

    /// The held start line, once she is in front: resumeGame says it on her
    /// return. Not in front yet not counted as away (the scene has not said so
    /// yet), it looks again shortly. A reload or 'ready' drops it.
    private func sayHeldStartLine() {
        guard !ended, !suspended, let line = startLinePending else { return }
        guard UIApplication.shared.applicationState == .active else {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.sayHeldStartLine()
            }
            return
        }
        startLinePending = nil
        speak(line, urgent: true, flush: true)
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

    /// The one wake for the start countdown: when it would run out, or
    /// `after` seconds. Any earlier wake is cancelled; none is set while the
    /// countdown is not running.
    private func scheduleStartCheck(after: TimeInterval? = nil) {
        stopStartCheck()
        guard let deadline = startWatch.deadline else { return }
        let wait = after ?? (max(0, deadline.timeIntervalSinceNow) + 0.05)
        startCheck = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } catch {
                return   // cancelled: the countdown stopped or was set again
            }
            guard !Task.isCancelled else { return }
            self?.checkStart()
        }
    }

    private func stopStartCheck() {
        startCheck?.cancel()
        startCheck = nil
    }

    /// The countdown ran out with no 'ready': the game did not start. Never
    /// while she is away or the page waits to restart (her return starts the
    /// countdown over), and never after the page stopped for good.
    private func checkStart() {
        guard !ended else { return }
        guard startWatch.due(now: Date()) else {
            // Woken before the deadline (the sleep keeps the phone's uptime,
            // the deadline the wall clock, which can step back): wake again
            // for it, so the countdown is never left without a wake.
            if startWatch.deadline != nil { scheduleStartCheck() }
            return
        }
        if suspended || needsReload || stopped != nil { return }
        guard UIApplication.shared.applicationState == .active else {
            // Not in front, yet not counted as away: look again shortly.
            scheduleStartCheck(after: 5)
            return
        }
        guard claimStart() else { return }
        telemetry.note(error: "start: no ready after \(Int(ArcadeStartWatch.limit)) s (status: \(status))")
        status = ArcadeStartWatch.status
        sayStartLine(ArcadeStartWatch.failureLine(couldNotStart: false, newerPlayer: launch.newerPlayer))
    }

    private func setMode(_ next: String) {
        guard next != mode else { return }
        mode = next
        pad?.setMode(next)
        input.mode = next
        // A new fight gets its own pad isn't held line.
        if next == "menu" || next == "demo" { watchdogWarned = false }
    }

    /// The page's sound can sit suspended until a user gesture even with
    /// autoplay allowed (WebKit bug 256075), and the web view takes no touches
    /// of its own. evaluateJavaScript counts as a gesture, so the app wakes it:
    /// when the page starts, when it is ready (after every restart too), and
    /// when it says its sound stopped while the game should be playing (then
    /// at most once a second). Never under Pad practice: the game stays
    /// frozen until it closes (the kit's own suspend reports its sound
    /// stopped, and waking it then would start the game again).
    private func wakeAudio(force: Bool) {
        guard !suspended, !ended, !practicing else { return }
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

    // MARK: Where the sound goes, and the sound choices (Oct 19 2026)

    /// The kit's 'settings' (all of them, whenever they change): kept as
    /// given, routes included, for the next start, and shown in Settings.
    /// The plain player's are only read for how the game ran: it keeps none
    /// (settingsKey), so it starts every time with the app's switches alone.
    private func keepKitSettings(_ settings: [String: Any]) {
        if let sound = ArcadeKitSound(settings) { kitSound = sound }
        guard let key = settingsKey else { return }
        kitSettings = settings
        // Oct 20 2026: the kit's own touch choices, and the fight tier the pad uses.
        touchChoices = ArcadeTouchChoices(settings: settings)
        if touchTable.tier != touchChoices.fightControls {
            touchTable.tier = touchChoices.fightControls
            pad?.setTable(touchTable)
        }
        if saves?.keepSettings(settings, gameId: key) != true {
            telemetry.note(error: "the game's settings could not be kept")
        }
    }

    /// Show the game picture to a ready page (revivalKit.setSettings).
    private func sendPicture() {
        pictureSent = showPicture
        evaluate(ArcadeJS.setSettings(ArcadeKitSettings.picture(full: showPicture)))
    }

    /// The audio route changed (headphones in or out, AirPlay, a car): the
    /// kit is told once it has settled for 300 ms, as one change can come
    /// as several notifications.
    private func routeChanged() {
        routeCheck?.cancel()
        routeCheck = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return   // a newer change came first
            }
            guard !Task.isCancelled else { return }
            self?.sendRoute()
        }
    }

    /// revivalKit.setOutput with the route's word, only when it differs from
    /// the last one this page was told (the kit says a change aloud), and
    /// only to a ready page in front: one starting is told at 'ready', and
    /// her return looks again.
    private func sendRoute() {
        guard !ended, pageReady, !suspended, let web = webView else { return }
        let ports = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { ArcadeAudioPort(type: $0.portType.rawValue, name: $0.portName) }
        guard let route = ArcadeAudioRoute.of(ports), route != routeSent else { return }
        routeSent = route
        web.evaluateJavaScript(ArcadeJS.setOutput(route)) { [weak self] result, _ in
            guard let self, !self.ended, let state = result as? [String: Any],
                  let sound = ArcadeKitSound(state) else { return }
            self.kitSound = sound
            self.applySpeakerCalls()
        }
    }

    /// Oct 20 2026: the touch choices for a ready page: the kit's own (kept,
    /// or the defaults), Pause when I leave the pad and her touch timing.
    private func sendTouchSettings() {
        guard !isPlain else { return }
        var partial: [String: Any] = ["touchTiming": timing.kitValue]
        // Touch-input choices: a keyboard or controller player keeps the demo fight.
        if pageInputType == "touch" { partial["pauseOnLeave"] = pauseOnLeave }
        if touchTable.hasTiers {
            partial["fightControls"] = touchChoices.fightControls
            partial["walkIn"] = touchChoices.walkIn
            // Only her own (or kept) choice: otherwise the kit's default, on for touch input only.
            if let skipDemo = touchChoices.skipDemo { partial["skipDemo"] = skipDemo }
            if let lessDamage = touchChoices.lessDamage { partial["lessDamage"] = lessDamage }
        }
        evaluate(ArcadeJS.setSettings(partial))
    }

    /// Warnings on the phone speaker: the kit keeps calls per route, so her
    /// choice is given to it while a touch player is on the speaker.
    private func applySpeakerCalls() {
        guard !isPlain, pageReady, pageInputType == "touch", let sound = kitSound, sound.output == .speaker,
              sound.calls != speakerWarnings.calls else { return }
        chooseCalls(speakerWarnings.calls)
    }

    /// The start-up warnings, once per open, in the kit's queue after its
    /// first line, as a class it never drops: a screen line lasts 3 s and goes
    /// with the next screen, and the legal page and title come within seconds,
    /// so Lockdown Mode (the reason for a silent game) would be lost. They
    /// stay in the Status button's value too.
    private func sendWarnings() {
        guard !warningsSent else { return }
        warningsSent = true
        let lines = warnings()
        startWarnings = lines
        if !lines.isEmpty { say(lines.joined(separator: " "), cls: "teach") }
    }

    /// The Status button's value: the status, then any start-up warnings.
    var statusValue: String {
        startWarnings.isEmpty ? status : status + ". " + startWarnings.joined(separator: " ")
    }

    /// Sound world from the game's Settings: 'stereo', '3d' or 'off'. The
    /// kit keeps it for the route in use; its 'settings' event confirms.
    /// Only on a ready page, which has been told the route: before that the
    /// kit would keep the choice for the route of the last session.
    func chooseSoundWorld(_ world: String) {
        guard pageReady, let world = ArcadeKitSettings.soundWorld(world), kitSound != nil,
              kitSound?.soundWorld != world else { return }
        kitSound?.soundWorld = world
        evaluate(ArcadeJS.setSettings(["soundWorld": world]))
    }

    /// Position calls from the game's Settings: 'all', 'urgent' or 'off'.
    func chooseCalls(_ calls: String) {
        guard pageReady, let calls = ArcadeKitSettings.calls(calls), kitSound != nil, kitSound?.calls != calls else { return }
        kitSound?.calls = calls
        evaluate(ArcadeJS.setSettings(["calls": calls]))
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

    /// The app's own line said here, not by the game's voice: VoiceOver in
    /// her own voice and rate, or the phone's own speech with VoiceOver off,
    /// one at a time (ArcadeSpeechQueue). Oct 20 2026: `urgent` no longer
    /// jumps ahead (the kit orders the game's lines); `flush` (her own
    /// action) cuts the line being said.
    func speak(_ text: String, urgent: Bool, flush: Bool) {
        nativeLine(text, id: nil, cls: urgent ? "alert" : "screen", interrupts: flush)
    }

    /// The app's own line (warnings, Pad on., the watchdog): through the
    /// kit's one queue when the page has it (from the kit's boot, well before
    /// 'ready'), so it never talks over the game's voice; else said here in turn.
    func say(_ text: String, cls: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !ended else { return }
        guard let web = webView else {
            nativeLine(clean, id: nil, cls: cls, interrupts: false)
            return
        }
        web.evaluateJavaScript(ArcadeJS.say(clean, cls: cls)) { [weak self] result, _ in
            guard let self, !self.ended else { return }
            if (result as? Bool) != true { self.nativeLine(clean, id: nil, cls: cls, interrupts: false) }
        }
    }

    /// One line into the queue (the kit's native item with its id, or the app's own).
    private func nativeLine(_ text: String, id: String?, cls: String, interrupts: Bool) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !ended else {
            // Nothing to say: done at once, so the kit's queue moves on.
            if let id { evaluate(ArcadeJS.spoken(id: id, ok: true)) }
            return
        }
        runSpeech(speech.add(ArcadeSpeechItem(id: id, text: clean, cls: cls, interrupts: interrupts), now: speechClock))
    }

    private var speechClock: Double { ProcessInfo.processInfo.systemUptime * 1000 }

    private func runSpeech(_ steps: [ArcadeSpeechStep]) {
        for step in steps {
            switch step {
            case .post(let item): postSpeech(item)
            case .ack(let id, let ok): evaluate(ArcadeJS.spoken(id: id, ok: ok))
            case .stop: speaker?.stopSpeaking(at: .immediate)
            case .silence:
                speaker?.stopSpeaking(at: .immediate)
                ArcadeVoiceOverCut.now()
            }
        }
        scheduleSpeechCheck()
    }

    private func postSpeech(_ item: ArcadeSpeechItem) {
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
                string: item.text, attributes: [.accessibilitySpeechQueueAnnouncement: NSNumber(value: !item.interrupts)]))
        } else {
            let synthesizer: AVSpeechSynthesizer
            if let speaker {
                synthesizer = speaker
            } else {
                synthesizer = AVSpeechSynthesizer()
                synthesizer.delegate = self
                speaker = synthesizer
            }
            if item.interrupts { synthesizer.stopSpeaking(at: .immediate) }
            let utterance = AVSpeechUtterance(string: item.text)
            utterance.prefersAssistiveTechnologySettings = true
            synthesizer.speak(utterance)
        }
    }

    /// The line being said ended (VoiceOver or the phone's speech).
    fileprivate func speechEnded(text: String?, ok: Bool) {
        guard !ended else { return }
        runSpeech(speech.finished(text: text, ok: ok, now: speechClock))
    }

    /// The one wake for a line that never ends.
    private func scheduleSpeechCheck() {
        speechCheck?.cancel()
        speechCheck = nil
        guard let deadline = speech.deadline else { return }
        let wait = max(0, deadline - speechClock) / 1000 + 0.02
        speechCheck = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, !self.ended else { return }
            self.runSpeech(self.speech.expire(now: self.speechClock))
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
        stopStartCheck()
        suspendToken += 1
        let token = suspendToken
        pad?.releaseAll()
        input.releaseAll()
        if mode == "fight" {
            pausedForAway = true
            pauseFight()
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
        // A start failure that came while she was away is said now.
        sayHeldStartLine()
        // Pad practice keeps the game frozen until it closes.
        if !practicing { evaluate(ArcadeJS.resume) }
        // The route may have changed while she was away (headphones taken
        // off on a call): the kit hears of it now.
        routeChanged()
        if pausedForAway {
            pausedForAway = false
            say("The game is paused. Press Pause on the strip, or two-finger double-tap the pad, to play on.", cls: "screen")
        }
    }

    private func interrupted(_ began: Bool) {
        if began { suspendGame() } else { resumeGame() }
    }

    private func callChanged(_ active: Bool) {
        if active { suspendGame() } else { resumeGame() }
    }

    private func headphonesGone() {
        let fighting = mode == "fight"
        if fighting { pauseFight() }
        // Oct 19 2026: a game page told the route (its kit answered
        // setOutput) with its own words for it says the new route itself, in
        // the game's voice, once the route settles, and reads its pause
        // screen: the app's line would be said on top of both, and it said
        // "Headphones" when AirPlay or a TV went too. The plain player and an
        // older game player still hear the app's line.
        let gameSaysRoute = !isPlain && pageReady && kitSound != nil && gameSaysRoutes
        if let line = ArcadeAudioRoute.lostLine(fighting: fighting, gameSaysRoute: gameSaysRoute) {
            speak(line, urgent: true, flush: true)
        }
    }

    private func mediaReset() {
        telemetry.note(error: "the phone's media services restarted")
        // Pad practice keeps the game frozen until it closes.
        if !suspended && !practicing { evaluate(ArcadeJS.resume) }
    }

    // Mid-game phone news goes through the kit's one queue, in turn, never over the game's voice (R1).

    private func powerChanged() {
        telemetry.environment = environment()
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            say("Low Power Mode is on, so the game may run at half speed.", cls: "flow")
        }
    }

    private func thermalChanged() {
        telemetry.environment = environment()
        switch ProcessInfo.processInfo.thermalState {
        case .serious: say("The phone is getting warm, so the game may slow down.", cls: "flow")
        case .critical: say("The phone is very hot. The game will stutter until it cools.", cls: "flow")
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
        // Oct 19 2026: what the kit made of the route, and her choices there.
        var gameSound = "not known"
        if let sound = kitSound {
            gameSound = sound.soundWorld + ", calls " + sound.calls
            if let output = sound.output { gameSound += " on " + output.rawValue }
        }
        return [
            "device": machine,
            "iOS": UIDevice.current.systemVersion,
            "app": "\(version) (\(build))",
            "low power": ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off",
            "thermal": thermal,
            "lockdown": lockdownOn ? "on" : "off",
            "VoiceOver": UIAccessibility.isVoiceOverRunning ? "on" : "off",
            "audio route": route.isEmpty ? "none" : route,
            "game sound": gameSound,
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
        // An older load's failure (one a restart replaced) is only noted: the
        // current load's status, line and countdown are left alone. (A load
        // WebKit gave no navigation for counts every failure as its own.)
        let current = navigation == nil || pageNavigation == nil || navigation === pageNavigation
        telemetry.note(error: "load: " + error.localizedDescription + (current ? "" : " (an older load)"))
        guard current else { return }
        status = "The game page did not load"
        // This load's failure says its own line: the start countdown has
        // nothing to add. Away, the line waits for her return.
        _ = claimStart()
        sayStartLine("The game page did not load. Leave the game and try again, or delete the download and get it again.")
    }

    /// iOS ended the page's process (usually memory). Restart it and say so,
    /// unless it keeps happening.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !ended else { return }
        telemetry.terminations += 1
        pad?.releaseAll()
        // No page to tell anything until it is started again.
        pageReady = false
        kitSound = nil
        // Away: restart when she is back (resumeGame), so nothing starts
        // playing behind another app; and a process iOS ends in the
        // background does not count toward giving up.
        if suspended || UIApplication.shared.applicationState != .active {
            suspended = true
            startWatch.away()
            stopStartCheck()
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
            _ = claimStart()
            startLinePending = nil
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
    @State private var showScreenText = false
    @State private var showHowToPlay = false
    /// Oct 20 2026: the strip reaches the very top of the screen (the
    /// status bar is hidden), so touching there brings VoiceOver back.
    @State private var stripTop: CGFloat = 0

    init(launch: ArcadeLaunch, apiClient: KadeAPIClient, onClose: @escaping (String) -> Void) {
        _host = StateObject(wrappedValue: ArcadeGameHost(launch: launch))
        self.apiClient = apiClient
        self.onClose = onClose
    }

    /// While the pad is held in a fight, an edge flick plays rather than opening Control Center or going Home.
    private var defersEdges: Bool {
        host.mode == "fight" && (host.padHeld || !voiceOverOn)
    }

    var body: some View {
        GeometryReader { proxy in
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
                .alert(ArcadeTouchLines.offerTitle, isPresented: $host.offeringPractice) {
                    Button(ArcadeTouchLines.offerLearn) { host.answerOffer(learn: true) }
                    Button(ArcadeTouchLines.offerPlay, role: .cancel) { host.answerOffer(learn: false) }
                } message: {
                    Text("Pad practice teaches the game pad with nothing at stake. It is also in the game's Settings.")
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .onAppear { stripTop = proxy.safeAreaInsets.top }
            .onChange(of: proxy.safeAreaInsets.top) { _, top in stripTop = top }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .defersSystemGestures(on: defersEdges ? .vertical : [])
        .persistentSystemOverlays(defersEdges ? .hidden : .automatic)
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
        .sheet(isPresented: $showScreenText) {
            ArcadeScreenTextView(host: host)
        }
        .sheet(isPresented: $showHowToPlay) {
            ArcadeHowToPlayView(host: host)
        }
        .fullScreenCover(isPresented: $host.practicing, onDismiss: { host.practiceClosed() }) {
            ArcadePadPracticeView(host: host)
        }
        // While a sheet covers the game, a keyboard's presses are not play.
        .onChange(of: showSettings) { _, _ in updateKeysElsewhere() }
        .onChange(of: showScreenText) { _, _ in updateKeysElsewhere() }
        .onChange(of: showHowToPlay) { _, _ in updateKeysElsewhere() }
        .onChange(of: host.practicing) { _, _ in updateKeysElsewhere() }
    }

    private func updateKeysElsewhere() {
        host.keysElsewhere = showSettings || showScreenText || showHowToPlay || host.practicing
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
            // Oct 19 2026: every line of the game's screen as a list to swipe
            // through. The plain player reads no screen, so it has none.
            if !host.isPlain {
                stripButton("Screen text", spoken: "Screen text", symbol: "text.alignleft",
                            hint: "Lists every line of the game's screen. Pauses a fight first.") {
                    host.pauseIfFighting()
                    showScreenText = true
                }
            }
            // Oct 20 2026: the controls in plain text, and Pad practice.
            stripButton("How to play", spoken: "How to play", symbol: "hand.tap",
                        hint: "Lists the pad's gestures for menus and fights. Pauses a fight first.") {
                host.pauseIfFighting()
                showHowToPlay = true
            }
            stripButton("Pad practice", spoken: "Pad practice", symbol: "graduationcap",
                        hint: "Practise every gesture with nothing at stake, about three minutes. Pauses a fight first.") {
                host.openPractice()
            }
            stripButton("Settings", spoken: "Settings", symbol: "gearshape",
                        hint: "The picture, sound, touch, speech, haptics, and Report a problem with this game. Pauses a fight first.") {
                host.pauseIfFighting()
                showSettings = true
            }
        }
        .padding(.horizontal, 4)
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
            .accessibilityValue(host.statusValue)
            .accessibilityAction(named: "Help") { host.info("help") }
        } else {
            stripButton("Status", spoken: "Status", symbol: "heart.text.square",
                        hint: "Says your health. The Actions rotor has time, where everyone is, facing and help.") { host.info("health") }
                .accessibilityValue(host.statusValue)
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
                .onLongPressGesture(minimumDuration: 1) { leave() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Leave game")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { host.askingLeave = true }
        }
    }

    /// At least 64 points tall below the top inset, and reaching the very
    /// top of the screen, so the whole strip is a target for her finger.
    private func stripLabel(_ title: String, symbol: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
            Text(title)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .foregroundStyle(.white)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, minHeight: 64 + stripTop, alignment: .bottom)
        .contentShape(Rectangle())
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

/// Oct 20 2026: How to play, the pad's gestures in plain VoiceOver text, from
/// the game's own table and its words: menus, then the fight controls in use.
struct ArcadeHowToPlayView: View {
    @ObservedObject var host: ArcadeGameHost
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(host.howToPlay.enumerated()), id: \.offset) { _, section in
                    Section(section.title) {
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                            Text(row)
                        }
                    }
                }
                Section {
                    Text("Touch the very top of the screen to get VoiceOver back. Double-tap the pad, then touch once, to take it again.")
                }
            }
            .navigationTitle("How to play")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
                if !host.isPlain { soundSection }
                touchSection
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

    /// Oct 20 2026: the game pad. The kit's own choices (Fight controls,
    /// Walk in for me, Less damage, Skip the demo fight, Teach me again) for
    /// a game with fight tiers; the app's own (warnings on the speaker, touch
    /// timing, how the pad takes hold, pausing on leaving the pad, the
    /// chimes) for every game; and Pad practice.
    @ViewBuilder
    private var touchSection: some View {
        Section {
            if host.hasFightTiers {
                Picker("Fight controls", selection: Binding(
                    get: { host.touchChoices.fightControls },
                    set: { host.chooseFightControls($0) })) {
                    Text("Easy").tag("easy")
                    Text("Full").tag("full")
                }
                Toggle("Walk in for me", isOn: Binding(
                    get: { host.touchChoices.walkIn }, set: { host.setKitTouch("walkIn", $0) }))
                Toggle("Less damage", isOn: Binding(
                    get: { host.touchChoices.lessDamageShown }, set: { host.setKitTouch("lessDamage", $0) }))
                Toggle("Skip the demo fight", isOn: Binding(
                    get: { host.touchChoices.skipDemoShown(touch: host.isTouchPlayer) }, set: { host.setKitTouch("skipDemo", $0) }))
            }
            if !host.isPlain {
                Picker("Warnings on the phone speaker", selection: $host.speakerWarnings) {
                    ForEach(ArcadeSpeakerWarnings.allCases, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
            }
            Picker("Touch timing", selection: Binding(
                get: { host.timing.choice }, set: { host.chooseTiming($0) })) {
                ForEach(ArcadeTouchTiming.allCases, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            Picker("Pad takes hold", selection: $host.takesHoldAtOnce) {
                Text("After a double-tap").tag(false)
                Text("At once").tag(true)
            }
            if !host.isPlain {
                Toggle("Pause when I leave the pad", isOn: $host.pauseOnLeave)
            }
            Toggle("Pad chimes", isOn: $host.chimesOn)
            if host.hasFightTiers {
                Button("Teach me again") { host.teachAgain() }
            }
            Button("Pad practice") {
                dismiss()
                host.openPracticeSoon()
            }
        } header: {
            Text("Touch")
        } footer: {
            Text("Fitted to me comes from Pad practice; until then it is the same as Relaxed. Quick is the old quarter-second timing. Teach me again brings the lesson back at your next fight.")
        }
    }

    /// Oct 19 2026: the kit's sound world and position calls, for whatever
    /// she is listening on now (the kit keeps a choice per route, and each
    /// picker names it). Shown once the page is ready and has been told the
    /// route, as the running page says them; an older game player has neither.
    @ViewBuilder
    private var soundSection: some View {
        Section {
            if host.pageReady, let sound = host.kitSound {
                if let output = sound.output {
                    LabeledContent("Listening on", value: output.spoken)
                }
                Picker(sound.label("Sound world"), selection: Binding(
                    get: { host.kitSound?.soundWorld ?? "stereo" },
                    set: { host.chooseSoundWorld($0) })) {
                    Text("Stereo").tag("stereo")
                    Text("3D sound, uses more battery").tag("3d")
                    Text("The game's own sound").tag("off")
                }
                if sound.output == .speaker && host.isTouchPlayer {
                    // Oct 20 2026: on the speaker, Touch's Warnings on the phone speaker sets the calls.
                    LabeledContent("Position calls", value: host.speakerWarnings.label)
                } else {
                    Picker(sound.label("Position calls"), selection: Binding(
                        get: { host.kitSound?.calls ?? "all" },
                        set: { host.chooseCalls($0) })) {
                        Text("All").tag("all")
                        Text("Urgent only").tag("urgent")
                        Text("Attacks only").tag("alerts")
                        Text("Off").tag("off")
                    }
                }
            } else {
                Text(host.pageReady ? "This version of the game player has no sound choices."
                                    : "The sound choices appear once the game has started.")
            }
        } header: {
            Text("Sound")
        } footer: {
            Text(ArcadeKitSound.footer)
        }
    }
}

/// Oct 19 2026: every line of the game's screen, from the kit's latest
/// 'lines' event, as plain rows to swipe through with VoiceOver; the title is
/// the screen's name. It follows the game while it is open. With no rows it
/// says why: not started yet, a game player older than the list, or a
/// screen with no text (ArcadeScreenText.sheetLine).
struct ArcadeScreenTextView: View {
    @ObservedObject var host: ArcadeGameHost
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let line = ArcadeScreenText.sheetLine(host.screenText, pageReady: host.pageReady) {
                    Text(line)
                } else if let text = host.screenText {
                    ForEach(Array(text.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                }
            }
            .navigationTitle(host.screenTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Oct 20 2026: with VoiceOver off, the phone's own speech ends a line. A
/// cancelled one was cut by the queue itself (stopSpeaking): it ends as not
/// spoken, which the queue knows as its own cut.
extension ArcadeGameHost: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor [weak self] in self?.speechEnded(text: text, ok: true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor [weak self] in self?.speechEnded(text: text, ok: false) }
    }
}

/// Oct 20 2026: VoiceOver has no call to stop an announcement; a new one
/// posted without queueing cuts the one being said. Quiet and the kit's cuts
/// post a single space, which says nothing (to be confirmed on her phone).
@MainActor
enum ArcadeVoiceOverCut {
    static func now() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
            string: " ", attributes: [.accessibilitySpeechQueueAnnouncement: NSNumber(value: false)]))
    }
}
