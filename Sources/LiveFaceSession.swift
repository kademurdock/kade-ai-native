import AVFoundation
import SwiftUI
import UIKit
import WebKit

/// Oct 28 2026: THE LIVE VIDEO FACE. A character's painting, driven live by
/// the audio of whatever it is saying, streamed back as video and shown on
/// the big stage in place of the painted rig. Kade's picture: "like Marco
/// Polo or WhatsApp where for sighted people, listening to a voice message
/// would trigger a video... and calls would be video calls."
///
/// How it runs (mirrors the Clubhouse engine, the app's proven WebKit lane):
/// the server mints a session for this account (POST /api/kade/live-face/
/// session; it refuses unless the account has said it uses the screen), the
/// phone loads kademurdock.com/live-face with the session in the URL
/// FRAGMENT, that page joins the face service's room and plays the video,
/// and the app pushes each spoken clip into it as PCM16 16 kHz over
/// `window.face.audio(base64)`. A chat clip is heard FROM the page (mouth and
/// voice stay together); a call loads the page muted and only feeds it, so
/// the call's own engine keeps its echo cancellation.
///
/// Every failure falls back to the painted rig the same second: the stage
/// shows the painting until the first frame arrives and again the moment
/// the session ends. Nothing here ever runs for a blind account or under
/// VoiceOver (LiveFacePolicy, tested).
@MainActor
final class LiveFaceSession: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = LiveFaceSession()

    enum State: Equatable {
        case idle
        case connecting(String)
        case live(String)
    }

    enum ClipOutcome {
        /// The page played it; the caller is done.
        case played
        /// The session was not up for this clip: play it locally as before.
        case notTaken
        /// The page could not play it. The session has been closed; the
        /// caller plays the clip locally so nothing is lost.
        case failed
    }

    @Published private(set) var state: State = .idle
    /// True once the page has drawn a frame; the stage shows the painting
    /// underneath until then so nothing ever flashes white.
    @Published private(set) var firstFrame = false
    /// Published so the stage attaches the web view the moment it exists.
    @Published private(set) var webView: WKWebView?

    private var lane: LiveFaceLane = .chat
    private var agentID: String?
    private var sessionID: String?
    private var openedAt: Date?
    private var usageReported = false

    /// What the stage on screen asked for, kept across a drop so the face can
    /// come back (after the service's idle timeout, a crashed page, or the
    /// app returning from the background). Cleared only when the stage goes.
    private var wanted: (agentID: String, lane: LiveFaceLane, motionAllowed: Bool)?
    /// Drops in a row without a clip getting through; three and it stops
    /// trying until the stage is shown again, so a broken service never loops.
    private var dropsInARow = 0

    // The clip the page is playing.
    private var clipBytes = Data()
    private var clipOffset = 0          // bytes into clipBytes the page started from
    private var clipStartedAt: Date?
    private var envelope: [Float] = []
    private var sawSilentSince: Date?
    private var sawSpeak = false
    private var pausedAtOffset: Int?
    private var resumeRequested = false

    // Call audio, batched: one converter per session, flushed every ~200 ms.
    private var callConverter: AVAudioConverter?
    private var callConverterInput: AVAudioFormat?
    private var callPending = Data()
    private var callFlushScheduled = false

    /// Server truth about the service, refreshed now and then.
    private var serverEnabled = false
    private var serverAgents: Set<String> = []
    private var configFetchedAt: Date?
    private var sightPulledAt: Date?
    private let client = KadeAPIClient()
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close(reason: "background", keepWanted: true) }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dropsInARow = 0
                Task { await self.reopenIfWanted() }
            }
        })
        observers.append(center.addObserver(forName: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckGates() }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckGates() }
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckGates() }
        })
    }

    // MARK: Attaching to a stage

    func shows(agentID: String?) -> Bool {
        guard let agentID else { return false }
        switch state {
        case .connecting(let id), .live(let id): return id == agentID
        case .idle: return false
        }
    }

    var isLive: Bool {
        if case .live = state { return true }
        return false
    }

    private var sight: String { UserDefaults.standard.string(forKey: SightSetting.key) ?? SightSetting.unset }
    private var liveFacesOn: Bool {
        UserDefaults.standard.object(forKey: LiveFaceSetting.key) as? Bool ?? LiveFaceSetting.defaultOn
    }

    private func refusal(agentID: String?, motionAllowed: Bool) -> LiveFaceRefusal? {
        LiveFacePolicy.refusal(sight: sight, liveFaces: liveFacesOn,
            voiceOver: UIAccessibility.isVoiceOverRunning, serverEnabled: serverEnabled,
            agents: serverAgents, agentID: agentID,
            motionAllowed: motionAllowed && !ProcessInfo.processInfo.isLowPowerModeEnabled, stage: true)
    }

    /// A big stage appeared (or its inputs changed) for this character. Opens
    /// a session when the account, the phone and the server all say yes, and
    /// closes a running one the moment any of them says no.
    func attach(agentID: String?, lane: LiveFaceLane, motionAllowed: Bool) async {
        if let agentID { wanted = (agentID, lane, motionAllowed) } else { wanted = nil }
        dropsInARow = 0
        // The account's answer follows the person across devices; reading it
        // costs nothing and never opens anything.
        await pullSightIfNeeded()
        // Cheap answers first: a blind account never asks for the service.
        guard sight == SightSetting.sighted, liveFacesOn, !UIAccessibility.isVoiceOverRunning, motionAllowed else {
            if state != .idle { close(reason: "gate", keepWanted: true) }
            return
        }
        await refreshConfigIfNeeded()
        if let why = refusal(agentID: agentID, motionAllowed: motionAllowed) {
            KadeBreadcrumbs.drop("live-face: closed (\(why))")
            if state != .idle { close(reason: "gate", keepWanted: true) }
            return
        }
        guard let agentID else { return }
        if shows(agentID: agentID), self.lane == lane { return }
        if state != .idle { close(reason: "switch", keepWanted: true) }
        await open(agentID: agentID, lane: lane)
    }

    /// The stage went away (left the chat, hung up): close and bill.
    func detach(agentID: String?) {
        if let agentID, wanted?.agentID == agentID { wanted = nil }
        guard shows(agentID: agentID) else { return }
        close(reason: "detach", keepWanted: false)
    }

    /// After a drop: bring the face back for the stage still on screen. The
    /// clip that noticed the drop plays locally; the next one has video.
    func reopenIfWanted() async {
        guard state == .idle, let w = wanted, dropsInARow < 3,
              UIApplication.shared.applicationState != .background else { return }
        await attach(agentID: w.agentID, lane: w.lane, motionAllowed: w.motionAllowed)
    }

    /// A gate may have flipped (VoiceOver, Low Power, the account's answer,
    /// the switch). Closes a running face that is no longer allowed.
    private func recheckGates() {
        guard state != .idle, let w = wanted else { return }
        if refusal(agentID: w.agentID, motionAllowed: w.motionAllowed) != nil {
            close(reason: "gate", keepWanted: true)
        }
    }

    private func open(agentID: String, lane: LiveFaceLane) async {
        self.lane = lane
        self.agentID = agentID
        state = .connecting(agentID)
        firstFrame = false
        var req = client.request(path: "api/kade/live-face/session", method: "POST", authorized: true, timeout: 20)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["agentId": agentID, "lane": lane.rawValue])
        guard let (data, http) = try? await client.send(req), http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["sessionToken"] as? String, !token.isEmpty,
              let sid = json["sessionId"] as? String, !sid.isEmpty else {
            KadeBreadcrumbs.drop("live-face: no session for \(agentID)")
            if case .connecting(let id) = state, id == agentID { state = .idle }
            dropsInARow += 1
            return
        }
        guard case .connecting(let still) = state, still == agentID else { return }
        let ws = (json["ws"] as? String) ?? "wss://api.simli.ai"
        sessionID = sid
        openedAt = Date()
        usageReported = false
        load(token: token, ws: ws, muted: LiveFacePolicy.pageMuted(lane: lane))
    }

    private func load(token: String, ws: String, muted: Bool) {
        teardownWebView()
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(LiveFaceScriptHandler(self), name: "face")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.backgroundColor = .clear
        web.isAccessibilityElement = false
        web.accessibilityElementsHidden = true
        web.isUserInteractionEnabled = false
        webView = web
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        let frag = "st=\(enc(token))&ws=\(enc(ws))&mute=\(muted ? 1 : 0)"
        if let url = URL(string: "https://kademurdock.com/live-face#\(frag)") {
            web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }

    private func teardownWebView() {
        if let web = webView {
            web.navigationDelegate = nil
            web.configuration.userContentController.removeScriptMessageHandler(forName: "face")
            web.stopLoading()
            web.load(URLRequest(url: URL(string: "about:blank")!))
            web.removeFromSuperview()
        }
        webView = nil
    }

    /// Ends the session, bills what ran, and drops back to the painting.
    /// `keepWanted` keeps the stage's wish so the face can come back.
    private func close(reason: String, keepWanted: Bool) {
        KadeBreadcrumbs.drop("live-face: close (\(reason))")
        webView?.evaluateJavaScript("window.face && window.face.end()", completionHandler: nil)
        reportUsage()
        teardownWebView()
        state = .idle
        firstFrame = false
        clipStartedAt = nil
        clipBytes = Data()
        envelope = []
        pausedAtOffset = nil
        resumeRequested = false
        callConverter = nil
        callConverterInput = nil
        callPending = Data()
        agentID = nil
        sessionID = nil
        if !keepWanted { wanted = nil }
    }

    func stop() { close(reason: "stop", keepWanted: false) }

    /// The person interrupted: drop whatever the page still has queued.
    func interrupt() {
        webView?.evaluateJavaScript("window.face && window.face.clear()", completionHandler: nil)
        clipStartedAt = nil
        clipBytes = Data()
        envelope = []
        pausedAtOffset = nil
        resumeRequested = false
    }

    private func reportUsage() {
        guard let openedAt, let sessionID, !usageReported else { return }
        usageReported = true
        let seconds = Int(Date().timeIntervalSince(openedAt).rounded())
        self.openedAt = nil
        guard seconds >= 1 else { return }
        let client = self.client
        Task {
            var req = client.request(path: "api/kade/live-face/usage", method: "POST", authorized: true, timeout: 15)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionID, "seconds": seconds])
            _ = try? await client.send(req)
        }
    }

    // MARK: Page events

    fileprivate func handle(message body: Any) {
        guard let dict = body as? [String: Any], let t = dict["t"] as? String else { return }
        switch t {
        case "start":
            firstFrame = true
            dropsInARow = 0
            if case .connecting(let id) = state { state = .live(id) }
        case "speaking":
            sawSpeak = true
            sawSilentSince = nil
        case "silent":
            sawSilentSince = Date()
        case "error", "stop":
            let why = (dict["why"] as? String) ?? t
            dropsInARow += 1
            close(reason: "\(t): \(why)", keepWanted: true)
        default:
            break
        }
    }

    // The page's process can be killed by iOS (memory, a long background);
    // nothing on the page can say so, so the navigation delegate does.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        dropsInARow += 1
        close(reason: "page process ended", keepWanted: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        dropsInARow += 1
        close(reason: "page failed", keepWanted: true)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        dropsInARow += 1
        close(reason: "page did not load", keepWanted: true)
    }

    // MARK: Feeding audio

    /// Whether a chat clip for this character should go to the page instead
    /// of the local player. Only once the video is actually on screen: before
    /// that the painting is up and the local player keeps the sound on time.
    func takesClip(agentID: String?) -> Bool {
        guard let agentID, lane == .chat, firstFrame, isLive, shows(agentID: agentID) else { return false }
        return true
    }

    /// The glow ring and the mood light read this while the page plays a clip.
    func level() -> Double {
        guard let clipStartedAt, pausedAtOffset == nil, !envelope.isEmpty else { return 0 }
        // The service draws a beat behind the audio it was given.
        let at = Double(clipOffset) / 32000 + Date().timeIntervalSince(clipStartedAt) - 0.25
        guard at >= 0 else { return 0 }
        let i = Int(at * 20)
        guard i < envelope.count else { return 0 }
        return Double(envelope[i])
    }

    var isPlayingClip: Bool { clipStartedAt != nil }
    var isPausedClip: Bool { clipStartedAt != nil && pausedAtOffset != nil }

    /// Pauses the clip the page is playing: drops what it still has queued and
    /// remembers where the voice was, so resume carries on from there.
    func pause() {
        guard let clipStartedAt, pausedAtOffset == nil else { return }
        let played = max(0, Date().timeIntervalSince(clipStartedAt) - 0.25)
        var at = clipOffset + Int(played * 32000)
        at -= at % 2
        pausedAtOffset = min(clipBytes.count, max(0, at))
        webView?.evaluateJavaScript("window.face && window.face.clear()", completionHandler: nil)
    }

    func resume() {
        guard pausedAtOffset != nil else { return }
        resumeRequested = true
    }

    /// Sends clipBytes from `offset` to the page. False when the page refused.
    private func send(from offset: Int, web: WKWebView, cancelled: @MainActor () -> Bool) async -> Bool {
        clipOffset = offset
        clipStartedAt = Date()
        sawSpeak = false
        sawSilentSince = nil
        var at = offset
        while at < clipBytes.count {
            if cancelled() { return true }
            guard isLive, webView === web else { return false }
            let end = min(clipBytes.count, at + LiveFacePolicy.chunkBytes)
            let b64 = clipBytes.subdata(in: at..<end).base64EncodedString()
            guard await evaluate(web, "window.face ? window.face.audio('\(b64)') : false") else { return false }
            at = end
        }
        return true
    }

    /// Plays one spoken clip (WAV or MP3 bytes) through the live face. Returns
    /// once the page reports silence after the speech, or the clip's own
    /// length plus a margin has passed. `onStarted` fires when the first audio
    /// has been handed over, where the local player would have started. Any
    /// failure closes the session and returns .failed, so the caller plays
    /// the clip locally and the face comes back for the next one.
    func playClip(_ data: Data, agentID: String?, onStarted: @MainActor () -> Void,
                  cancelled: @MainActor () -> Bool) async -> ClipOutcome {
        guard takesClip(agentID: agentID), let web = webView else { return .notTaken }
        guard let pcm = await LiveFaceAudio.pcm16(from: data) else { return .notTaken }
        guard takesClip(agentID: agentID), webView === web else { return .notTaken }
        clipBytes = pcm.data
        envelope = pcm.envelope
        pausedAtOffset = nil
        resumeRequested = false
        onStarted()
        func fail(_ why: String) -> ClipOutcome {
            dropsInARow += 1
            close(reason: why, keepWanted: true)
            return .failed
        }
        guard await send(from: 0, web: web, cancelled: cancelled) else { return fail("clip refused") }
        var remaining = pcm.seconds
        var deadline = Date().addingTimeInterval(LiveFacePolicy.clipTimeout(seconds: remaining))
        var earliest = Date().addingTimeInterval(max(0.3, remaining - 0.2))
        while true {
            if cancelled() { break }
            if !isLive || webView !== web { return fail("session ended mid-clip") }
            if let paused = pausedAtOffset {
                if resumeRequested {
                    resumeRequested = false
                    pausedAtOffset = nil
                    guard await send(from: paused, web: web, cancelled: cancelled) else { return fail("resume refused") }
                    remaining = Double(clipBytes.count - paused) / 32000
                    deadline = Date().addingTimeInterval(LiveFacePolicy.clipTimeout(seconds: remaining))
                    earliest = Date().addingTimeInterval(max(0.3, remaining - 0.2))
                    continue
                }
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            if Date() >= deadline { break }
            // Done when the page went silent after speaking, once the clip's
            // own length has passed (short clips can report silence early).
            if Date() >= earliest, sawSpeak, let since = sawSilentSince, Date().timeIntervalSince(since) >= 0.15 { break }
            // No SPEAK at all a second and a half past the clip's length: the
            // page is not playing it. Close it and let the clip play locally.
            if !sawSpeak, Date() >= earliest.addingTimeInterval(1.5) { return fail("no speech from the page") }
            try? await Task.sleep(for: .milliseconds(40))
        }
        if cancelled() { interrupt() }
        clipStartedAt = nil
        dropsInARow = 0
        return .played
    }

    /// A call's agent audio (the call engine's one format) goes to the muted
    /// page so the face follows the voice. One converter per session keeps the
    /// resample continuous; the page gets one batch every ~200 ms.
    func feedCall(_ buffer: AVAudioPCMBuffer, agentID: String?) {
        // A call stage holds one character; a clip without a named speaker is theirs.
        guard lane == .call, isLive, firstFrame, agentID == nil || shows(agentID: agentID), webView != nil else { return }
        if callConverter == nil || callConverterInput != buffer.format {
            callConverter = AVAudioConverter(from: buffer.format, to: LiveFaceAudio.format)
            callConverterInput = buffer.format
        }
        guard let converter = callConverter,
              let data = LiveFaceAudio.pcm16(streaming: buffer, through: converter) else { return }
        callPending.append(data)
        guard !callFlushScheduled else { return }
        callFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            self?.flushCall()
        }
    }

    private func flushCall() {
        callFlushScheduled = false
        guard let web = webView, isLive, !callPending.isEmpty else { callPending = Data(); return }
        let bytes = callPending
        callPending = Data()
        let b64 = bytes.base64EncodedString()
        web.evaluateJavaScript("window.face && window.face.audio('\(b64)')", completionHandler: nil)
    }

    /// True only when the page ran the script and it answered true.
    private func evaluate(_ web: WKWebView, _ js: String) async -> Bool {
        await withCheckedContinuation { cont in
            web.evaluateJavaScript(js) { result, error in
                cont.resume(returning: error == nil && ((result as? Bool) ?? ((result as? NSNumber)?.boolValue ?? false)))
            }
        }
    }

    private func refreshConfigIfNeeded() async {
        if let at = configFetchedAt, Date().timeIntervalSince(at) < 600 { return }
        let req = client.request(path: "api/kade/live-face/config", authorized: true, timeout: 15)
        guard let (data, http) = try? await client.send(req), http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        serverEnabled = (json["enabled"] as? Bool) ?? false
        serverAgents = Set((json["agents"] as? [String]) ?? [])
        configFetchedAt = Date()
    }

    private func pullSightIfNeeded() async {
        if let at = sightPulledAt, Date().timeIntervalSince(at) < 600 { return }
        sightPulledAt = Date()
        await SightService.pull(client: client)
    }
}

/// WKUserContentController retains its handlers strongly; a weak proxy keeps
/// the session (and the web view it owns) collectable.
private final class LiveFaceScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: LiveFaceSession?
    init(_ target: LiveFaceSession) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        Task { @MainActor in
            self.target?.handle(message: body)
        }
    }
}

/// Hosts the session's web view inside the stage, filling its frame.
struct LiveFaceWebView: UIViewRepresentable {
    @ObservedObject var session: LiveFaceSession

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .clear
        host.isAccessibilityElement = false
        host.accessibilityElementsHidden = true
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        guard let web = session.webView else {
            host.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        if web.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            web.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(web)
            NSLayoutConstraint.activate([
                web.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                web.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                web.topAnchor.constraint(equalTo: host.topAnchor),
                web.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
        }
    }
}

/// The account's sight flag, kept on the server so it follows the person
/// across devices (the arcade and the web will read the same answer). The
/// server is the truth: a failed save puts the phone back to what it says.
@MainActor
enum SightService {
    private static var lastPushAt: Date?

    static func pull(client: KadeAPIClient = KadeAPIClient()) async {
        let req = client.request(path: "api/kade/sight", authorized: true, timeout: 15)
        guard let (data, http) = try? await client.send(req), http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        // A save in flight wins over an older read.
        if let lastPushAt, Date().timeIntervalSince(lastPushAt) < 20 { return }
        let sight = (json["sight"] as? String) ?? SightSetting.unset
        let liveFaces = (json["liveFaces"] as? Bool) ?? LiveFaceSetting.defaultOn
        let defaults = UserDefaults.standard
        let value = [SightSetting.sighted, SightSetting.nonvisual].contains(sight) ? sight : SightSetting.unset
        if defaults.string(forKey: SightSetting.key) != value { defaults.set(value, forKey: SightSetting.key) }
        if (defaults.object(forKey: LiveFaceSetting.key) as? Bool) != liveFaces { defaults.set(liveFaces, forKey: LiveFaceSetting.key) }
    }

    static func push(sight: String, liveFaces: Bool) async {
        lastPushAt = Date()
        let client = KadeAPIClient()
        var req = client.request(path: "api/kade/sight", method: "PUT", authorized: true, timeout: 15)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let value: Any = sight.isEmpty ? NSNull() : sight
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sight": value, "liveFaces": liveFaces])
        let saved: Bool
        if let (_, http) = try? await client.send(req) { saved = http.statusCode == 200 } else { saved = false }
        lastPushAt = nil
        if !saved { await pull(client: client) }
    }
}

/// Clip bytes (WAV or MP3, whatever the voice lane returned) to what the face
/// service eats: PCM16 mono 16 kHz, plus a 20 Hz loudness envelope for the
/// stage's glow ring.
enum LiveFaceAudio {
    struct PCM {
        let data: Data
        let seconds: Double
        let envelope: [Float]
    }

    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    static func pcm16(from clip: Data) async -> PCM? {
        await Task.detached(priority: .userInitiated) { () -> PCM? in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("live-face-\(UUID().uuidString).clip")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                try clip.write(to: url)
                let file = try AVAudioFile(forReading: url)
                let src = file.processingFormat
                let frames = AVAudioFrameCount(file.length)
                guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: frames) else { return nil }
                try file.read(into: inBuf)
                return convert(inBuf)
            } catch {
                return nil
            }
        }.value
    }

    /// One call buffer through a converter the caller keeps for the whole
    /// call, so the resample runs on across buffer boundaries.
    static func pcm16(streaming buffer: AVAudioPCMBuffer, through converter: AVAudioConverter) -> Data? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard buffer.frameLength > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(out.frameLength) * 2)
    }

    private static func convert(_ inBuf: AVAudioPCMBuffer) -> PCM? {
        let src = inBuf.format
        guard let converter = AVAudioConverter(from: src, to: format) else { return nil }
        let ratio = format.sampleRate / src.sampleRate
        let outFrames = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outFrames) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        guard status != .error, error == nil, outBuf.frameLength > 0, let ch = outBuf.int16ChannelData else { return nil }
        let count = Int(outBuf.frameLength)
        let data = Data(bytes: ch[0], count: count * 2)
        // 20 Hz RMS envelope, normalised to the clip's own loudest moment.
        let hop = 800
        var env: [Float] = []
        env.reserveCapacity(count / hop + 1)
        var i = 0
        var peak: Float = 0.0001
        while i < count {
            let end = min(count, i + hop)
            var sum: Float = 0
            for j in i..<end {
                let v = Float(ch[0][j]) / 32768
                sum += v * v
            }
            let rms = (sum / Float(max(1, end - i))).squareRoot()
            peak = max(peak, rms)
            env.append(rms)
            i = end
        }
        return PCM(data: data, seconds: Double(count) / format.sampleRate, envelope: env.map { min(1, $0 / peak) })
    }
}
