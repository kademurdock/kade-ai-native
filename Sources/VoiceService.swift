import Foundation
import AVFoundation

/// Phase 5: push-to-talk recording ("voice in") + spoken replies ("voice
/// out"). Deliberately does NOT use on-device speech frameworks
/// (SFSpeechRecognizer / AVSpeechSynthesizer) -- researched live 2026-07-19
/// against the fork's actual route/service files (see docs/ENDPOINTS.md)
/// and confirmed the fork already has a working, in-use speech pipeline at
/// `/api/files/speech/stt` (Deepgram) and `/api/files/speech/tts/manual`
/// (Inworld, 326 custom character voices) -- the SAME pipeline the web
/// app's own "Spotter" rooms use. Reusing it means this app's voice mode
/// sounds like the actual characters (Kiana, Big Tom, etc.) instead of a
/// generic system voice, and costs nothing new (same already-paid-for,
/// already-metered service). Both endpoints verified live this session,
/// including a full round-trip (real TTS audio fed back into STT and
/// correctly transcribed).
///
/// Two real findings from that live testing, worth keeping in mind:
/// 1. `/api/files/speech/tts/manual` claims `Content-Type: audio/mpeg` but
///    actually returns WAV bytes (RIFF/WAVE PCM), not real MP3 -- verified
///    by inspecting the raw response. `AVAudioPlayer(data:)` sniffs the
///    real container from the file header regardless of what the
///    Content-Type header claims, so this doesn't need special handling
///    here, just don't assume the header is trustworthy elsewhere.
/// 2. STT is not perfect (a live test mis-heard "Keighty" as "Katie") --
///    so transcribed text lands in the composer for review, it is never
///    auto-sent. See `ConversationDetailView`.
@MainActor
final class VoiceService: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var isSpeaking = false
    @Published var recordError: String?

    private let client: KadeAPIClient
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    private var currentPlayer: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Never>?
    private var speakQueue: [(text: String, agentId: String?, agentName: String?)] = []
    private var isPumping = false

    /// Playback rate for spoken replies. 1.0 is the voice's own natural
    /// pace; the picker offers 0.75x through 2x. Applied via
    /// `AVAudioPlayer.rate` (which needs `enableRate` set BEFORE `play()`),
    /// not by asking the TTS service for a different speed -- that would
    /// re-synthesize and re-bill every clip, and would change the voice's
    /// prosody rather than just how fast it plays back. Persisted in
    /// UserDefaults: this is exactly the lightweight, non-sensitive
    /// preference that belongs there rather than in the Keychain.
    @Published var playbackRate: Float = VoiceService.loadPlaybackRate() {
        didSet {
            UserDefaults.standard.set(playbackRate, forKey: Self.playbackRateKey)
            // Applies mid-clip, so a rate change while a long reply is
            // playing takes effect immediately instead of at the next one.
            currentPlayer?.rate = playbackRate
        }
    }

    private static let playbackRateKey = "kade.voiceMessage.playbackRate"

    /// The speeds offered in the picker. Deliberately a short, opinionated
    /// list rather than a slider: a slider is fiddly with VoiceOver and
    /// nobody actually wants 1.37x.
    static let availableRates: [Float] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// Compact form for the on-screen chip ("1x", "1.5x").
    nonisolated static func rateLabel(_ rate: Float) -> String {
        // Explicit Double conversion: String(format:) takes CVarArg and a
        // Float promoting through varargs is exactly the sort of thing that
        // is "probably fine" rather than known-correct, which is not a trade
        // worth making with no compiler here.
        rate == rate.rounded()
            ? String(format: "%.0fx", Double(rate))
            : String(format: "%.2gx", Double(rate))
    }

    /// Spoken form. "Normal speed" rather than "1x" for the default,
    /// because that is the useful thing to hear when checking where you are.
    nonisolated static func rateSpokenLabel(_ rate: Float) -> String {
        if rate == 1.0 { return "Normal speed" }
        return "\(rateLabel(rate)) speed"
    }

    private static func loadPlaybackRate() -> Float {
        let stored = UserDefaults.standard.float(forKey: playbackRateKey)
        // `float(forKey:)` returns 0 for "never set" -- which is also an
        // invalid rate, so one check covers both.
        return (stored >= 0.5 && stored <= 2.0) ? stored : 1.0
    }

    /// Session 17 (Kade: "a native way to access settings like speech and
    /// whatnot"): the default "Voice messages" starting state for a FRESH
    /// `ConversationDetailView` -- that screen's own `readAloudEnabled` is
    /// plain per-view `@State` (always started `false` before this),
    /// seeded from this published, persisted value in its `.task` instead.
    /// Lives here rather than in a separate prefs object because it is
    /// conceptually the same kind of setting as `playbackRate` right
    /// above -- one more small, non-sensitive speech preference, same
    /// persistence pattern, same home.
    @Published var defaultReadAloudOn: Bool = UserDefaults.standard.bool(forKey: "kade.voiceMessage.defaultReadAloudOn") {
        didSet {
            UserDefaults.standard.set(defaultReadAloudOn, forKey: "kade.voiceMessage.defaultReadAloudOn")
        }
    }

    private var voicesListCache: [String]?
    private var agentVoiceCache: [String: (voice: String?, speed: Double?)] = [:]

    struct VoiceError: Error {
        let message: String
    }

    init(client: KadeAPIClient) {
        self.client = client
        super.init()
    }

    /// Called on sign-out: stops anything in flight and clears per-account
    /// caches, matching `AgentsService.reset()` / `ConversationsService.reset()`.
    func reset() {
        stopSpeaking()
        if isRecording {
            _ = stopRecording()
        }
        voicesListCache = nil
        agentVoiceCache.removeAll()
        recordError = nil
    }

    // MARK: - Recording ("voice in")

    /// Requests mic permission if needed, then starts recording to a temp
    /// `.m4a` file. Returns `false` (and sets `recordError`) on permission
    /// denial or a session/recorder setup failure -- callers should treat a
    /// `false` return as "nothing started," not throw a generic error, since
    /// the specific reason (denied vs. hardware failure) is already in
    /// `recordError` for VoiceOver to read.
    func startRecording() async -> Bool {
        guard !isRecording else { return false }
        recordError = nil

        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .denied:
            recordError = "Microphone access is off for Kade-AI. Turn it on in Settings to talk instead of type."
            return false
        case .undetermined:
            let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            if !granted {
                recordError = "Microphone access is off for Kade-AI. Turn it on in Settings to talk instead of type."
                return false
            }
        case .granted:
            break
        @unknown default:
            break
        }

        do {
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            recordError = "Couldn't access the microphone. Try again."
            return false
        }
        // Haptics (Phase B/Phase 7 -- ConversationDetailView's send/
        // recording/reply feedback, added this session) can silently no-op
        // once `.playAndRecord` has exclusive control of the audio hardware
        // -- a real, documented iOS gotcha
        // (IOS_NATIVE_ADVANCED_TECHNIQUES_2026-07-19.md), not hypothetical.
        // This is the cheap, Apple-provided fix, applied once here since
        // this is the one place in the app that ever puts the session into
        // that category. Best-effort on purpose (`try?`, not folded into the
        // `do` above): never blocks recording itself from starting if this
        // one call fails for some reason -- the mic actually working matters
        // far more than haptics degrading gracefully.
        try? session.setAllowHapticsAndSystemSoundsDuringRecording(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kade-voice-\(UUID().uuidString).m4a")
        // AAC in an m4a container -- matches the fork's STTService.js
        // MIME_TO_EXTENSION_MAP (`audio/mp4` -> `m4a`, in its accepted-
        // formats list), and 16kHz mono is plenty for speech transcription
        // while keeping the upload small.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            let newRecorder = try AVAudioRecorder(url: url, settings: settings)
            guard newRecorder.record() else {
                recordError = "Couldn't start recording. Try again."
                return false
            }
            recorder = newRecorder
            recordingURL = url
            isRecording = true
            return true
        } catch {
            recordError = "Couldn't start recording. Try again."
            return false
        }
    }

    /// Stops the current recording and returns the file URL, or `nil` if
    /// nothing was recording. Caller is responsible for uploading (or
    /// discarding) the file; `transcribe(fileURL:)` deletes it once read
    /// either way.
    func stopRecording() -> URL? {
        guard isRecording else { return nil }
        recorder?.stop()
        recorder = nil
        isRecording = false
        return recordingURL
    }

    /// Uploads a recorded file to `/api/files/speech/stt` and returns the
    /// transcribed text. Always deletes the temp file, even on failure --
    /// there's nothing useful to retry from a stale recording, only from a
    /// fresh one.
    func transcribe(fileURL: URL) async throws -> String {
        isTranscribing = true
        defer { isTranscribing = false }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: fileURL)
        } catch {
            throw VoiceError(message: "Couldn't read the recording. Try again.")
        }
        try? FileManager.default.removeItem(at: fileURL)

        guard !audioData.isEmpty else {
            throw VoiceError(message: "That recording came out empty. Try again.")
        }

        let req = client.multipartRequest(
            path: "api/files/speech/stt",
            authorized: true,
            fields: [],
            fileField: "audio",
            fileData: audioData,
            fileName: "recording.m4a",
            fileMimeType: "audio/mp4"
        )

        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw VoiceError(message: "Couldn't understand that. Try again.")
        }

        struct STTResponse: Codable { let text: String }
        guard let decoded = try? JSONDecoder().decode(STTResponse.self, from: data) else {
            throw VoiceError(message: "Couldn't understand that. Try again.")
        }
        return decoded.text
    }

    // MARK: - Spoken replies ("voice out")

    /// Queues `text` to be spoken in `agentId`'s voice. Safe to call
    /// repeatedly while a previous line is still playing -- lines speak in
    /// order, one at a time, same as the web app's own read-aloud queue
    /// (`kadeRoomPage.js`'s `speakQ`/`pumpSpeech`).
    func enqueueSpeak(text: String, agentId: String?, agentName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        speakQueue.append((trimmed, agentId, agentName))
        guard !isPumping else { return }
        Task { await pumpSpeakQueue() }
    }

    /// Stops any current playback and drops everything still queued --
    /// used when the user turns Read Aloud off mid-speech.
    func stopSpeaking() {
        speakQueue.removeAll()
        currentPlayer?.stop()
        currentPlayer = nil
        playbackContinuation?.resume()
        playbackContinuation = nil
        isSpeaking = false
        isPumping = false
    }

    private func pumpSpeakQueue() async {
        isPumping = true
        isSpeaking = true
        while !speakQueue.isEmpty {
            let item = speakQueue.removeFirst()
            await speakOne(text: item.text, agentId: item.agentId, agentName: item.agentName)
        }
        isSpeaking = false
        isPumping = false
    }

    /// One clip failing to fetch or play never blocks the rest of the
    /// queue -- matches the web app's own `try{...}catch(e){ /* one bad
    /// clip never blocks the queue */ }` behavior exactly.
    private func speakOne(text: String, agentId: String?, agentName: String?) async {
        let (voice, speed) = await resolveVoice(agentId: agentId, agentName: agentName)

        var fields: [(String, String)] = [("input", text)]
        if let voice { fields.append(("voice", voice)) }
        if let speed { fields.append(("speed", String(speed))) }

        let req = client.multipartRequest(path: "api/files/speech/tts/manual", authorized: true, fields: fields)
        guard let (data, http) = try? await client.send(req), http.statusCode == 200, !data.isEmpty else {
            return
        }
        await playAudio(data)
    }

    /// FIX (Kade, session 14): "if the auto play is switched on in a text
    /// conversation, it switches to ear speaker instead of main."
    ///
    /// Root cause: this playback path never set an audio session category at
    /// all, so it inherited whatever was left behind by the last thing that
    /// DID. Two things in this app set one, and both leave `.playAndRecord`
    /// active afterwards: `startRecording()` above (sending a voice message)
    /// and `StreamingCallService.startAudioEngine()` (a call, which also
    /// sets `.voiceChat` MODE). **`.playAndRecord` routes to the built-in
    /// RECEIVER -- the earpiece -- by default**, and `.voiceChat` mode makes
    /// that stickier still. So a reply spoken after either of those came out
    /// of the earpiece, exactly as reported, while a reply spoken on a fresh
    /// launch came out of the speaker. Same family of bug as build 120's
    /// silent-call fix, one layer up.
    ///
    /// `.playback` is the correct category for this (output only, no mic),
    /// and it routes to the speaker. `.mixWithOthers` is deliberate and
    /// carried forward from an earlier fix in the Capacitor app: without it
    /// this session DUCKS VoiceOver, which for this user is not a cosmetic
    /// problem -- her screen reader going quiet or quiet-ish under a spoken
    /// reply is the app fighting itself.
    ///
    /// Fail-soft on purpose: if the category can't be set for some reason,
    /// still play. Wrong-sounding output beats silence.
    private func prepareOutputSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func playAudio(_ data: Data) async {
        prepareOutputSession()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            do {
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                // `enableRate` MUST be set before `play()` -- setting it
                // afterwards silently does nothing, which is the kind of
                // thing that looks fine in review and is dead on device.
                player.enableRate = true
                player.rate = playbackRate
                currentPlayer = player
                playbackContinuation = continuation
                if !player.play() {
                    playbackContinuation = nil
                    continuation.resume()
                }
            } catch {
                continuation.resume()
            }
        }
    }

    // MARK: - Voice message files (save / share)

    /// Synthesizes `text` in the right voice and hands back the raw audio
    /// plus a filename with the CORRECT extension for what actually came
    /// back. Kade asked for a download button; a downloaded file with the
    /// wrong extension is a file that won't open, so the container is
    /// sniffed from the bytes rather than trusted from the response header
    /// -- this endpoint is already known to claim `audio/mpeg` while
    /// returning WAV (see this file's header note), so the header is exactly
    /// the wrong thing to believe here.
    func voiceMessageFile(text: String, agentId: String?, agentName: String?) async -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let (voice, speed) = await resolveVoice(agentId: agentId, agentName: agentName)

        var fields: [(String, String)] = [("input", trimmed)]
        if let voice { fields.append(("voice", voice)) }
        if let speed { fields.append(("speed", String(speed))) }

        let req = client.multipartRequest(path: "api/files/speech/tts/manual", authorized: true, fields: fields)
        guard let (data, http) = try? await client.send(req), http.statusCode == 200, !data.isEmpty else {
            return nil
        }

        let name = Self.suggestedFileName(for: agentName, ext: Self.audioExtension(for: data))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Container sniff by magic bytes. Compared through `prefix`/
    /// `elementsEqual` rather than index subscripting, for the same reason
    /// as `StreamingCallService.handleBinary`: `Data` indices are not
    /// guaranteed to start at zero.
    nonisolated static func audioExtension(for data: Data) -> String {
        func startsWith(_ bytes: [UInt8]) -> Bool {
            data.count >= bytes.count && data.prefix(bytes.count).elementsEqual(bytes)
        }
        if startsWith([0x52, 0x49, 0x46, 0x46]) { return "wav" }  // "RIFF"
        if startsWith([0x4F, 0x67, 0x67, 0x53]) { return "ogg" }  // "OggS"
        if startsWith([0x66, 0x4C, 0x61, 0x43]) { return "flac" } // "fLaC"
        if startsWith([0x49, 0x44, 0x33]) { return "mp3" }        // "ID3"
        if startsWith([0xFF, 0xFB]) || startsWith([0xFF, 0xF3]) || startsWith([0xFF, 0xF2]) { return "mp3" }
        if data.count >= 12, data.dropFirst(4).prefix(4).elementsEqual([0x66, 0x74, 0x79, 0x70]) { return "m4a" } // "ftyp"
        // Unknown container: WAV is what this endpoint has actually been
        // observed to return, so it's the least-wrong default.
        return "wav"
    }

    /// A filename she can find again by ear in the Files app: who said it
    /// and when, not a UUID.
    nonisolated static func suggestedFileName(for agentName: String?, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = formatter.string(from: Date())
        let who = (agentName ?? "Kade-AI")
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeWho = who.isEmpty ? "Kade-AI" : who
        return "Voice message from \(safeWho) \(stamp).\(ext)"
    }

    // MARK: - Voice selection

    private struct AgentTTSDetail: Codable {
        struct TTS: Codable {
            let voiceId: String?
            let speakingRate: Double?
        }
        let tts: TTS?
    }

    /// Resolves which catalog voice speaks for a given agent. Checks the
    /// agent's own configured `tts.voiceId` first (`GET /api/agents/:id`,
    /// confirmed live to include `tts` in even the basic VIEW-permission
    /// response -- read the controller's own comment: "the agent's default
    /// TTS voice must be visible to any viewer so their client can speak
    /// this agent with its intended voice"); falls back to a deterministic
    /// hash of the agent's name over the full voice catalog if no explicit
    /// voice is configured. Cached per agentId for the rest of the sign-in
    /// session -- an agent's assigned voice isn't expected to change
    /// mid-conversation, and re-fetching per reply would burn the shared
    /// pacing budget for no benefit.
    private func resolveVoice(agentId: String?, agentName: String?) async -> (voice: String?, speed: Double?) {
        if let agentId, let cached = agentVoiceCache[agentId] {
            return cached
        }

        var resolvedVoice: String?
        var resolvedSpeed: Double?

        if let agentId {
            let req = client.request(path: "api/agents/\(agentId)", authorized: true)
            if let (data, http) = try? await client.send(req),
               http.statusCode == 200,
               let detail = try? JSONDecoder().decode(AgentTTSDetail.self, from: data) {
                resolvedVoice = detail.tts?.voiceId
                resolvedSpeed = detail.tts?.speakingRate
            }
        }

        if resolvedVoice == nil {
            let voices = await fetchVoicesList()
            resolvedVoice = Self.hashVoice(for: agentName ?? agentId ?? "assistant", voices: voices)
        }

        let result = (resolvedVoice, resolvedSpeed)
        if let agentId {
            agentVoiceCache[agentId] = result
        }
        return result
    }

    /// `GET /api/files/speech/tts/voices` -- verified live 2026-07-19: a
    /// plain JSON array of 326 strings like "Voice 11", not wrapped in an
    /// object. Cached for the sign-in session (same reasoning as
    /// `AgentsService`'s agent-list cache).
    private func fetchVoicesList() async -> [String] {
        if let voicesListCache { return voicesListCache }
        let req = client.request(path: "api/files/speech/tts/voices", authorized: true)
        guard let (data, http) = try? await client.send(req),
              http.statusCode == 200,
              let voices = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        voicesListCache = voices
        return voices
    }

    /// Mirrors the web app's own per-agent voice fallback exactly
    /// (`kadeRoomPage.js`'s `voiceFor()`, read live 2026-07-19) so a given
    /// agent sounds like the SAME voice whether Kade hears it through the
    /// web app's Spotter rooms or here -- a plain djb2-style hash of the
    /// agent's name, unsigned 32-bit wraparound, indexed into the full
    /// voice catalog. Known simplification: the web version iterates
    /// UTF-16 code units; this iterates Unicode scalars. Every agent name
    /// on this account is plain ASCII, where the two produce identical
    /// results, so this doesn't matter today -- flagged here in case that
    /// ever changes.
    private static func hashVoice(for name: String, voices: [String]) -> String? {
        guard !voices.isEmpty else { return nil }
        var h: UInt32 = 0
        for scalar in name.unicodeScalars {
            h = h &* 31 &+ scalar.value
        }
        return voices[Int(h % UInt32(voices.count))]
    }
}

extension VoiceService: AVAudioPlayerDelegate {
    // AVAudioPlayerDelegate is an @objc protocol and its callback isn't
    // guaranteed to land on the main actor, even though this whole class
    // is @MainActor -- explicitly `nonisolated` + hopping back via `Task {
    // @MainActor in ... }` is the always-correct pattern here regardless
    // of which concurrency-checking mode this build uses, which matters a
    // lot with no local compiler to verify a riskier assumption.
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.currentPlayer = nil
            self.playbackContinuation?.resume()
            self.playbackContinuation = nil
        }
    }
}
