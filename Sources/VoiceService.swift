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
    /// True only while a TTS clip is actually coming out of the speaker.
    /// `isSpeaking` (above) flips true when the speak QUEUE starts -- i.e.
    /// before the network fetch -- so it cannot tell "fetching" apart from
    /// "playing." This one flips at a successful `player.play()` and back on
    /// finish/stop. It exists for the chat lane's autoplay handoff (see
    /// ConversationDetailView's sendState watcher): the waiting ticks keep
    /// running through the TTS fetch and stop the instant the voice starts.
    @Published private(set) var isClipPlaying = false
    /// Aug 4 2026 (Kade: "The stop button on voice messages should prob just
    /// be a pause button"): true while the current clip is paused mid-play.
    /// `isClipPlaying` deliberately STAYS true while paused -- the clip is
    /// still "the thing on deck," which is what the composer button and the
    /// row actions key off to stay enabled.
    @Published private(set) var isPaused = false
    /// The caller-supplied tag (chat uses the message id) of the item
    /// currently playing, so a message row's own "Play as voice message"
    /// action can morph into Pause/Resume for exactly the message that is
    /// speaking. Nil when idle or when the item carried no tag.
    @Published private(set) var nowPlayingKey: String?
    @Published var recordError: String?

    private let client: KadeAPIClient
    private var recorder: AVAudioRecorder?
    /// Session 23 (Kade: "I don't think I want an auto stop if you mean a
    /// limit to how long you can record. But if you mean between recording
    /// and silence, that's fine."): the old hard 60-second cap is GONE.
    /// Recordings now run as long as she's talking; the only auto-stop is
    /// silence-based -- an abandoned mic (VoiceOver focus wandered off, a
    /// call came in, the phone went in a pocket) is by definition a SILENT
    /// one, so this catches exactly the accident the old cap existed for
    /// without ever cutting off a real, long thought.
    private var silenceWatch: Task<Void, Never>?
    private var onSilenceAutoStop: (@MainActor () -> Void)?
    private var recordingURL: URL?

    private var currentPlayer: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Never>?
    /// Session 35 part 3 (the Debate Room's voices): items may carry an
    /// EXPLICIT voice/rate (the room's cast snapshot already knows who
    /// sounds like what — no per-line agent resolve needed) and an optional
    /// completion so a caller can AWAIT one line finishing (auto-advance
    /// paces itself on real playback, not guesses). Chat's enqueueSpeak
    /// path is byte-identical in behavior: nil/nil/nil.
    /// Part 91.10 — named so the prefetcher can take one whole.
    typealias SpeakItem = (text: String, agentId: String?, agentName: String?, explicitVoice: String?, explicitRate: Double?, key: String?, completion: CheckedContinuation<Void, Never>?)
    private var speakQueue: [SpeakItem] = []
    private var isPumping = false
    /* PART 91.9 — THE SECOND PUMP, and it is why she heard "a couple of
     * seconds of each chunk and then the next one."
     *
     * `isPumping` is set INSIDE pumpSpeakQueue, which runs in a Task — so it
     * is still false when enqueueSpeak returns. Enqueue twice before that Task
     * gets a turn and BOTH calls pass the guard and BOTH spawn a pump. Two
     * pumps then race the same queue, and since `currentPlayer` is a single
     * property, the second player overwrites the first — dropping its only
     * strong reference, so ARC deallocates a player that is still speaking.
     * The clip dies a second or two in and the next one starts.
     *
     * This race has always been here. Nothing ever triggered it because
     * enqueueSpeak was called once per reply. Streaming speech calls it
     * several times in a row from one synchronous loop, which is exactly the
     * condition it needed. `pumpScheduled` is set SYNCHRONOUSLY, before the
     * Task exists, so the second caller can see it. */
    private var pumpScheduled = false
    /* Part 91.10 — the pump raises this while it holds a prefetched clip, so
     * stopSpeaking can tell the pump to drop what it is carrying. The pump
     * owns the prefetch task; stop cannot reach into the loop, so it leaves a
     * flag the loop checks the moment it wakes. */
    private var cancelGeneration = 0
    /* PART 92.13 — THE KEY THE STREAMED TURN DID NOT HAVE.
     *
     * Her report on build 243, 7am: "when I tried to pause the voice message
     * from where it started auto playing by default, it just reloaded a new
     * instance of the voice clip. Like regenerated one as if it weren't
     * already playing."
     *
     * It was not already playing — AS FAR AS THE ROW KNEW. 91.6's streaming
     * lane enqueues every piece with `key: nil`, because while the reply is
     * still being written the server has not given it an id yet. So
     * `nowPlayingKey` stays nil for the whole spoken reply, MessageRow's
     * `voicePlayback` (nowPlayingKey == message.id) reads `.idle`, and the
     * control she pressed was not Pause at all — it was READ ALOUD, which
     * correctly did what it says and synthesised the message from the top.
     * The non-streaming path passes `key: reply.id` and has always worked,
     * which is exactly why this hid: pause works on a message you tap read-
     * aloud on yourself, and only fails on the one that started by itself.
     *
     * ⚠️ 92.12 made this EASIER to hit rather than causing it. Bigger pieces
     * and depth 2 mean more audio is still queued when the stream ends, so
     * the window where she can reach for pause got longer.
     *
     * The id exists by the time the authoritative reload lands, so the fix is
     * to adopt it then: stamp the clip currently playing, everything still
     * queued, and — via this property — everything the pump has in flight. */
    private var streamedTurnKey: String?

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
    /// The signed-in user's OWN per-agent voice picks ({agentId: voice}),
    /// which override the agent's builder default. Loaded once from
    /// `GET /api/kade/voice-prefs`; nil until first load.
    private var userVoicePrefs: [String: String]?

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
        userVoicePrefs = nil
        recordError = nil
    }

    // MARK: - Recording ("voice in")

    /// Requests mic permission if needed, then starts recording to a temp
    /// `.m4a` file. Returns `false` (and sets `recordError`) on permission
    /// denial or a session/recorder setup failure -- callers should treat a
    /// `false` return as "nothing started," not throw a generic error, since
    /// the specific reason (denied vs. hardware failure) is already in
    /// `recordError` for VoiceOver to read.
    func startRecording(
        silenceStopAfter: TimeInterval? = nil,
        onSilenceAutoStop: (@MainActor () -> Void)? = nil
    ) async -> Bool {
        self.onSilenceAutoStop = onSilenceAutoStop
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
            // Aug 13 2026 — AMBER'S AIRPODS BUG, root-caused. `.playAndRecord`
            // with ONLY `.defaultToSpeaker` makes a Bluetooth headset
            // ineligible for the session: no `.allowBluetooth` means no HFP,
            // and A2DP is output-only so it can't serve a record category at
            // all. The moment she hit record with AirPods in, iOS had no
            // choice but built-in mic + built-in speaker — sound "kept
            // pushing out the speaker," and her voice note wasn't even using
            // the AirPods mic she thought she was talking into. Every retry
            // re-broke the route, which read as "can't get it back at all."
            //
            // `.allowBluetooth` (HFP) fixes both halves: with AirPods in, the
            // mic is the AirPods and the audio stays in her ears. Voice drops
            // to phone-call quality while recording — that's Bluetooth
            // physics, same as Siri and every phone call, and it recovers the
            // moment the session is restored below.
            //
            // `.allowBluetoothA2DP` is deliberately NOT added, on the call
            // lane's own paid-for lesson (StreamingCallService, build 119):
            // A2DP is output-only, and combining it with a record category is
            // a known source of odd route selection.
            //
            // `.defaultToSpeaker` stays: with NO headset connected, output
            // belongs on the loud speaker, not the earpiece — unchanged
            // behavior for the no-AirPods case (the option only applies when
            // no external route exists, so it never fights a headset).
            try session.setCategory(.playAndRecord, options: [.allowBluetooth, .defaultToSpeaker])
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
            newRecorder.isMeteringEnabled = true
            guard newRecorder.record() else {
                recordError = "Couldn't start recording. Try again."
                // The session was already activated as .playAndRecord above;
                // bail without restoring and the speaker-routing bug comes
                // back through the failure door.
                restorePlaybackSession()
                return false
            }
            recorder = newRecorder
            recordingURL = url
            isRecording = true
            if let window = silenceStopAfter { startSilenceWatch(window: window) }
            return true
        } catch {
            recordError = "Couldn't start recording. Try again."
            restorePlaybackSession()
            return false
        }
    }

    /// Polls the recorder's average power a few times a second and calls
    /// `onSilenceAutoStop` once `window` seconds pass with nothing louder
    /// than the threshold. Any real sound resets the clock, so a long
    /// recording full of talking never trips this -- only a mic left
    /// running with nobody speaking does. -44 dBFS sits comfortably below
    /// conversational speech at arm's length while staying above most
    /// room hiss; the poll interval keeps the cost negligible.
    private func startSilenceWatch(window: TimeInterval) {
        silenceWatch?.cancel()
        let interval: TimeInterval = 0.4
        silenceWatch = Task { [weak self] in
            // Inherits this class's MainActor context; each tick is a few
            // property reads and one updateMeters() -- negligible on main.
            var silentFor: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, self.isRecording, let rec = self.recorder else { return }
                rec.updateMeters()
                let power = rec.averagePower(forChannel: 0)
                if power > -44 {
                    silentFor = 0
                } else {
                    silentFor += interval
                    if silentFor >= window {
                        self.onSilenceAutoStop?()
                        return
                    }
                }
            }
        }
    }

    /// Stops the current recording and returns the file URL, or `nil` if
    /// nothing was recording. Caller is responsible for uploading (or
    /// discarding) the file; `transcribe(fileURL:)` deletes it once read
    /// either way.
    func stopRecording() -> URL? {
        guard isRecording else { return nil }
        silenceWatch?.cancel()
        silenceWatch = nil
        onSilenceAutoStop = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        // Aug 13 2026, the second half of Amber's AirPods bug: this method
        // stopped the RECORDER but never touched the SESSION, so
        // `.playAndRecord + .defaultToSpeaker` stayed the live category for
        // the rest of the app's life — every earcon and reply after one
        // voice note played out the phone speaker instead of her AirPods.
        // Same restore shape as StreamingCallService's call teardown:
        // deactivate (with the courtesy flag so backgrounded audio apps get
        // their session back), then park the category on `.playback` so the
        // next reply routes to A2DP — which is the AirPods again.
        restorePlaybackSession()
        return recordingURL
    }

    /// The record session's exit door. Fail-soft like every session call in
    /// this file: a restore hiccup must never eat the recording that was
    /// just made — the file URL is already in hand when this runs.
    private func restorePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
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
    func enqueueSpeak(text: String, agentId: String?, agentName: String?, key: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        supersedePausedClip()
        speakQueue.append((trimmed, agentId, agentName, nil, nil, key, nil))
        guard !isPumping, !pumpScheduled else { return }
        pumpScheduled = true
        Task { await pumpSpeakQueue(); pumpScheduled = false }
    }

    /// Aug 4 2026 evening (her report, same day the Pause button shipped:
    /// a new reply "didn't play automatically when it was sent, and when I
    /// pressed resume it just did the clip I was listening to before"):
    /// a PAUSED clip parks the queue on purpose -- but a NEW voice message
    /// arriving behind it turned that into a hostage situation, because the
    /// pump sits awaiting the paused clip's continuation forever. The rule
    /// now: pause means "hold that thought," never "block everything after
    /// it" -- anything newly enqueued SUPERSEDES a paused clip. The paused
    /// player is stopped, its parked continuation resumed (the pump wakes
    /// and advances), and the new clip plays. A clip that's actually
    /// PLAYING is untouched -- the new item queues behind it normally.
    private func supersedePausedClip() {
        guard isPaused else { return }
        currentPlayer?.stop()
        currentPlayer = nil
        isPaused = false
        isClipPlaying = false
        nowPlayingKey = nil
        playbackContinuation?.resume()
        playbackContinuation = nil
    }

    /// The streamed reply finally has a real message id — give it to every
    /// piece of that reply so the row can tell it is playing. Safe to call
    /// more than once and safe to call when nothing is playing.
    func adoptStreamedTurn(as key: String) {
        streamedTurnKey = key
        // The clip in the speaker right now, if it came from the stream.
        if isClipPlaying, nowPlayingKey == nil { nowPlayingKey = key }
        // Everything still waiting its turn.
        for i in speakQueue.indices where speakQueue[i].key == nil {
            speakQueue[i].key = key
        }
    }

    /// Session 35 part 3: speak ONE line in an explicit voice and return
    /// only when it has finished playing (or failed, or been stopped).
    /// The Debate Room's autoplay and auto-advance pace themselves on
    /// this. Rides the same queue as enqueueSpeak, so a room line and a
    /// chat reply can never talk over each other.
    func speakLine(text: String, voiceId: String?, rate: Double?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            supersedePausedClip()
            speakQueue.append((trimmed, nil, nil, voiceId, rate, nil, continuation))
            guard !isPumping, !pumpScheduled else { return }
            pumpScheduled = true
            Task { await self.pumpSpeakQueue(); self.pumpScheduled = false }
        }
    }

    /// Stops any current playback and drops everything still queued --
    /// used when the user turns Read Aloud off mid-speech.
    func stopSpeaking() {
        // Never strand an awaiting caller: resume any queued completions
        // BEFORE dropping the items, or `speakLine` callers would hang
        // forever on a continuation nobody owns anymore.
        for item in speakQueue { item.completion?.resume() }
        speakQueue.removeAll()
        /* Part 91.10 — invalidate anything the pump has already fetched or is
         * fetching. Without this, a stop mid-reply still plays the sentence
         * that was queued up behind it: she turns Read Aloud off and hears one
         * more sentence anyway, which reads as the switch being broken. */
        cancelGeneration &+= 1
        currentPlayer?.stop()
        currentPlayer = nil
        playbackContinuation?.resume()
        playbackContinuation = nil
        isSpeaking = false
        isClipPlaying = false
        isPaused = false
        nowPlayingKey = nil
        isPumping = false
        streamedTurnKey = nil
    }

    /// Aug 4 2026: pause the clip that's playing right now, resumable with
    /// `resumeSpeaking()`. A pause is NOT a stop -- the queue keeps waiting
    /// (the playback continuation stays parked), so anything queued behind
    /// this clip plays in order after a resume, and `isSpeaking` never
    /// flickers (the chat lane's dead-air watcher must not mistake a pause
    /// for "TTS finished"). No-op while nothing is actually playing --
    /// pausing a clip that's still FETCHING has nothing to pause yet, and
    /// the composer button routes that case to a full stop instead.
    func pauseSpeaking() {
        guard let player = currentPlayer, player.isPlaying else { return }
        player.pause()
        isPaused = true
    }

    /// Resumes a paused clip exactly where it left off. Re-prepares the
    /// output session first -- the same defensive move `playAudio` makes --
    /// because a call or recording may have re-routed audio while paused.
    func resumeSpeaking() {
        guard let player = currentPlayer, isPaused else { return }
        prepareOutputSession()
        if player.play() {
            isPaused = false
        }
    }

    /// The full TTS voice catalog ("Voice 1"..."Voice 326"), cached for the
    /// session. Public so the Agent Builder's voice picker can browse it.
    func availableVoices() async -> [String] {
        await fetchVoicesList()
    }

    /// Audition one voice: synthesize a short sample line in `voiceId` and
    /// play it, so a voice can be heard before it's assigned. Independent of
    /// the read-aloud queue; stops any current playback first so rapid
    /// previews never stack up.
    /// Aug 6 2026 (her "native is my premium platform" pass): two lengths.
    /// `long` (default) sends the sentinel the proxy swaps for the FULL
    /// performed audition — steering beats, both providers' dialects, the
    /// works. Quick sends a genuinely short line (deliberately NOT the
    /// sentinel, so no swap fires).
    func previewVoice(_ voiceId: String, long: Bool = true) async {
        let sample = long
            ? "Hi there. This is how I sound."
            : "Hey — quick hello from this voice, right here with you."
        await previewVoice(voiceId, sample: sample)
    }

    func previewVoice(_ voiceId: String, sample: String) async {
        stopSpeaking()
        let fields: [(String, String)] = [("input", sample), ("voice", voiceId)]
        let req = client.multipartRequest(path: "api/files/speech/tts/manual", authorized: true, fields: fields)
        guard let (data, http) = try? await client.send(req), http.statusCode == 200, !data.isEmpty else { return }
        await playAudio(data)
    }

    private func pumpSpeakQueue() async {
        isPumping = true
        isSpeaking = true
        let generation = cancelGeneration
        /* PART 92.12 — TWO CLIPS IN FLIGHT, NOT ONE.
         *
         * 91.10 held exactly one, and its comment argued against two: a deeper
         * queue synthesizes text the user may never hear (they stop, or a new
         * reply supersedes it) and every one of those costs real money.
         *
         * That reasoning is still true and it is now outweighed, so it is being
         * overruled deliberately rather than quietly. The waste case is bounded:
         * one extra clip per INTERRUPTED reply, ~160 characters after the piece-
         * sizing change — pennies. The case for depth is the Aug 24 spike, when
         * Inworld's fixed per-request overhead went ~1.31s -> ~5.9s for half an
         * hour and a family member heard 5+ second holes.
         *
         * Piece sizing and prefetch depth are doing DIFFERENT jobs, which is why
         * the fix needs both. Sizing sets the margin on each sentence: a 160-char
         * floor clears a 5.9s overhead. Depth sets how many sentences of runway
         * is banked, so margin earned on long sentences can pay for one slow one.
         * Bigger pieces at depth 1 survive a repeat of Aug 24. Depth 2 is what
         * survives a worse night, because it tolerates VARIANCE instead of just
         * moving the threshold. (Forge's call, asked for by Kade before shipping.) */
        let prefetchDepth = 2
        var inflight: [(item: SpeakItem, task: Task<Data?, Never>)] = []
        /* ⭐ PART 94 — AN ERROR TONE IN THE MIDDLE OF A REPLY IS A LIE.
         *
         * Her report, Aug 28 2026: "one of the sections of voiceclip gave an
         * error sound" — the earcon fired mid-message and the rest of the
         * reply kept playing, so what she heard was a hole with an alarm in
         * it. The alarm was the honest thing to do in session 23, when the
         * only alternative was silence indistinguishable from read-aloud
         * never firing at all. It stopped being honest the day this pump
         * started streaming a reply as N separate synthesis calls: one
         * sentence hiccuping is not "something broke," and 92.11 already
         * showed a single reply making 29 of these calls.
         *
         * So the tone now means what a listener assumes it means — YOU GOT
         * NOTHING — and nothing else. A piece that dies while other pieces
         * are playing is skipped quietly and left in the breadcrumb trail,
         * where a session can find it without her having to describe a sound.
         * A whole reply that never makes a sound still boops, exactly once,
         * however many of its pieces failed.
         *
         * ⚠️ THE KNOWN EDGE, said plainly rather than hidden: `playedAnything`
         * is scoped to this PUMP RUN, not to one reply, so a second reply that
         * fails completely while a first one played fine goes quiet instead of
         * booping. Scoping it per reply was tried and is worse — a streamed
         * reply's pieces carry a nil key until adoptStreamedTurn lands one
         * mid-flight, so a per-key reset would fire a false alarm in the exact
         * middle of a reply, which is the bug being fixed. A missed tone beats
         * a wrong tone. */
        var playedAnything = false
        var failedPieces = 0
        /// Fill the pipe up to `current + prefetchDepth` without ever awaiting —
        /// every prefetch started here overlaps the clip already playing.
        func topUp() {
            while inflight.count <= prefetchDepth, !speakQueue.isEmpty {
                let next = speakQueue.removeFirst()
                inflight.append((next, prefetch(next)))
            }
        }
        /* PART 97.3 (Aug 29 2026) — THE OPENER GETS A CLEAR LANE.
         *
         * Her report, an hour after build 249: "why is there such a big space
         * between the received message and the tts reading out." Measured
         * before touched: solo synth on her voice 1.4–2.1s, the same request
         * with the pump's opening move (three synths at once, because topUp
         * filled to depth BEFORE the first clip's data ever arrived) 2.3–2.5s
         * — and during that afternoon's provider wobble the proxy logged
         * single pieces at 3.5–5.6s, which is what a listener calls a big
         * space. The opener was paying a contention tax to build a runway
         * nobody could hear yet.
         *
         * So the first piece now synthesises ALONE, and the pipe fills the
         * moment its data is in hand — every later synthesis runs under a
         * clip that is actually PLAYING, which always outlasts a synth, so
         * 92.12's depth-2 spike margin is untouched from piece two onward.
         * The only trade: nothing overlaps the opener's synth, which is the
         * point. */
        if !speakQueue.isEmpty {
            let first = speakQueue.removeFirst()
            inflight.append((first, prefetch(first)))
        }
        while !inflight.isEmpty {
            let current = inflight.removeFirst()
            let data = await current.task.value
            // Stopped while that was in flight? Drop it, resume the waiter,
            // and leave — never speak past a stop.
            if generation != cancelGeneration {
                current.task.cancel()
                current.item.completion?.resume()
                for pending in inflight {
                    pending.task.cancel()
                    pending.item.completion?.resume()
                }
                inflight.removeAll()
                isSpeaking = false
                isPumping = false
                return
            }
            // Refill now that this clip's data is in hand — the next
            // syntheses run under ITS playback (or its skip), never under
            // the opener's synth. Part 97.3; see the note above the loop.
            topUp()
            if let data {
                // `?? streamedTurnKey` covers the pieces that were prefetched
                // BEFORE the reload handed us an id — they are already out of
                // speakQueue, so adoptStreamedTurn cannot reach them directly.
                await playAudio(data, key: current.item.key ?? streamedTurnKey)
                playedAnything = true
            } else {
                // Session 23's boop lives on below, at the END of the pump and
                // only if nothing at all was spoken. See the note up top.
                failedPieces += 1
                KadeBreadcrumbs.drop("tts: piece would not synthesise, skipped silently (\(failedPieces) this run)")
            }
            current.item.completion?.resume()
            nowPlayingKey = nil
            isPaused = false
            // Sentences that streamed in during playback join the pipe now.
            topUp()
        }
        // Session 23's rule, kept and narrowed: a reply that made no sound at
        // all must never be indistinguishable from read-aloud never firing.
        if failedPieces > 0 && !playedAnything {
            KadeBreadcrumbs.drop("tts: WHOLE reply failed to synthesise (\(failedPieces) pieces) -- earcon")
            Earcons.shared.play(.error)
        }
        isSpeaking = false
        isPumping = false
        streamedTurnKey = nil
    }

    /* PART 91.10 — SYNTHESIS SPLIT OUT OF PLAYBACK, so the next sentence can
     * be fetched while the current one is still being spoken.
     *
     * Her report on build 155: "long gappy silences between chunks." Measured
     * against the live endpoint: a ~95-character sentence takes about two
     * seconds to synthesize and yields about four seconds of audio. The pump
     * was strictly serial — fetch, play, fetch, play — so every sentence
     * boundary cost a full two-second round trip of dead air. One big
     * synthesis used to pay that once; streaming pays it N times.
     *
     * Because playback (4s) comfortably outlasts synthesis (2s), fetching ONE
     * ahead hides the cost completely. This is the same trick the phone lane
     * has always used, and the reason a call never has gaps between
     * sentences. */
    private func synthesize(
        text: String,
        agentId: String?,
        agentName: String?,
        explicitVoice: String?,
        explicitRate: Double?
    ) async -> Data? {
        // An explicit voice (Debate Room cast snapshot) skips the network
        // resolve entirely; an empty-string voiceId means "uncast" and
        // falls through to the resolver exactly like nil.
        let (voice, speed): (String?, Double?)
        if let explicitVoice, !explicitVoice.isEmpty {
            (voice, speed) = (explicitVoice, explicitRate)
        } else {
            (voice, speed) = await resolveVoice(agentId: agentId, agentName: agentName)
        }

        var fields: [(String, String)] = [("input", text)]
        if let voice { fields.append(("voice", voice)) }
        if let speed { fields.append(("speed", String(speed))) }

        /* ⭐ PART 94 — ONE RETRY, BECAUSE THE FAILURE CLASS HERE IS LATENCY.
         *
         * Every measured failure on this endpoint has been transient: the
         * Aug-24 Inworld spike (fixed overhead 1.31s -> 5.9s for half an
         * hour, same voice, same text, no deploy of ours), a 5xx from the
         * proxy's upstream, a timeout. That class usually clears on the very
         * next attempt, and the cost of finding out is one extra call on a
         * piece that was otherwise going to be a hole in her reply.
         *
         * Only the transient class is retried. A 401, a 400, a 413 will fail
         * identically the second time and retrying them just doubles the
         * spend and the wait. A 200 carrying zero bytes IS transient — 92.11
         * measured that shape live on this exact endpoint.
         *
         * The request is rebuilt each attempt rather than reused: a
         * multipart body is a stream, and handing a consumed one back to
         * URLSession is a class of bug that reads as "the server did it." */
        func transientStatus(_ code: Int) -> Bool {
            code >= 500 || code == 408 || code == 429
        }
        for attempt in 0...1 {
            let req = client.multipartRequest(path: "api/files/speech/tts/manual", authorized: true, fields: fields)
            guard let (data, http) = try? await client.send(req) else {
                // No response at all -- the most transient shape there is.
                if attempt == 0 { try? await Task.sleep(nanoseconds: 400_000_000); continue }
                KadeBreadcrumbs.drop("tts: no response after retry (\(text.count) chars)")
                return nil
            }
            if http.statusCode == 200, !data.isEmpty {
                if attempt == 1 { KadeBreadcrumbs.drop("tts: recovered on retry") }
                return data
            }
            let retryable = transientStatus(http.statusCode) || (http.statusCode == 200 && data.isEmpty)
            guard retryable, attempt == 0 else {
                KadeBreadcrumbs.drop("tts: synth failed HTTP \(http.statusCode), \(data.count) bytes")
                return nil
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return nil
    }

    /// Kick a synthesis off now and hand back the handle. Nothing awaits this
    /// until its turn comes, which is the whole point.
    private func prefetch(_ item: SpeakItem) -> Task<Data?, Never> {
        Task { [weak self] in
            guard let self else { return nil }
            return await self.synthesize(
                text: item.text,
                agentId: item.agentId,
                agentName: item.agentName,
                explicitVoice: item.explicitVoice,
                explicitRate: item.explicitRate
            )
        }
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

    private func playAudio(_ data: Data, key: String? = nil) async {
        prepareOutputSession()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            do {
                /* Belt and braces for the same class of fault: if a
                 * continuation is somehow still parked here, resume it before
                 * overwriting, or whoever is awaiting it waits forever. With
                 * the pump guard above this should never fire — but a silent
                 * hang is the worst way to find out it did. */
                if let stranded = playbackContinuation {
                    playbackContinuation = nil
                    currentPlayer?.stop()
                    stranded.resume()
                }
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
                } else {
                    isClipPlaying = true
                    isPaused = false
                    nowPlayingKey = key
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
    // MARK: - Per-user voice overrides
    //
    // Session 21g (Kade: the agent maker sets a voice, "but then the user can
    // change it once they get it"). Backed by the fork's per-user, per-agent
    // `GET/POST /api/kade/voice-prefs`, so a pick follows the account across
    // read-aloud, calls, and (pending) phone -- same store the web app uses.

    private func loadUserVoicePrefsIfNeeded() async {
        if userVoicePrefs != nil { return }
        struct PrefsResponse: Decodable { let prefs: [String: String]? }
        let req = client.request(path: "api/kade/voice-prefs", authorized: true)
        if let (data, http) = try? await client.send(req), http.statusCode == 200,
           let decoded = try? JSONDecoder().decode(PrefsResponse.self, from: data) {
            userVoicePrefs = decoded.prefs ?? [:]
        } else {
            userVoicePrefs = [:]   // don't hammer a failed load every reply
        }
    }

    /// The user's saved voice override for an agent, if any. Loads the prefs
    /// first if they haven't been fetched yet.
    func voiceOverride(forAgent agentId: String) async -> String? {
        await loadUserVoicePrefsIfNeeded()
        guard let v = userVoicePrefs?[agentId], !v.isEmpty else { return nil }
        return v
    }

    /// Save (empty clears) the user's own voice pick for an agent. Updates the
    /// local caches so the very next spoken reply uses it, no relaunch needed.
    func setUserVoiceOverride(agentId: String, voice: String?) async {
        await loadUserVoicePrefsIfNeeded()
        let v = (voice ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String? = v.isEmpty ? nil : v
        if userVoicePrefs?[agentId] == normalized { return }   // no change
        var req = client.request(path: "api/kade/voice-prefs", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["agentId": agentId, "voice": v])
        guard let (_, http) = try? await client.send(req), http.statusCode == 200 else { return }
        if userVoicePrefs == nil { userVoicePrefs = [:] }
        userVoicePrefs?[agentId] = normalized
        agentVoiceCache[agentId] = nil   // force a re-resolve with the new pick
    }

    private func resolveVoice(agentId: String?, agentName: String?) async -> (voice: String?, speed: Double?) {
        if let agentId, let cached = agentVoiceCache[agentId] {
            return cached
        }
        await loadUserVoicePrefsIfNeeded()

        var resolvedVoice: String?
        var resolvedSpeed: Double?

        if let agentId {
            // The user's OWN pick (Settings/in-conversation) wins over the
            // agent's builder default -- "my Kiana sounds like Voice 27."
            if let pref = userVoicePrefs?[agentId], !pref.isEmpty {
                resolvedVoice = pref
            }
            let req = client.request(path: "api/agents/\(agentId)", authorized: true)
            if let (data, http) = try? await client.send(req),
               http.statusCode == 200,
               let detail = try? JSONDecoder().decode(AgentTTSDetail.self, from: data) {
                if resolvedVoice == nil { resolvedVoice = detail.tts?.voiceId }
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
            self.isClipPlaying = false
            self.playbackContinuation?.resume()
            self.playbackContinuation = nil
        }
    }
}
