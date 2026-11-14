import AVFoundation
import UIKit

/// Nov 14 2026: the keeper of the app's own sound session. VoiceOver got
/// quieter once she was in a conversation and louder in any other app,
/// because once anything had played the app's session stayed switched on
/// with nothing playing (see KadeAudioSessionPolicy.swift for the whole
/// story and the rules).
///
/// What it does:
/// - Voices, the thinking bubbles and earcons tell it when they sound and
///   when they stop. A moment after the last one stops (and only when no
///   call, room or recording holds the microphone, no book or film owns the
///   session, and no live face is up), it switches the session off with
///   `.notifyOthersOnDeactivation`, so VoiceOver is back to its own level
///   inside the app, exactly as it is in other apps.
/// - Just before it lets go it posts `willRelease`, so an engine left
///   running (the streamed voice) stops; a running engine keeps the session
///   busy and the switch-off fails.
/// - An audition lets go of the old session first and starts on a fresh one,
///   so a duck from VoiceOver's last words is not carried into the clip.
///
/// The trail: "audio session: let go (...)" and "audio session: could not
/// let go (...)". Phone switch: KadeAppSwitches.audioSessionRelease (false =
/// the old session that stays on, nothing here switches anything off).
@MainActor
final class KadeAudioSession {
    static let shared = KadeAudioSession()

    /// Posted on the main thread, delivered at once, just before the session
    /// is switched off. Observers stop engines that are running idle.
    static let willRelease = Notification.Name("kadeAudioSessionWillRelease")

    private var holds = KadeAudioHolds()
    private var pendingRelease: Task<Void, Never>?
    private var retried = false

    private init() {}

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Sounding and stopping

    /// Something of the app's own sounds until it says it is done.
    func hold(_ who: String) {
        holds.hold(who)
        retried = false
        cancelPendingRelease()
    }

    /// That holder is quiet now. The session goes once nothing holds it.
    func letGo(_ who: String) {
        guard holds.letGo(who) else { return }
        releaseSoon("\(who) went quiet")
    }

    /// A VoiceService is speaking (or has a clip on deck), or has stopped.
    /// Driven by the same busy flag as KadeSpeechFloor.
    func speech(busy: Bool, source: ObjectIdentifier) {
        let who = "a voice \(source.debugDescription)"
        if busy {
            // The clip reported itself; it holds the session by name now.
            holds.settled()
            hold(who)
        } else {
            letGo(who)
        }
    }

    /// A VoiceService stopped everything: whatever was starting is not. A
    /// release already waiting is brought forward to match.
    func clipStopped() {
        holds.settled()
        if pendingRelease != nil { releaseSoon("speech stopped") }
    }

    /// A sound that ends by itself (an earcon, a chime) started now.
    func shortSound(seconds: TimeInterval) {
        holds.shortSound(now: now, seconds: seconds)
        retried = false
        releaseSoon("a short sound ended")
    }

    // MARK: Setting the session up

    /// The playing plan, switched on: `.playback`, `.default`,
    /// `[.mixWithOthers]`. Called right before a clip starts; the clip has
    /// `startWindow` seconds to report itself before the session may go.
    func preparePlayback() {
        holds.starting(now: now)
        retried = false
        cancelPendingRelease()
        let session = AVAudioSession.sharedInstance()
        try? Self.setCategory(for: .playing)
        try? session.setActive(true)
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
    @discardableResult
    func releaseNow(_ why: String) -> Bool {
        cancelPendingRelease()
        let session = AVAudioSession.sharedInstance()
        let category = Self.category(session.category)
        let moment = KadeAudioSessionPolicy.Moment(
            switchOn: KadeAppSwitches.audioSessionRelease,
            quiet: holds.isQuiet(now: now),
            micHeld: KadeAudioLanes.micHeld,
            liveFaceUp: LiveFaceSession.shared.state != .idle,
            category: category,
            mode: Self.mode(session.mode))
        guard KadeAudioSessionPolicy.release(moment) == .release else { return false }
        NotificationCenter.default.post(name: Self.willRelease, object: nil)
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            KadeBreadcrumbs.drop("audio session: could not let go (\(why)): \(error.localizedDescription)")
            if !retried {
                retried = true
                scheduleRelease(after: KadeAudioSessionPolicy.retryDelay, why: why)
            }
            return false
        }
        if let parked = KadeAudioSessionPolicy.parkedActivity(after: category) {
            try? Self.setCategory(for: parked)
        }
        retried = false
        KadeBreadcrumbs.drop("audio session: let go (\(why))")
        return true
    }

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
