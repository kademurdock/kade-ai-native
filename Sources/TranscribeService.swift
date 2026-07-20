import Foundation

/// Voice-memo transcription — the native port of the `/transcribe` web page
/// (Kade, session 15: "consider the transcriber app and similar apps like
/// that. They need to go native as well. As much accessible native as
/// possible.").
///
/// Two server routes, both read straight off the fork's own
/// `api/server/routes/kadeTranscribe.js` rather than assumed — the standing
/// house rule after `DELETE /api/convos` turned out to nest its arguments
/// and answer 201:
///
///   POST /api/kade/transcribe          JWT. The audio is the RAW REQUEST
///                                      BODY (`express.raw({ type: () => true })`),
///                                      NOT multipart and NOT JSON — the
///                                      only route in this app that works
///                                      that way. Content-Type is passed
///                                      through to Deepgram when it starts
///                                      with "audio", otherwise the server
///                                      substitutes application/octet-stream,
///                                      so an honest audio/mp4 here is the
///                                      right thing to send.
///                                      -> 200 { transcript, seconds, model }
///                                      -> 400 { error } (including "No speech
///                                         was found in that audio", which is
///                                         a real, expected outcome worth
///                                         showing verbatim rather than
///                                         flattening into "failed")
///   POST /api/kade/transcribe/organize JWT, JSON { text, style } where style
///                                      is "notes" or "prose" (the server
///                                      coerces anything else to "notes").
///                                      -> 200 { text, style }
///                                      -> 400 { error }
///
/// Recording itself deliberately reuses `VoiceService.startRecording()` /
/// `stopRecording()` rather than standing up a second recorder: that path
/// already carries the mic-permission handling, the
/// `setAllowHapticsAndSystemSoundsDuringRecording` fix, and the AAC/m4a
/// settings the server's byte-sniffer is known to accept.
@MainActor
final class TranscribeService: ObservableObject {
    @Published private(set) var isWorking = false
    /// Plain-language description of what's happening right now, wired to an
    /// `aria-live`-equivalent on the screen (a `.updatesFrequently` element
    /// VoiceOver re-reads). Mirrors the web page's own status line.
    @Published private(set) var statusMessage = "Ready."

    private let client: KadeAPIClient

    init(client: KadeAPIClient) {
        self.client = client
    }

    struct TranscribeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct ServerError: Decodable { let error: String? }

    /// Uploads one recorded take and returns its transcript. Deletes the
    /// temp file either way — same contract as `VoiceService.transcribe`,
    /// for the same reason: there is nothing useful to retry from a stale
    /// recording, only from a fresh one.
    func transcribe(fileURL: URL) async throws -> String {
        isWorking = true
        statusMessage = "Transcribing…"
        defer { isWorking = false }

        let audio: Data
        do {
            audio = try Data(contentsOf: fileURL)
        } catch {
            statusMessage = "Ready."
            throw TranscribeError(message: "Couldn't read that recording. Try again.")
        }
        try? FileManager.default.removeItem(at: fileURL)

        guard !audio.isEmpty else {
            statusMessage = "Ready."
            throw TranscribeError(message: "That recording came out empty. Try again.")
        }

        var req = client.request(path: "api/kade/transcribe", method: "POST", authorized: true)
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        req.httpBody = audio

        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            let decoded = try? JSONDecoder().decode(ServerError.self, from: data)
            statusMessage = "Ready."
            throw TranscribeError(
                message: decoded?.error ?? "Couldn't transcribe that. Try again."
            )
        }

        struct Response: Decodable {
            let transcript: String
            let seconds: Int?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            statusMessage = "Ready."
            throw TranscribeError(message: "Couldn't read the transcript that came back. Try again.")
        }
        statusMessage = decoded.seconds.map { "Transcribed \($0) seconds." } ?? "Transcribed."
        return decoded.transcript
    }

    enum OrganizeStyle: String {
        case notes
        case prose
    }

    /// Runs the current transcript through the server's organizer. Returns
    /// the rewritten text; the caller is responsible for keeping the raw
    /// version around so Undo can put it back (see `TranscribeView`).
    func organize(text: String, style: OrganizeStyle) async throws -> String {
        isWorking = true
        statusMessage = style == .notes ? "Organizing into notes…" : "Cleaning up the text…"
        defer { isWorking = false }

        var req = client.request(path: "api/kade/transcribe/organize", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["text": text, "style": style.rawValue]
        )

        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            let decoded = try? JSONDecoder().decode(ServerError.self, from: data)
            statusMessage = "Ready."
            throw TranscribeError(message: decoded?.error ?? "Couldn't organize that. Try again.")
        }
        struct Response: Decodable { let text: String }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            statusMessage = "Ready."
            throw TranscribeError(message: "The organizer sent something unreadable back. Try again.")
        }
        statusMessage = style == .notes ? "Organized into notes." : "Text cleaned up."
        return decoded.text
    }

    func resetStatus() {
        statusMessage = "Ready."
    }
}
