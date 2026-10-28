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
final class LiveFaceSession: NSObject, ObservableObject {
    static let shared = LiveFaceSession()

    enum State: Equatable {
        case idle
        case connecting(String)
        case live(String)
        case failed(String, String)
    }

    enum ClipOutcome {
        /// The page played it; the caller is done.
        case played
        /// The session was not up for this clip: play it locally as before.
        case notTaken
        /// The session died mid-clip.
        case failed
    }

    @Published private(set) var state: State = .idle
    /// True once the page has drawn a frame; the stage shows the painting
    /// underneath until then so nothing ever flashes white.
    @Published private(set) var firstFrame = false
    @Published private(set) var speaking = false

    private(set) var webView: WKWebView?
    private var lane: LiveFaceLane = .chat
    private var agentID: String?
    private var openedAt: Date?
    private var clipStartedAt: Date?
    private var envelope: [Float] = []
    private var sawSilentSince: Date?
    private var sawSpeak = false
    private var usageReported = false

    /// Server truth about the service, refreshed now and then.
    private var serverEnabled = false
    private var serverAgents: Set<String> = []
    private var configFetchedAt: Date?
    private var sightPulledAt: Date?
    private let client = KadeAPIClient()

    // MARK: Attaching to a stage

    func shows(agentID: String?) -> Bool {
        guard let agentID else { return false }
        switch state {
        case .connecting(let id), .live(let id): return id == agentID
        default: return false
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

    /// A big stage appeared for this character. Opens a session when the
    /// account, the phone and the server all say yes; otherwise does nothing.
    func attach(agentID: String?, lane: LiveFaceLane, motionAllowed: Bool) async {
        // Cheap answers first, before any network: a blind account never
        // even asks the server.
        guard sight == SightSetting.sighted, liveFacesOn, !UIAccessibility.isVoiceOverRunning else { return }
        await pullSightIfNeeded()
        await refreshConfigIfNeeded()
        if let why = LiveFacePolicy.refusal(sight: sight, liveFaces: liveFacesOn,
            voiceOver: UIAccessibility.isVoiceOverRunning, serverEnabled: serverEnabled,
            agents: serverAgents, agentID: agentID, motionAllowed: motionAllowed, stage: true) {
            KadeBreadcrumbs.drop("live-face: closed (\(why))")
            return
        }
        guard let agentID else { return }
        if shows(agentID: agentID) { return }
        if state != .idle { stop() }
        await open(agentID: agentID, lane: lane)
    }

    /// The stage went away (left the chat, hung up): close and bill.
    func detach(agentID: String?) {
        guard shows(agentID: agentID) else { return }
        stop()
    }

    private func open(agentID: String, lane: LiveFaceLane) async {
        self.lane = lane
        self.agentID = agentID
        state = .connecting(agentID)
        firstFrame = false
        speaking = false
        var req = client.request(path: "api/kade/live-face/session", method: "POST", authorized: true, timeout: 20)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["agentId": agentID, "lane": lane.rawValue])
        guard let (data, http) = try? await client.send(req), http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["sessionToken"] as? String, !token.isEmpty else {
            KadeBreadcrumbs.drop("live-face: no session for \(agentID)")
            state = .idle
            return
        }
        guard case .connecting(let wanted) = state, wanted == agentID else { return }
        let ws = (json["ws"] as? String) ?? "wss://api.simli.ai"
        load(token: token, ws: ws, muted: LiveFacePolicy.pageMuted(lane: lane))
        openedAt = Date()
        usageReported = false
    }

    private func load(token: String, ws: String, muted: Bool) {
        teardownWebView()
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(LiveFaceScriptHandler(self), name: "face")
        let web = WKWebView(frame: .zero, configuration: config)
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
            web.configuration.userContentController.removeScriptMessageHandler(forName: "face")
            web.stopLoading()
            web.load(URLRequest(url: URL(string: "about:blank")!))
            web.removeFromSuperview()
        }
        webView = nil
    }

    func stop() {
        webView?.evaluateJavaScript("window.face && window.face.end()", completionHandler: nil)
        reportUsage()
        teardownWebView()
        state = .idle
        firstFrame = false
        speaking = false
        clipStartedAt = nil
        envelope = []
        agentID = nil
    }

    /// The person interrupted: drop whatever the page still has queued.
    func interrupt() {
        webView?.evaluateJavaScript("window.face && window.face.clear()", completionHandler: nil)
        clipStartedAt = nil
        envelope = []
    }

    private func reportUsage() {
        guard let openedAt, !usageReported else { return }
        usageReported = true
        let seconds = Int(Date().timeIntervalSince(openedAt).rounded())
        let agent = agentID ?? ""
        let laneName = lane.rawValue
        self.openedAt = nil
        guard seconds >= 1 else { return }
        Task {
            var req = client.request(path: "api/kade/live-face/usage", method: "POST", authorized: true, timeout: 15)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["seconds": seconds, "agentId": agent, "lane": laneName])
            _ = try? await client.send(req)
        }
    }

    // MARK: Page events

    fileprivate func handle(message body: Any) {
        guard let dict = body as? [String: Any], let t = dict["t"] as? String else { return }
        switch t {
        case "start":
            firstFrame = true
            if case .connecting(let id) = state { state = .live(id) }
        case "speaking":
            speaking = true
            sawSpeak = true
            sawSilentSince = nil
        case "silent":
            speaking = false
            sawSilentSince = Date()
        case "error", "stop":
            let why = (dict["why"] as? String) ?? t
            KadeBreadcrumbs.drop("live-face: \(t) \(why)")
            let id = agentID ?? ""
            reportUsage()
            teardownWebView()
            state = .failed(id, why)
            firstFrame = false
            speaking = false
        default:
            break
        }
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
        guard let clipStartedAt, !envelope.isEmpty else { return 0 }
        // The service draws a beat behind the audio it was given.
        let at = Date().timeIntervalSince(clipStartedAt) - 0.25
        guard at >= 0 else { return 0 }
        let i = Int(at * 20)
        guard i < envelope.count else { return 0 }
        return Double(envelope[i])
    }

    var isPlayingClip: Bool { clipStartedAt != nil }

    /// Plays one spoken clip (WAV or MP3 bytes) through the live face. Returns
    /// once the page reports silence after the speech, or the clip's own
    /// length plus a margin has passed. `onStarted` fires when the first audio
    /// has been handed over, where the local player would have started.
    func playClip(_ data: Data, agentID: String?, onStarted: @MainActor () -> Void,
                  cancelled: @MainActor () -> Bool) async -> ClipOutcome {
        guard takesClip(agentID: agentID), let web = webView else { return .notTaken }
        guard let pcm = await LiveFaceAudio.pcm16(from: data) else { return .notTaken }
        envelope = pcm.envelope
        sawSpeak = false
        sawSilentSince = nil
        clipStartedAt = Date()
        onStarted()
        var offset = 0
        let bytes = pcm.data
        while offset < bytes.count {
            if cancelled() || !isLive { clipStartedAt = nil; return cancelled() ? .played : .failed }
            let end = min(bytes.count, offset + LiveFacePolicy.chunkBytes)
            let b64 = bytes.subdata(in: offset..<end).base64EncodedString()
            let ok = await evaluate(web, "window.face && window.face.audio('\(b64)')")
            if !ok { clipStartedAt = nil; return .failed }
            offset = end
        }
        let deadline = Date().addingTimeInterval(LiveFacePolicy.clipTimeout(seconds: pcm.seconds))
        let earliest = Date().addingTimeInterval(max(0.3, pcm.seconds - 0.2))
        while Date() < deadline {
            if cancelled() { break }
            if !isLive { clipStartedAt = nil; return .failed }
            // Done when the page went silent after speaking, once the clip's
            // own length has passed (short clips can report silence early).
            if Date() >= earliest, sawSpeak, let since = sawSilentSince, Date().timeIntervalSince(since) >= 0.15 { break }
            // No SPEAK at all within the clip's length plus a second: the
            // page is not playing it; stop waiting rather than hang.
            if !sawSpeak, Date() >= earliest.addingTimeInterval(1.5) { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        clipStartedAt = nil
        return .played
    }

    /// A call's agent audio (Float32, 24 kHz mono, the call engine's one
    /// format) goes to the muted page so the face follows the voice.
    func feedCall(_ buffer: AVAudioPCMBuffer, agentID: String?) {
        // A call stage holds one character; a clip without a named speaker is theirs.
        guard lane == .call, isLive, firstFrame, agentID == nil || shows(agentID: agentID), let web = webView else { return }
        guard let data = LiveFaceAudio.pcm16(resampling: buffer) else { return }
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + LiveFacePolicy.chunkBytes)
            let b64 = data.subdata(in: offset..<end).base64EncodedString()
            web.evaluateJavaScript("window.face && window.face.audio('\(b64)')", completionHandler: nil)
            offset = end
        }
    }

    private func evaluate(_ web: WKWebView, _ js: String) async -> Bool {
        await withCheckedContinuation { cont in
            web.evaluateJavaScript(js) { _, error in cont.resume(returning: error == nil) }
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
/// across devices (the arcade and the web will read the same answer).
@MainActor
enum SightService {
    static func pull(client: KadeAPIClient) async {
        let req = client.request(path: "api/kade/sight", authorized: true, timeout: 15)
        guard let (data, http) = try? await client.send(req), http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let sight = (json["sight"] as? String) ?? SightSetting.unset
        let liveFaces = (json["liveFaces"] as? Bool) ?? LiveFaceSetting.defaultOn
        let defaults = UserDefaults.standard
        defaults.set([SightSetting.sighted, SightSetting.nonvisual].contains(sight) ? sight : SightSetting.unset,
            forKey: SightSetting.key)
        defaults.set(liveFaces, forKey: LiveFaceSetting.key)
    }

    static func push(sight: String, liveFaces: Bool) async {
        let client = KadeAPIClient()
        var req = client.request(path: "api/kade/sight", method: "PUT", authorized: true, timeout: 15)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let value: Any = sight.isEmpty ? NSNull() : sight
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sight": value, "liveFaces": liveFaces])
        _ = try? await client.send(req)
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

    /// One call buffer (any float/int format) to PCM16 16 kHz bytes.
    static func pcm16(resampling buffer: AVAudioPCMBuffer) -> Data? {
        convert(buffer)?.data
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
