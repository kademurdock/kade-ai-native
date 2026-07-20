import Foundation
import AVFoundation
import MediaPlayer
// UIAccessibility (spoken reconnect announcements, session 15). MediaPlayer
// pulls UIKit in transitively on iOS, but this file depends on it directly
// now, so it says so directly.
import UIKit

/// Real-time voice (and, once the caller enables Spotter, video) calling —
/// the native port of the fork's `useStreamingCall.ts` + `video-live.js`
/// bridge relay. Kade's ask (session 13, after the message-actions/VoiceOver
/// batch): "work on calling and spotters and shit too... I'd like to be
/// fully featured soon."
///
/// ARCHITECTURE (mirrors the web client's `useStreamingCall.ts` exactly —
/// same wire protocol, same server, just a different audio stack on this
/// end):
///   1. Fetch a short-lived ticket: `GET /api/kade/web-voice/ticket?agentId=`
///      via the existing `KadeAPIClient` (kademurdock.com, JWT-authorized).
///      Response: `{ticket, wsUrl}` — `wsUrl` points at kade-ai-bridge's
///      `/ws/web-voice`, NOT kademurdock.com, so the actual call socket
///      deliberately does NOT go through `KadeAPIClient` (same reasoning
///      already established for `PushService` -> the bridge is a different
///      host with its own lifecycle, not subject to the site's pacing gate).
///   2. Open a `URLSessionWebSocketTask` to that `wsUrl`, send
///      `{type:'hello', ticket, spotterDirect}`.
///   3. Mic: tapped continuously off `AVAudioEngine.inputNode` (never
///      pauses, even while the agent is "speaking" -- that's what makes
///      barge-in possible server-side, exactly like the web client's
///      comment: "talk over the agent and the server stops her mid-word").
///      Each tap buffer is converted (`AVAudioConverter`) from the
///      hardware's native format down to 16kHz mono Int16 and sent as a
///      RAW BINARY WebSocket frame -- no JSON envelope, no base64; the
///      server (`voice-stream.js`'s `/ws/web-voice` handler) forwards
///      binary frames straight to Deepgram.
///   4. Agent audio: binary frames come back as either a WAV clip (Inworld
///      TTS, starts with the ASCII bytes "RIFF") or, once Spotter/Live mode
///      is on, a raw 24kHz PCM16 chunk prefixed with the 4-byte magic
///      "LIVE" (`video-live.js`'s `LIVE_AUDIO_MAGIC`). Both get converted to
///      one fixed playback format and scheduled on a single
///      `AVAudioPlayerNode`. Unlike the web client (which hand-tracks a
///      `nextTime` playhead over Web Audio's `AudioBufferSourceNode`s to
///      keep clips gapless), `AVAudioPlayerNode.scheduleBuffer` already
///      queues buffers back-to-back with no gap once the node is playing --
///      genuinely simpler here than the workaround the browser needs.
///   5. JSON control messages (`ready`/`state`/`caption`/`clear`/`table`/
///      `error`/`live-notice`/`live-state`/`video-notice`/`video-state`)
///      drive `@Published` state the SwiftUI call screen renders/announces.
///
/// HONEST RISK NOTE (worth reading before touching this file again): this
/// is real-time duplex audio over a raw WebSocket, built with zero access to
/// a compiler AND zero access to a real device or simulator in this sandbox
/// -- unlike every other native-app change this project has shipped, this
/// one cannot be meaningfully hand-verified beyond "does the code read as
/// correct against Apple's documented AVAudioConverter/AVAudioEngine
/// contracts." Codemagic passing proves it COMPILES, nothing more. The
/// specific things most likely to need a real-device tuning pass (matching
/// `video-live.js`'s own "first activation is expected to need a tuning
/// session" honesty about the server side): whether the mic tap's actual
/// delivered buffer size behaves as expected across real hardware, and
/// general first-call latency feel. None of this can be confirmed until
/// someone is actually on a call.
///
/// CONFIRMED LIVE (first real call, build 116): the predicted echo risk
/// above was real -- the caller heard the agent fine and the agent
/// understood the caller fine, but the agent kept cutting herself off
/// mid-sentence, because she was hearing her OWN played-back voice loop
/// back through the mic and tripping the server's barge-in detection.
/// Root cause: `.voiceChat` AVAudioSession MODE alone (the original code
/// here) configures session-level hints but does NOT turn on real acoustic
/// echo cancellation for a custom `AVAudioEngine` graph -- that needs the
/// engine's Voice-Processing I/O unit explicitly enabled via
/// `inputNode.setVoiceProcessingEnabled(true)`, which `startAudioEngine()`
/// now does. Not yet re-confirmed live (this fix itself is unverified the
/// same "no device" way everything here is) -- if the cutting-herself-off
/// behavior is EVER reported again after this fix, this specific API is
/// the first thing to re-check, not the barge-in logic itself (the server
/// behaved completely correctly given what it was actually hearing).
@MainActor
final class StreamingCallService: NSObject, ObservableObject {

    enum Status: Equatable {
        case idle
        case connecting
        case listening
        case thinking
        case speaking
        case ended(graceful: Bool)
        case failed(String)
        /// The call socket dropped without anyone hanging up, and the
        /// service is putting it back together. Distinct from `.connecting`
        /// on purpose: the caller is already IN a call and needs to be told
        /// what happened, not shown a fresh "starting" state as though
        /// nothing had. See `beginReconnect()`.
        case reconnecting
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var agentName: String = ""
    @Published private(set) var userCaption: String = ""
    @Published private(set) var agentCaption: String = ""
    @Published private(set) var liveOn: Bool = false
    @Published private(set) var liveNotice: String?
    @Published private(set) var spotterName: String?
    @Published private(set) var liveMinutesLeft: Int?
    /// The PLAIN camera-describe lane (`video-sight.js`), distinct from
    /// Spotter/Live: the agent you're already talking to gains sight of your
    /// camera and works what she sees into her own replies, in her own
    /// voice, with no handoff to a separate live companion. Ported in
    /// session 14 -- it was explicitly carved out of the session-13 calling
    /// batch as "its own well-scoped follow-up" and Kade asked for it by
    /// name ("plain camera describe mode").
    @Published private(set) var videoOn: Bool = false
    @Published private(set) var videoNotice: String?
    @Published private(set) var videoMinutesLeft: Int?
    @Published private(set) var errorMessage: String?

    /// Plain-language audio diagnostic, surfaced on the call screen as its
    /// own VoiceOver element. Added after build 119's live report: the call
    /// connected and the caption read "Kiana here, go ahead" on screen, but
    /// no sound ever came out. With no device and no compiler in this
    /// sandbox, a second round of blind guessing is worth less than giving
    /// the caller something she can actually READ OUT and report back, so
    /// the next attempt narrows the cause in one pass instead of three.
    /// Reports: clips received off the wire, clips actually scheduled for
    /// playback, clips CONFIRMED played (via the scheduler's own completion
    /// handler -- session 17/18's own bug report, a Spotter reply that was
    /// scheduled but genuinely never audible, is exactly why "scheduled"
    /// and "played" are no longer conflated here), conversion failures, the
    /// live output route, and the system output volume.
    @Published private(set) var audioDiagnostic: String = "No audio received yet."

    private var clipsReceived = 0
    private var clipsScheduled = 0
    private var clipsPlayed = 0
    private var clipFailures = 0
    /// Rearmed to `false` every time a FRESH Spotter/Live segment starts
    /// (`liveOn` false -> true); flipped `true` the first time that
    /// segment's own audio is actually scheduled, gating a one-shot
    /// confirmation tone distinct from the whole-call connect tone -- see
    /// `playLiveStartTone()`.
    private var liveTonePlayed = false
    private var routeObserver: NSObjectProtocol?
    /// When this call started, used by the post-call handoff to make sure it
    /// opens THIS call's transcript rather than a stale one.
    private(set) var startedAt: Date = Date()
    private var remoteCommandsWired = false

    /// True once `start()` has fully wired the engine/socket and the call
    /// screen should be showing live controls rather than a spinner.
    var isActive: Bool { webSocketTask != nil }

    private let apiClient: KadeAPIClient
    private let socketSession = URLSession(configuration: .default)
    private var webSocketTask: URLSessionWebSocketTask?

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// Running playhead (on `playerNode`'s own sample-time timeline, at
    /// `playerFormat.sampleRate`) the next scheduled buffer pins to. `nil`
    /// means nothing is queued -- the next schedule starts a small lead
    /// into the future. Reset to `nil` on flush and on any engine
    /// (re)start, since both reset the node's timeline. Only ever touched
    /// on the main actor (this whole class is `@MainActor`).
    private var nextPlayheadSample: AVAudioFramePosition?
    /// Every incoming clip (WAV or raw LIVE PCM) is converted to this one
    /// fixed format before scheduling, so `playerNode` only ever sees one
    /// consistent format regardless of what arrives. 24kHz mono Float32:
    /// matches the LIVE lane's native rate exactly (no resampling needed
    /// there) and is a clean, standard rate for the WAV clips to convert to.
    private let playerFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false
    )!
    /// What the server's Deepgram STT wants from us, per `voice-stream.js`.
    private let sendFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
    )!
    private var engineRunning = false

    private var byeSent = false
    private var receiveLoopTask: Task<Void, Never>?

    // MARK: Reconnect state (session 15)
    //
    // Google's Live API closes an audio+video session at roughly 10 minutes
    // no matter what -- documented, not a bug, and not liftable without
    // session resumption on the SERVER side (researched, unbuilt). Before
    // this, a long Spotter call simply went dead: the socket closed, the
    // status flipped to "Call disconnected," and someone who cannot see the
    // screen was left holding a silent phone with no idea whether to keep
    // talking. Reconnecting automatically is not a workaround for the cap
    // so much as the honest handling of it -- the caller never asked to
    // hang up, so the app shouldn't act as though she did.
    private var callAgentId: String?
    private var callSpotterDirect = false
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    /// Deliberately small. An unreachable server should surface as a real
    /// ended call quickly rather than an endless, silent retry loop that
    /// looks identical to a working call to someone listening rather than
    /// looking -- and each attempt on a LIVE/Spotter leg starts a fresh
    /// metered session server-side, so this is a cost ceiling too, not just
    /// a patience one. Reset to zero every time a reconnect actually
    /// succeeds (see `handleControl`'s "ready"), so a two-hour call can
    /// cross the ten-minute boundary as many times as it needs to.
    private static let maxReconnectAttempts = 3

    /// Set right before a deliberate `stop()` so the receive-loop's own
    /// "socket closed" handling knows not to report it as a dropped call.
    private var stopping = false

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        super.init()
    }

    // MARK: - Lifecycle

    /// Fetches a ticket, opens the call socket, starts the mic. Throws with
    /// a user-presentable message on any failure; the caller (CallView)
    /// shows it and never leaves the screen in a half-started state --
    /// mirrors `useStreamingCall.ts`'s own `start()` contract exactly
    /// (ticket fetch fails -> throw; mic fails -> throw; socket fails ->
    /// throw), including tearing everything back down on any failure.
    func start(agentId: String?, displayName: String, spotterDirect: Bool) async throws {
        guard webSocketTask == nil else { return }
        agentName = displayName
        callAgentId = agentId
        callSpotterDirect = spotterDirect
        reconnectAttempts = 0
        status = .connecting
        errorMessage = nil
        byeSent = false
        stopping = false
        startedAt = Date()

        let (ticket, wsUrl) = try await fetchTicket(agentId: agentId)

        do {
            try startAudioEngine()
        } catch {
            status = .failed("Microphone access is blocked. Enable mic permission in Settings, then try the call again.")
            throw error
        }

        do {
            try openSocket(ticket: ticket, wsUrl: wsUrl)
        } catch {
            teardownAudio()
            status = .failed("Couldn't reach the call service.")
            throw error
        }
    }

    /// Opens the call socket and says hello. Split out of `start()` so the
    /// reconnect path can reuse it WITHOUT touching the audio engine: the
    /// mic, the player node, the speaker route override and the mic
    /// permission are all still perfectly good after a socket drop, and
    /// tearing them down and rebuilding them would risk re-negotiating the
    /// output route mid-call -- the exact class of bug that made calls
    /// silent for four builds.
    private func openSocket(ticket: String, wsUrl: String) throws {
        guard let url = URL(string: wsUrl) else { throw URLError(.badURL) }
        let task = socketSession.webSocketTask(with: url)
        // Default is 1 MiB. A single Inworld WAV clip for a long sentence
        // can approach that, and URLSession's failure mode when a frame
        // exceeds the limit is to fail the whole task -- cheap insurance,
        // and one of the candidate explanations for build 119's silent
        // audio that costs nothing to rule out.
        task.maximumMessageSize = 16 * 1024 * 1024
        webSocketTask = task
        task.resume()
        sendJSON(["type": "hello", "ticket": ticket, "spotterDirect": callSpotterDirect])
        startReceiveLoop()
    }

    /// Graceful hangup (sends `bye` first, same as the web client) unless
    /// `graceful` is false (used internally when tearing down after an
    /// error, where the socket may already be gone).
    func stop(graceful: Bool = true) {
        stopping = true
        reconnectTask?.cancel()
        reconnectTask = nil
        if graceful, let task = webSocketTask, !byeSent {
            byeSent = true
            sendJSON(["type": "bye"])
            task.cancel(with: .normalClosure, reason: nil)
        } else {
            webSocketTask?.cancel(with: .goingAway, reason: nil)
        }
        webSocketTask = nil
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        teardownAudio()
        status = .ended(graceful: graceful)
    }

    /// Manual "stop talking" / barge-in button — same as the web client's
    /// Stop button: flush whatever's queued for playback locally AND tell
    /// the server to cut the agent off server-side.
    func barge() {
        flushPlayback()
        sendJSON(["type": "barge"])
    }

    /// Toggle Spotter/Live mode. `ack` must be true only on the SECOND call
    /// after the caller has heard/accepted the first-use cost notice
    /// (`live-notice`) — mirrors the server's own `handleLiveMsg` gate in
    /// `video-live.js`, which re-sends the notice every time until `ack`
    /// comes back true.
    func setLive(on: Bool, ack: Bool = false, direct: Bool = false) {
        sendJSON(["type": "live", "on": on, "ack": ack, "direct": direct])
    }

    /// Toggle the plain camera-describe lane. Same two-step consent shape
    /// as `setLive`: the server re-sends `video-notice` (and speaks it)
    /// every time until `ack` comes back true, so the caller always hears
    /// the cost note before any camera minutes are billed.
    func setVideo(on: Bool, ack: Bool = false) {
        sendJSON(["type": "video", "on": on, "ack": ack])
    }

    func clearVideoNotice() {
        videoNotice = nil
    }

    /// Dismisses the first-use cost notice without accepting it (the
    /// caller tapped "Not now" or swiped the alert away) -- `liveNotice`
    /// is `private(set)` on purpose (only this service decides when a
    /// fresh notice arrives), so the view needs this rather than assigning
    /// nil directly.
    func clearLiveNotice() {
        liveNotice = nil
    }

    /// One camera frame while Spotter/Live (or the plain video-sight lane)
    /// is active. `jpegData` should already be resized/compressed by the
    /// caller (`CameraCaptureController`) -- this just base64-wraps and
    /// ships it, matching the server's `{type:'frame', data: <base64 jpeg>}`
    /// contract exactly (`video-sight.js`/`video-live.js` both read it).
    func sendFrame(jpegData: Data) {
        sendJSON(["type": "frame", "data": jpegData.base64EncodedString()])
    }

    // MARK: - Ticket

    private func fetchTicket(agentId: String?) async throws -> (ticket: String, wsUrl: String) {
        var query: [URLQueryItem] = []
        if let agentId { query.append(URLQueryItem(name: "agentId", value: agentId)) }
        let req = apiClient.request(
            path: "api/kade/web-voice/ticket", authorized: true,
            queryItems: query.isEmpty ? nil : query
        )
        let (data, http) = try await apiClient.send(req)
        guard http.statusCode == 200 else {
            throw CallError.message("Couldn't start the call (server said \(http.statusCode)).")
        }
        struct TicketResponse: Decodable { let ticket: String?; let wsUrl: String? }
        let decoded = try JSONDecoder().decode(TicketResponse.self, from: data)
        guard let ticket = decoded.ticket, let wsUrl = decoded.wsUrl else {
            throw CallError.message("Couldn't start the call (bad ticket response).")
        }
        return (ticket, wsUrl)
    }

    enum CallError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let m) = self { return m }
            return "Call error."
        }
    }

    // MARK: - WebSocket send/receive

    private func sendJSON(_ obj: [String: Any]) {
        guard let task = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in /* fail-soft: one dropped control message ≠ dead call */ }
    }

    private func startReceiveLoop() {
        receiveLoopTask = Task { [weak self] in
            guard let self else { return }
            while let task = await self.webSocketTask {
                do {
                    let message = try await task.receive()
                    await self.handle(message: message)
                } catch {
                    if await self.stopping { return }
                    await self.handleSocketClosed()
                    return
                }
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            handleBinary(data)
        case .string(let text):
            handleControl(text)
        @unknown default:
            break
        }
    }

    private func handleBinary(_ data: Data) {
        // "LIVE" magic = 0x4C 0x49 0x56 0x45 -- matches `LIVE_AUDIO_MAGIC`
        // in video-live.js exactly. Anything else is a WAV clip (starts
        // "RIFF"); the web client checks the same 4 bytes the same way.
        clipsReceived += 1
        // Prefix compared through `elementsEqual` rather than `data[0...3]`
        // subscripting: `Data` indices are NOT guaranteed to start at 0 for
        // every `Data` value, and a slice whose `startIndex` is non-zero
        // would make the direct subscript form read the wrong bytes (or
        // trap). `prefix` is index-agnostic.
        let liveMagic: [UInt8] = [0x4C, 0x49, 0x56, 0x45] // "LIVE"
        if data.count > 4, data.prefix(4).elementsEqual(liveMagic) {
            enqueueLivePCM(data)
        } else {
            enqueueWav(data)
        }
        updateAudioDiagnostic()
    }

    private func handleControl(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONDecoder().decode(CallServerMessage.self, from: data) else { return }
        switch msg.type {
        case "ready":
            status = .listening
            // A reconnect that got all the way to "ready" is a genuinely
            // healthy call again, so give it a full retry budget back --
            // otherwise a call long enough to cross the Live cap three
            // times would run out of attempts and die on the fourth.
            reconnectAttempts = 0
            // FIX (session 21, Kade: the home-screen "Call your Spotter"
            // button "opens up a call, nobody responds"). A DIRECT Spotter
            // call (spotterDirect + no agent) has nobody to talk to UNLESS
            // the Spotter comes online -- and this client never actually
            // asked for it, it only relied on the server auto-enabling live
            // from the hello's `spotterDirect` flag. If that hasn't happened
            // shortly after the socket is ready, ask explicitly, using the
            // exact same request the reconnect path already uses to restore
            // Spotter (setLive on/ack/direct). Guarded on `!liveOn` so if the
            // server DID auto-enable, this is a no-op and can't double-toggle.
            if callSpotterDirect {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    guard let self else { return }
                    if !self.liveOn, self.webSocketTask != nil, !self.stopping {
                        self.setLive(on: true, ack: true, direct: true)
                    }
                }
            }
        case "state":
            switch msg.state {
            case "speaking": status = .speaking
            case "thinking": status = .thinking
            default: status = .listening
            }
        case "caption":
            if msg.role == "user" { userCaption = msg.text ?? "" } else { agentCaption = msg.text ?? "" }
        case "clear":
            flushPlayback()
        case "live-state":
            let wasLive = liveOn
            liveOn = msg.on ?? false
            // A fresh Spotter/Live segment starting (not just staying on
            // across an unrelated live-state update) rearms the one-shot
            // "Spotter's own audio is really flowing" tone -- see
            // `playLiveStartTone()`.
            if liveOn && !wasLive { liveTonePlayed = false }
            if let name = msg.spotterName { spotterName = name }
            liveMinutesLeft = msg.minutesLeft
            if let m = msg.message { liveNotice = m }
            if engineRunning { updateNowPlayingInfo() }
        case "live-notice":
            liveNotice = msg.text
        case "video-notice":
            videoNotice = msg.text
        case "video-state":
            videoOn = msg.on ?? false
            videoMinutesLeft = msg.minutesLeft
            // `video-state` doubles as the refusal channel (`reason` of
            // "disabled" or "cap" arrives with `on:false` plus a plain-
            // language `message`). Surfacing it as a notice rather than a
            // hard `errorMessage` is deliberate: the CALL is completely
            // fine, only the camera lane was declined.
            if let m = msg.message { videoNotice = m }
        case "error":
            errorMessage = msg.message ?? "Call error."
        default:
            break // "table" (Game Parlor) and anything future: ignore quietly
        }
    }

    private func handleSocketClosed() {
        webSocketTask = nil
        if case .failed = status {
            teardownAudio()
            return
        }
        // A close we asked for (hang up) is just the end of the call.
        if byeSent || stopping {
            teardownAudio()
            status = .ended(graceful: byeSent)
            return
        }
        // Nobody hung up -- the socket went away on its own. Most likely
        // the ~10 minute Live/Spotter session cap, otherwise ordinary
        // network flakiness. Either way the caller is still on the phone.
        guard reconnectAttempts < Self.maxReconnectAttempts else {
            teardownAudio()
            status = .ended(graceful: false)
            errorMessage = "The call dropped and couldn't reconnect. Call again when you're ready."
            return
        }
        beginReconnect()
    }

    /// Schedules one reconnect attempt, with a short escalating gap so a
    /// server that is genuinely down isn't hammered. Announces itself out
    /// loud, because on this screen there is nothing else that would tell
    /// a blind caller the line went quiet on purpose rather than by
    /// accident -- silence and "reconnecting" sound identical otherwise.
    private func beginReconnect() {
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        status = .reconnecting
        // Drop whatever was mid-sentence. It belongs to a session that no
        // longer exists, and hearing half of it land after the reconnect
        // greeting would be worse than losing it.
        flushPlayback()
        // Remember what was running so it can be re-requested from the
        // fresh session in `finishReconnect` -- but do NOT clear `liveOn`/
        // `videoOn` here. An earlier version of this method did, on the
        // theory that "the new session starts with neither lane on." That
        // was wrong in a way that only showed up by tracing CallView's own
        // onChange handlers, not by re-reading this function in isolation:
        // flipping `videoOn` false (after `liveOn` had already gone false
        // moments before) satisfies `if !callService.liveOn { camera.stop() }`
        // in CallView's `onChange(of: callService.videoOn)`, which ALSO
        // speaks "Camera off." -- a false announcement in the middle of a
        // transient reconnect, plus a needless AVCaptureSession stop/
        // restart, right as the caller is being told to "hold on." The
        // camera hardware staying up during the gap is harmless: frames it
        // keeps producing just get silently dropped by `sendJSON`'s own
        // nil-`webSocketTask` guard until the socket is back, matching this
        // service's fail-soft pattern everywhere else. So `liveOn`/
        // `videoOn` now stay exactly as they were for the whole gap, the
        // camera preview stays on screen (accurately -- it IS still
        // running), and the status header keeps saying the Spotter's name
        // through "Reconnecting..." rather than reverting to the original
        // agent's only to flip back a moment later.
        let wasLive = liveOn
        let wasVideo = videoOn
        UIAccessibility.post(
            notification: .announcement,
            argument: attempt == 1
                ? "The call dropped. Reconnecting, hold on."
                : "Still reconnecting, attempt \(attempt)."
        )
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.finishReconnect(restoreLive: wasLive, restoreVideo: wasVideo)
        }
    }

    private func finishReconnect(restoreLive: Bool, restoreVideo: Bool) async {
        guard !stopping else { return }
        do {
            let (ticket, wsUrl) = try await fetchTicket(agentId: callAgentId)
            guard !stopping else { return }
            byeSent = false
            try openSocket(ticket: ticket, wsUrl: wsUrl)
            status = .listening
            UIAccessibility.post(
                notification: .announcement,
                argument: "Reconnected. Go ahead."
            )
            // Consent for the metered lanes was already given earlier in
            // THIS call, so ack straight through rather than making someone
            // re-approve the same cost notice every ten minutes. The server
            // re-sends the notice until `ack` is true (`video-live.js`'s
            // `handleLiveMsg`), so passing it here is what keeps a long
            // Spotter call from turning into a consent prompt treadmill.
            if restoreLive { setLive(on: true, ack: true, direct: callSpotterDirect) }
            if restoreVideo { setVideo(on: true, ack: true) }
        } catch {
            guard !stopping else { return }
            if reconnectAttempts < Self.maxReconnectAttempts {
                beginReconnect()
            } else {
                teardownAudio()
                status = .ended(graceful: false)
                errorMessage = "The call dropped and couldn't reconnect. Call again when you're ready."
            }
        }
    }

    // MARK: - Audio engine (mic capture)

    private func startAudioEngine() throws {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .denied:
            throw CallError.message("Microphone access is off for Kade-AI.")
        case .undetermined, .granted:
            break
        @unknown default:
            break
        }
        // `.voiceChat` mode is Apple's documented mode for exactly this
        // shape of duplex call audio (continuous simultaneous record+
        // playback with the system doing its own echo/gain assistance) --
        // the closest native equivalent to `getUserMedia`'s
        // echoCancellation/noiseSuppression/autoGainControl flags the web
        // client requests explicitly.
        // `.allowBluetoothA2DP` is deliberately NOT requested here (it was,
        // through build 119): A2DP is an OUTPUT-ONLY profile and combining
        // it with a duplex `.playAndRecord` + `.voiceChat` graph is a known
        // source of odd route selection. `.allowBluetooth` (HFP) already
        // covers a real headset, which is what a caller actually wants.
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .defaultToSpeaker]
        )
        try session.setActive(true)
        // FIX CANDIDATE #1 for build 119's "captions appear, no sound"
        // report. `.voiceChat` MODE makes iOS treat this like a phone call,
        // and a phone call's default output is the BUILT-IN RECEIVER (the
        // earpiece), not the speaker -- the `.defaultToSpeaker` option above
        // is documented against the category but is not reliably honored
        // once a call-style mode is set. A caller holding the phone in her
        // hand rather than against her ear would hear exactly nothing while
        // every caption still rendered perfectly, which is precisely the
        // symptom reported. `overrideOutputAudioPort` is the explicit,
        // unambiguous way to say "speaker" and is re-applied on every route
        // change below (plugging in or dropping a headset resets it).
        forceSpeakerRoute()
        observeRouteChanges()

        let input = audioEngine.inputNode
        // FIX (live-tested, first real call): the caller heard the agent
        // hearing HERSELF -- the agent's own played-back voice looping back
        // through the mic and tripping the server's barge-in detection,
        // cutting her off mid-sentence every time. The caller heard the
        // agent fine and the agent understood the caller fine, so this was
        // never the WebSocket/mic-send path -- it was acoustic echo, the
        // exact risk flagged (but not yet guarded against) in this file's
        // original top comment. `.voiceChat` MODE alone configures session-
        // level hints; it does NOT turn on real acoustic echo cancellation
        // for a custom AVAudioEngine graph like this one. The actual fix is
        // enabling the engine's Voice-Processing I/O unit directly on the
        // input node -- this cancels whatever the engine is CURRENTLY
        // playing (the agent's own clips, scheduled on `playerNode` into
        // this same engine's mixer) out of what the input node captures,
        // which is exactly the loop that was tripping the server's VAD.
        // Enabling it can change the node's own delivered format, so the
        // format is read AFTER enabling, not before -- reading it first
        // (the original bug) risked building the mic converter against a
        // format that was about to change out from under it.
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            // Fail-soft: a handful of audio route configurations don't
            // support voice processing. The call still works without it --
            // just back to the original echo risk -- never worth failing
            // the whole call over.
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw CallError.message("No microphone input available.")
        }

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: playerFormat)

        // FIX (live-tested): the first echo fix (enabling voice processing
        // above) broke mic capture entirely on the very next call -- Kiana
        // greeted, then never responded, because the converter built here
        // from `inputFormat` (read right after `setVoiceProcessingEnabled`)
        // silently stopped matching the format actually delivered to the
        // tap once the engine was really running, so every conversion call
        // was failing quietly (`pcm16Data` returning nil) and NOTHING ever
        // reached the server -- Deepgram had nothing to transcribe, so
        // there was never a turn to reply to. Rather than guess at the
        // exact timing voice processing settles its format (unverifiable
        // without a device), `MicConverterBox` below is self-healing: it
        // rebuilds its converter from whatever format the REAL buffer
        // reports on each tap callback, so there is no "read the format at
        // the right moment" question left to get wrong. Rebuilding only
        // happens when the format actually changes (cheap after the first
        // call in the overwhelmingly common case).
        let box = MicConverterBox(outputFormat: sendFormat)
        input.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
            guard let pcmData = box.convert(buffer) else { return }
            Task { @MainActor in
                self?.sendMicData(pcmData)
            }
        }

        // Belt and braces: both of these default to 1.0, but a silent-audio
        // bug is exactly the situation where asserting the obvious costs
        // nothing and rules out a whole branch of the search.
        playerNode.volume = 1.0
        audioEngine.mainMixerNode.outputVolume = 1.0

        audioEngine.prepare()
        try audioEngine.start()
        playerNode.play()
        engineRunning = true
        updateAudioDiagnostic()
        startNowPlaying()
        // AUDIBLE SELF-TEST. A short, soft two-note tone pushed through the
        // exact same `playerNode` -> mixer -> output path the agent's voice
        // uses. This is the single most valuable thing that can be added
        // without a device: it turns the next bug report into one clean bit
        // of information instead of another guess. If the caller HEARS the
        // tone but still hears no agent, playback is fine and the problem is
        // upstream (clips not arriving, or not decoding -- and
        // `audioDiagnostic` says which). If she hears NOTHING at all, the
        // problem is the route/session/volume layer. It also does real UX
        // work as a "call connected" earcon.
        playConnectTone()
    }

    /// Explicitly routes call audio out the loudspeaker. Fail-soft: a
    /// wired/Bluetooth headset route legitimately rejects the override, and
    /// in that case the headset IS the right output anyway.
    private func forceSpeakerRoute() {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
    }

    /// Re-forces the speaker whenever iOS reroutes mid-call (headset
    /// plugged/unplugged, Bluetooth connecting late, the system taking the
    /// route back after activating voice processing). Without this, a single
    /// route change silently undoes `forceSpeakerRoute()` for the rest of
    /// the call.
    private func observeRouteChanges() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.engineRunning else { return }
                let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
                let onHeadset = outputs.contains {
                    $0.portType == .headphones || $0.portType == .bluetoothA2DP
                        || $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
                        || $0.portType == .usbAudio
                }
                if !onHeadset { self.forceSpeakerRoute() }
                self.updateAudioDiagnostic()
            }
        }
    }

    /// Two short sine blips (880Hz then 1175Hz, ~110ms each) synthesized
    /// straight into `playerFormat` and scheduled like any agent clip.
    private func playConnectTone() {
        let sampleRate = playerFormat.sampleRate
        let noteFrames = Int(sampleRate * 0.11)
        let total = noteFrames * 2
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: playerFormat, frameCapacity: AVAudioFrameCount(total)
        ), let channel = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(total)
        let dst = channel[0]
        for i in 0..<total {
            let isSecond = i >= noteFrames
            let freq: Double = isSecond ? 1175.0 : 880.0
            let localIndex = isSecond ? (i - noteFrames) : i
            let phase = 2.0 * Double.pi * freq * (Double(localIndex) / sampleRate)
            // Short linear fade in/out so the blip doesn't click.
            let fade = min(1.0, Double(min(localIndex, noteFrames - localIndex)) / (sampleRate * 0.01))
            dst[i] = Float(sin(phase) * 0.22 * fade)
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Session 17/18 (Kade, after a Spotter call went silent: "Spotter
    /// should prob beep like normal calls do"). The connect tone above
    /// proves the ENGINE/OUTPUT PATH works at the moment a call starts --
    /// it says nothing about whether Spotter/Live's own audio (a
    /// completely separate lane, `enqueueLivePCM`, added/changed later in
    /// the call) actually made it to the speaker. This is a second,
    /// audibly DIFFERENT one-shot earcon (a single higher chirp, not the
    /// two-note connect tone) fired the first time a fresh Spotter/Live
    /// segment's own audio is actually handed to the player -- same
    /// diagnostic value as the connect tone, scoped to the specific lane
    /// this session's bug report was about. Uses the same bare
    /// `scheduleBuffer` (no `at:` time) as the connect tone, deliberately
    /// NOT `scheduleOnTimeline` -- this is a fixed, known-good utility
    /// sound, not part of the jitter-sensitive reply stream, so there is no
    /// reason to expose it to the same timing math this session's other
    /// fix was about.
    private func playLiveStartTone() {
        let sampleRate = playerFormat.sampleRate
        let total = Int(sampleRate * 0.09)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: playerFormat, frameCapacity: AVAudioFrameCount(total)
        ), let channel = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(total)
        let dst = channel[0]
        let freq = 1567.98 // G6 -- clearly distinct from the connect tone's A5/D6 pair
        for i in 0..<total {
            let phase = 2.0 * Double.pi * freq * (Double(i) / sampleRate)
            let fade = min(1.0, Double(min(i, total - i)) / (sampleRate * 0.01))
            dst[i] = Float(sin(phase) * 0.22 * fade)
        }
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Rebuilds the human-readable diagnostic string. Cheap, and only ever
    /// called on genuinely interesting transitions (engine start, a clip
    /// arriving, a route change), never per audio frame.
    private func updateAudioDiagnostic() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute.outputs.first.map { port -> String in
            switch port.portType {
            case .builtInSpeaker: return "speaker"
            case .builtInReceiver: return "earpiece"
            case .headphones: return "headphones"
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return "Bluetooth"
            case .usbAudio: return "USB audio"
            default: return port.portName
            }
        } ?? "unknown"
        let volumePercent = Int((session.outputVolume * 100).rounded())
        var parts = [
            "Playing through \(route).",
            "Volume \(volumePercent) percent.",
            "\(clipsReceived) clips received, \(clipsScheduled) scheduled, \(clipsPlayed) confirmed played."
        ]
        if clipFailures > 0 { parts.append("\(clipFailures) could not be decoded.") }
        // A gap between "scheduled" and "confirmed played" that keeps
        // growing (rather than just trailing behind by the last clip or
        // two, which is normal -- playback confirmation lags scheduling
        // slightly by design) is the exact signature of session 17/18's
        // bug report: audio handed to the OS scheduler that never actually
        // came out of the speaker.
        if clipsScheduled - clipsPlayed > 2 {
            parts.append("\(clipsScheduled - clipsPlayed) scheduled clips have not been confirmed played yet.")
        }
        audioDiagnostic = parts.joined(separator: " ")
    }

    private func sendMicData(_ pcmData: Data) {
        guard let task = webSocketTask else { return }
        task.send(.data(pcmData)) { _ in /* fail-soft: one dropped mic chunk ≠ dead call */ }
    }

    /// Pure conversion, no actor isolation, safe to call from the real-time
    /// audio thread: one input `AVAudioPCMBuffer` in a source format, one
    /// `Data` of little-endian Int16 samples in `outputFormat` out. The
    /// "provide the buffer once, then `.noDataNow`" input-block shape is
    /// the standard `AVAudioConverter` pull pattern for converting exactly
    /// one already-in-memory buffer (used identically for playback in
    /// `schedule(_:from:)` below).
    nonisolated fileprivate static func pcm16Data(
        from buffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat, using converter: AVAudioConverter
    ) -> Data? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else { return nil }
        var provided = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError, withInputFrom: inputBlock)
        guard status != .error, convError == nil, outBuffer.frameLength > 0,
              let channelData = outBuffer.int16ChannelData else { return nil }
        let byteCount = Int(outBuffer.frameLength) * 2 // Int16 = 2 bytes, mono
        return Data(bytes: channelData[0], count: byteCount)
    }

    // MARK: - Playback

    /// WAV clip (Inworld TTS): written to a temp file and read back via
    /// `AVAudioFile` rather than hand-parsing the RIFF header -- leans on
    /// Apple's own parser instead of a hand-rolled one for something that
    /// can't be tested on-device before shipping. Mirrors the temp-file
    /// pattern `VoiceService`/`MessageSendingService` already use elsewhere
    /// in this app for audio.
    private func enqueueWav(_ data: Data) {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kade-call-clip-\(UUID().uuidString).wav")
        do {
            try data.write(to: tmpURL)
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            let file = try AVAudioFile(forReading: tmpURL)
            guard let raw = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
            ) else { return }
            try file.read(into: raw)
            schedule(raw, from: file.processingFormat)
        } catch {
            // One bad clip must never kill the call -- same fail-soft
            // philosophy as every other audio path in this app. Counted,
            // though: "clips arrived but none decoded" is a completely
            // different bug from "no clips arrived," and before the
            // diagnostic string existed there was no way to tell them apart
            // from the caller's side.
            clipFailures += 1
        }
    }

    /// LIVE lane: raw 24kHz PCM16 mono, no header, prefixed with the 4-byte
    /// "LIVE" magic already consumed by the caller. Reconstructed byte-by-
    /// byte (little-endian, matching both this platform's native layout and
    /// the JS client's own `Int16Array` read of the same bytes) rather than
    /// an aligned pointer cast, since `Data` received off the wire carries
    /// no alignment guarantee.
    private func enqueueLivePCM(_ data: Data) {
        let sampleCount = (data.count - 4) / 2
        guard sampleCount > 0 else { return }
        if liveOn, !liveTonePlayed {
            liveTonePlayed = true
            playLiveStartTone()
        }
        let liveFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true
        )!
        guard let liveBuffer = AVAudioPCMBuffer(pcmFormat: liveFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let channelData = liveBuffer.int16ChannelData else { return }
        liveBuffer.frameLength = AVAudioFrameCount(sampleCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let dst = channelData[0]
            for i in 0..<sampleCount {
                let lo = UInt16(raw[4 + i * 2])
                let hi = UInt16(raw[4 + i * 2 + 1])
                dst[i] = Int16(bitPattern: lo | (hi << 8))
            }
        }
        schedule(liveBuffer, from: liveFormat)
    }

    /// Converts any incoming buffer to the one fixed `playerFormat` and
    /// schedules it. `AVAudioPlayerNode.scheduleBuffer` (no explicit `at:`
    /// time) queues gaplessly behind whatever's already scheduled as long
    /// as the node is playing -- no manual playhead-tracking needed here,
    /// unlike the web client's Web Audio workaround.
    private func schedule(_ buffer: AVAudioPCMBuffer, from sourceFormat: AVAudioFormat) {
        guard engineRunning else { return }
        // The engine can be stopped out from under us by an interruption
        // (another app taking the session, a real phone call) without this
        // service ever hearing about it -- and once stopped, every
        // `scheduleBuffer` is silently swallowed. Restarting here is a
        // no-op in the normal case and recovers the whole call in the bad
        // one. Another candidate cause of build 119's silence: enabling
        // voice processing can itself provoke a configuration change.
        if !audioEngine.isRunning {
            try? audioEngine.start()
            playerNode.play()
            nextPlayheadSample = nil   // the restart reset the node's timeline
        }
        // Fast path: a clip already in the player's own format needs no
        // conversion at all, and skipping the converter removes one more
        // place a silent failure could hide.
        if sourceFormat == playerFormat {
            scheduleOnTimeline(buffer)
            return
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: playerFormat) else {
            clipFailures += 1
            return
        }
        let ratio = playerFormat.sampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: outCapacity) else { return }
        var provided = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if provided { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError, withInputFrom: inputBlock)
        guard status != .error, convError == nil, outBuffer.frameLength > 0 else {
            clipFailures += 1
            return
        }
        scheduleOnTimeline(outBuffer)
    }

    /// Schedules a `playerFormat` buffer pinned to a running sample-time
    /// playhead with a small lead, instead of a bare `scheduleBuffer` with
    /// no `at:`. Mirrors the web client's proven live-lane scheduling
    /// (`useStreamingCall.ts`: `start(max(ctx.currentTime + 0.03,
    /// nextTime))`), which the native path had never matched. Bare
    /// `scheduleBuffer` gives the render thread zero cushion, so the many
    /// tiny back-to-back PCM chunks a Spotter/Live turn arrives in can
    /// underrun between WebSocket frames and stutter -- heard as the reply
    /// "skipping" or racing. The ~80ms lead adds slack; taking the max of
    /// (now + lead) and the running playhead re-syncs forward if the
    /// stream ever falls behind rather than letting drift pile up. Degrades
    /// safely: a chunk that arrives so late its slot is already in the past
    /// just plays right away (exactly the old behavior), never worse. WAV
    /// clips ride the same one timeline as LIVE PCM here, matching the web
    /// client, which shares one playhead across both lanes so they can
    /// never overlap.
    private func scheduleOnTimeline(_ buffer: AVAudioPCMBuffer) {
        let rate = playerFormat.sampleRate
        let lead = AVAudioFramePosition(rate * 0.08)  // ~80ms jitter cushion
        let confirmPlayed: () -> Void = { [weak self] in
            Task { @MainActor in
                self?.clipsPlayed += 1
                self?.updateAudioDiagnostic()
            }
        }
        guard let renderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime) else {
            // Session 17/18's own bug report (a Spotter reply that got
            // scheduled -- clipsScheduled incremented -- but was never
            // actually audible) traced to exactly this branch: `lastRenderTime`/
            // `playerTime(forNodeTime:)` are nil right after the node (re)starts,
            // before its first real render callback -- true at the very
            // start of a fresh call, and plausibly again right after
            // `flushPlayback()`'s stop()+play() cycle (a barge-in, or the
            // clear() that can precede a Spotter/Live handoff). The
            // PREVIOUS version of this code fabricated `nowSample = 0` here
            // and pinned the buffer to a numeric sample-time built from
            // that guess -- which has no reliable relationship to the
            // node's REAL internal clock once it starts rendering, and a
            // buffer pinned to a wrong/effectively-past `AVAudioTime` can
            // be silently dropped by `AVAudioPlayerNode` rather than played
            // -- worse than the jitter this whole mechanism exists to fix,
            // and exactly the kind of silent failure `clipsScheduled` being
            // mislabeled "played" was masking. Falling back to the OLD,
            // proven-safe immediate scheduling (no `at:` time at all) for
            // just this one buffer costs nothing but the jitter cushion on
            // ONE clip; `nextPlayheadSample` stays nil so the NEXT buffer
            // tries the real pinned timeline fresh once a render time
            // actually exists, rather than building forward from a guess.
            playerNode.scheduleBuffer(buffer, completionHandler: confirmPlayed)
            nextPlayheadSample = nil
            clipsScheduled += 1
            return
        }
        let nowSample = playerTime.sampleTime
        let earliest = nowSample + lead
        let startAt = max(earliest, nextPlayheadSample ?? earliest)
        let when = AVAudioTime(sampleTime: startAt, atRate: rate)
        playerNode.scheduleBuffer(buffer, at: when, options: [], completionHandler: confirmPlayed)
        nextPlayheadSample = startAt + AVAudioFramePosition(buffer.frameLength)
        clipsScheduled += 1
    }

    /// Barge-in / `{type:'clear'}`: stop whatever's queued immediately.
    /// `AVAudioPlayerNode.stop()` clears its entire internal queue (unlike
    /// pausing); re-arming with `play()` leaves it ready for the next
    /// scheduled buffer, same net effect as the web client's
    /// `flushPlayback()` stopping every live `AudioBufferSourceNode`.
    private func flushPlayback() {
        guard engineRunning else { return }
        playerNode.stop()
        playerNode.play()
        nextPlayheadSample = nil   // stop() cleared the queue and reset the timeline
    }

    private func teardownAudio() {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
        stopNowPlaying()
        guard engineRunning else { return }
        engineRunning = false
        audioEngine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // FIX (session 14, same family as the silent-call bug one layer up):
        // leaving the session in `.playAndRecord` + `.voiceChat` after a call
        // is what made spoken replies in a TEXT conversation come out of the
        // EARPIECE afterwards -- `.playAndRecord` routes to the receiver by
        // default and nothing else in the app was resetting it. `VoiceService`
        // now sets its own category before every clip (the real fix), but
        // handing the session back in a sane state when a call ends is the
        // right thing to do regardless, and covers anything else that plays
        // audio without asking first.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    // MARK: - Lock screen controls

    /// Puts the call on the lock screen and Control Centre as a Now Playing
    /// item, with working controls. Kade asked for lock-screen call
    /// controls; worth being precise about what this is and isn't, because
    /// the distinction matters if someone extends it later:
    ///
    /// This is the **Now Playing / remote-command** route, not a Live
    /// Activity and not CallKit. A Live Activity needs a separate widget
    /// extension target (a real change to `project.yml` and the signing
    /// setup), and CallKit would make this look like a system phone call --
    /// which brings its own interruption behaviour and an "in call" status
    /// bar, and would be a much bigger, riskier change than anything shipped
    /// here so far. Now Playing gets the practical win -- see who you are
    /// talking to and hang up without unlocking -- for a fraction of the
    /// surface area.
    ///
    /// Pause/play is deliberately mapped to BARGE-IN rather than to
    /// pausing audio: there is no such thing as pausing a live call, and the
    /// nearest honest meaning of "the big button" mid-call is "stop talking
    /// and listen to me." Stop hangs up.
    private func startNowPlaying() {
        updateNowPlayingInfo()
        guard !remoteCommandsWired else { return }
        remoteCommandsWired = true
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.isEnabled = true
        _ = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.barge() }
            return .success
        }
        center.pauseCommand.isEnabled = true
        _ = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.barge() }
            return .success
        }
        center.stopCommand.isEnabled = true
        _ = center.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.stop() }
            return .success
        }
        // Skip controls are meaningless on a live call and an enabled-but-
        // dead control is worse than an absent one, especially by touch.
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.playCommand.isEnabled = false
    }

    /// Keeps the lock screen honest about who is actually talking -- once
    /// Spotter takes over, the lock screen must say so too, for the same
    /// reason the call screen does: there is no other way to know.
    private func updateNowPlayingInfo() {
        let who = liveOn ? (spotterName ?? "Your Spotter") : (agentName.isEmpty ? "Kade-AI" : agentName)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "On a call with \(who)",
            MPMediaItemPropertyArtist: "Kade-AI",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
    }

    private func stopNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        guard remoteCommandsWired else { return }
        remoteCommandsWired = false
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.stopCommand.removeTarget(nil)
    }
}

/// Self-healing mic converter, deliberately NOT `@MainActor`: lives only
/// inside the tap closure's captured state and is touched only from the
/// real-time audio thread, which `AVAudioEngine` guarantees calls a given
/// tap's callback serially (never concurrently with itself) -- same
/// single-threaded-by-construction safety as `CameraCaptureController`'s
/// `FrameSampler`. Rebuilds its `AVAudioConverter` whenever the incoming
/// buffer's format differs from the last one it converted, so it can never
/// go stale against whatever the input node is ACTUALLY delivering --
/// see `startAudioEngine()`'s comment for the live bug this replaced (a
/// converter built once from a format read at the wrong moment, which
/// silently broke every mic chunk after voice processing was enabled).
private final class MicConverterBox {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        if converter == nil || lastInputFormat != buffer.format {
            lastInputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return nil }
        return StreamingCallService.pcm16Data(from: buffer, to: outputFormat, using: converter)
    }
}

/// Loose envelope covering every `{type: ...}` JSON message the bridge
/// sends on `/ws/web-voice` (`ready`/`state`/`caption`/`clear`/`table`/
/// `error`/`live-notice`/`live-state`/`video-notice`/`video-state`) --
/// every field beyond `type` is optional since each message type only
/// populates a subset, mirroring how the web client just reads `any` off
/// the parsed JSON and switches on `m.type`.
private struct CallServerMessage: Decodable {
    let type: String
    let state: String?
    let role: String?
    let text: String?
    let id: String?
    let message: String?
    let on: Bool?
    let reason: String?
    let spotterName: String?
    let minutesLeft: Int?
}
