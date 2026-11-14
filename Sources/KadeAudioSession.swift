import AVFoundation
import UIKit

/// Nov 14 2026: the keeper of the app's own sound session. VoiceOver got
/// quieter once she was in a conversation and louder in any other app,
/// because once anything had played the app's session stayed switched on
/// with nothing playing (see KadeAudioSessionPolicy.swift for the whole
/// story and the rules).
///
/// What it does:
/// - Everything in the app that makes a sound tells it when it sounds and
///   when it stops: voices (paused or not), the thinking bubbles, earcons and
///   chimes, the player sheets, the Parlor, previews, and the books, films,
///   family stories and listen-while-made (which also own the category while
///   they are open). AudioSessionTests lists every player in the source and
///   fails on one that nobody registered.
/// - A moment after the last one stops (and only when no call, room or
///   recording holds the microphone, no book or film owns the mode, and no
///   live face is up), it switches the session off, so VoiceOver is back to
///   its own level inside the app, exactly as it is in other apps.
/// - Just before it lets go it posts `willRelease`, so an engine left
///   running idle (the streamed voice, a paused Library book) stops first.
/// - An audition lets go of the old session first and starts on a fresh one.
///
/// The trail: "audio session: let go (...)", "audio session: let go (...),
/// and something of the app's that was still playing was stopped (...)" (a
/// player the keeper did not know about: the line names the category, mode
/// and route), "audio session: could not let go (...)", and "audio session:
/// switched back on for a voice in N ms" after a release.
/// Phone switch: KadeAppSwitches.audioSessionRelease (Settings >
/// Troubleshooting > "Let go of audio when quiet"; off = the old session
/// that stays on, nothing here switches anything off).
@MainActor
final class KadeAudioSession {
    static let shared = KadeAudioSession()

    /// Posted on the main thread, delivered at once, just before the session
    /// is switched off. Observers stop engines that are running idle.
    static let willRelease = Notification.Name("kadeAudioSessionWillRelease")

    private var holds = KadeAudioHolds()
    private var pendingRelease: Task<Void, Never>?
    /// True from a release until the next sound asks for the session, so the
    /// trail can time that first sound (switching on is a blocking call).
    private(set) var isLetGo = false

    private init() {}

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The name a VoiceService (and its streamed player) holds the session under.
    nonisolated static func voiceName(_ source: ObjectIdentifier) -> String {
        "a voice \(source.debugDescription)"
    }

    // MARK: Sounding and stopping

    /// Something of the app's own sounds until it says it is done.
    func hold(_ who: String) {
        holds.hold(who)
        isLetGo = false
        cancelPendingRelease()
    }

    /// Something sounds for `seconds` and then stops by itself, unless it
    /// calls `letGo` first (a ringtone preview).
    func hold(_ who: String, seconds: TimeInterval) {
        holds.hold(who, now: now, seconds: seconds)
        isLetGo = false
        releaseSoon("\(who) ended")
    }

    /// That holder is quiet now. The session goes once nothing holds it.
    func letGo(_ who: String) {
        guard holds.letGo(who) else { return }
        releaseSoon("\(who) went quiet")
    }

    /// A VoiceService is speaking, has a clip on deck or has one paused
    /// (busy), or has nothing at all.
    func speech(busy: Bool, source: ObjectIdentifier) {
        let who = Self.voiceName(source)
        if busy {
            hold(who)
        } else {
            letGo(who)
        }
    }

    /// `who`'s clip reported itself playing, or will not play: its start
    /// window is over.
    func clipSettled(_ who: String) {
        holds.settled(who)
    }

    /// `who` stopped everything: whatever was starting is not. A release
    /// already waiting is brought forward to match.
    func clipStopped(_ who: String) {
        holds.settled(who)
        if pendingRelease != nil { releaseSoon("speech stopped") }
    }

    /// A sound that ends by itself (an earcon, a chime) started now.
    func shortSound(seconds: TimeInterval) {
        holds.shortSound(now: now, seconds: seconds)
        isLetGo = false
        releaseSoon("a short sound ended")
    }

    // MARK: Books, films, family stories, listen-while-made

    /// `who` sets its own not-mixed category (backgroundListen or film) and
    /// switches the session on. It owns the category until `handBack`; it
    /// holds the session (`hold`/`letGo`) while it plays.
    func take(_ who: String) {
        holds.take(who)
        isLetGo = false
        cancelPendingRelease()
    }

    /// `who` stops. The category goes back to the app's usual mixing
    /// playback only when no other book, film or story is still open (one
    /// closing never changes the category under another), then the session
    /// is let go a moment later if nothing else sounds.
    func handBack(_ who: String) {
        let lastOwner = holds.handBack(who)
        if lastOwner || !KadeAppSwitches.audioSessionRelease {
            try? Self.setCategory(for: .idle)
        }
        releaseSoon("\(who) stopped")
    }

    // MARK: Setting the session up

    /// The playing plan, switched on: `.playback`, `.default`,
    /// `[.mixWithOthers]`. Called right before `who`'s clip starts; the clip
    /// has `startWindow` seconds to report itself (`clipSettled`) before the
    /// session may go.
    func preparePlayback(_ who: String) {
        holds.starting(who, now: now)
        cancelPendingRelease()
        let session = AVAudioSession.sharedInstance()
        try? Self.setCategory(for: .playing)
        let afterRelease = isLetGo
        let asked = now
        try? session.setActive(true)
        isLetGo = false
        if afterRelease {
            KadeBreadcrumbs.drop("audio session: switched back on for a voice in \(Int(((now - asked) * 1000).rounded())) ms")
        }
        releaseSoon("a clip did not start")
    }

    /// Sets the category, mode and options of `activity`'s plan. Throws as
    /// AVAudioSession does; does not switch the session on.
    static func setCategory(for activity: KadeAudioActivity) throws {
        let plan = KadeAudioSessionPolicy.plan(for: activity)
        try AVAudioSession.sharedInstance().setCategory(plan.avCategory, mode: plan.avMode, options: plan.avOptions)
    }

    // MARK: Letting go

    /// Lets go a moment after the last sound, if nothing starts meanwhile.
    func releaseSoon(_ why: String) {
        guard KadeAppSwitches.audioSessionRelease else { return }
        scheduleRelease(after: holds.releaseDelay(now: now), why: why)
    }

    /// Lets go now if nothing holds the session. True when it was let go.
    /// When it is not quiet yet only because a short sound, a timed sound or
    /// a starting clip is still running, it asks again when that is over; a
    /// holder by name, the microphone, a book or a film ask again themselves
    /// when they stop.
    @discardableResult
    func releaseNow(_ why: String) -> Bool {
        cancelPendingRelease()
        let t = now
        holds.prune(now: t)
        let session = AVAudioSession.sharedInstance()
        let category = Self.category(session.category)
        let mode = Self.mode(session.mode)
        let quiet = holds.isQuiet(now: t)
        let moment = KadeAudioSessionPolicy.Moment(
            switchOn: KadeAppSwitches.audioSessionRelease,
            quiet: quiet,
            micHeld: KadeAudioLanes.micHeld,
            liveFaceUp: LiveFaceSession.shared.state != .idle,
            category: category,
            mode: mode)
        guard KadeAudioSessionPolicy.release(moment) == .release else {
            if moment.switchOn, !quiet, let wait = holds.nextCheck(now: t) {
                scheduleRelease(after: wait, why: why)
            }
            return false
        }
        NotificationCenter.default.post(name: Self.willRelease, object: nil)
        // Read before the switch-off, for the trail.
        let shape = "category=\(session.category.rawValue) mode=\(session.mode.rawValue) route=\(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","))"
        let notify = KadeAudioSessionPolicy.notifyOthers(ownerTookOver: holds.ownerTookOver)
        let options: AVAudioSession.SetActiveOptions = notify ? .notifyOthersOnDeactivation : []
        var stoppedSomething = false
        do {
            try session.setActive(false, options: options)
        } catch let error as NSError where error.code == Self.busyCode {
            // Apple: switching off a session with audio still running or
            // paused stops that audio, switches the session off anyway and
            // reports busy. So it IS let go, and something was cut.
            stoppedSomething = true
        } catch {
            KadeBreadcrumbs.drop("audio session: could not let go (\(why)): \(error.localizedDescription) \(shape)")
            return false
        }
        holds.released()
        isLetGo = true
        if let parked = KadeAudioSessionPolicy.parkedActivity(after: category) {
            try? Self.setCategory(for: parked)
        }
        if stoppedSomething {
            KadeBreadcrumbs.drop("audio session: let go (\(why)), and something of the app's that was still playing was stopped (\(shape))")
        } else {
            KadeBreadcrumbs.drop("audio session: let go (\(why))\(notify ? "" : ", other apps not told to start again")")
        }
        return true
    }

    /// AVAudioSession.ErrorCode.isBusy, '!act'.
    private static let busyCode = 0x2161_6374

    private func scheduleRelease(after seconds: TimeInterval, why: String) {
        pendingRelease?.cancel()
        let wait = UInt64(max(0, seconds) * 1_000_000_000)
        pendingRelease = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: wait)
            guard !Task.isCancelled, let self else { return }
            self.pendingRelease = nil
            self.releaseNow(why)
        }
    }

    private func cancelPendingRelease() {
        pendingRelease?.cancel()
        pendingRelease = nil
    }

    // MARK: AVAudioSession values to the plan's names

    private static func category(_ value: AVAudioSession.Category) -> KadeAudioSessionPlan.Category? {
        switch value {
        case .ambient: return .ambient
        case .soloAmbient: return .soloAmbient
        case .playback: return .playback
        case .record: return .record
        case .playAndRecord: return .playAndRecord
        case .multiRoute: return .multiRoute
        default: return nil
        }
    }

    private static func mode(_ value: AVAudioSession.Mode) -> KadeAudioSessionPlan.Mode? {
        switch value {
        case .default: return .standard
        case .spokenAudio: return .spokenAudio
        case .voicePrompt: return .voicePrompt
        case .moviePlayback: return .moviePlayback
        case .voiceChat: return .voiceChat
        case .videoChat: return .videoChat
        case .gameChat: return .gameChat
        case .videoRecording: return .videoRecording
        case .measurement: return .measurement
        default: return nil
        }
    }
}

extension KadeAudioSessionPlan {
    var avCategory: AVAudioSession.Category {
        switch category {
        case .ambient: return .ambient
        case .soloAmbient: return .soloAmbient
        case .playback: return .playback
        case .record: return .record
        case .playAndRecord: return .playAndRecord
        case .multiRoute: return .multiRoute
        }
    }

    var avMode: AVAudioSession.Mode {
        switch mode {
        case .standard: return .default
        case .spokenAudio: return .spokenAudio
        case .voicePrompt: return .voicePrompt
        case .moviePlayback: return .moviePlayback
        case .voiceChat: return .voiceChat
        case .videoChat: return .videoChat
        case .gameChat: return .gameChat
        case .videoRecording: return .videoRecording
        case .measurement: return .measurement
        }
    }

    var avOptions: AVAudioSession.CategoryOptions {
        var out: AVAudioSession.CategoryOptions = []
        for option in options {
            switch option {
            case .mixWithOthers: out.insert(.mixWithOthers)
            case .duckOthers: out.insert(.duckOthers)
            case .interruptSpokenAudioAndMixWithOthers: out.insert(.interruptSpokenAudioAndMixWithOthers)
            case .allowBluetoothHFP: out.insert(.allowBluetooth)
            case .allowBluetoothA2DP: out.insert(.allowBluetoothA2DP)
            case .allowAirPlay: out.insert(.allowAirPlay)
            case .defaultToSpeaker: out.insert(.defaultToSpeaker)
            }
        }
        return out
    }
}

// MARK: - Speak, then wait for VoiceOver to finish

extension KadeAnnounce {
    /// Nov 14 2026: says `text` and returns once VoiceOver has finished
    /// saying it (or `timeout` seconds have passed), so a sound started next
    /// does not begin under VoiceOver's words and its duck. Without VoiceOver
    /// it posts nothing and returns at once (an announcement is VoiceOver's).
    @MainActor
    static func sayThenWait(_ text: String, timeout: TimeInterval = 6) async {
        guard UIAccessibility.isVoiceOverRunning, !text.isEmpty else { return }
        let wait = KadeAnnouncementWait()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wait.start(text: text, timeout: timeout) { continuation.resume() }
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }
}

/// Resumes its waiter once: on VoiceOver's "finished" for that exact text,
/// or at the timeout. Holds itself strongly until then, so the waiter can
/// never be left hanging.
@MainActor
private final class KadeAnnouncementWait {
    private var observer: NSObjectProtocol?
    private var done: (() -> Void)?

    func start(text: String, timeout: TimeInterval, done: @escaping () -> Void) {
        self.done = done
        observer = NotificationCenter.default.addObserver(
            forName: UIAccessibility.announcementDidFinishNotification, object: nil, queue: .main
        ) { note in
            let said = note.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String
            guard said == text else { return }
            MainActor.assumeIsolated { self.finish() }
        }
        let wait = UInt64(max(0, timeout) * 1_000_000_000)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: wait)
            self.finish()
        }
    }

    private func finish() {
        guard let done else { return }
        self.done = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        done()
    }
}
