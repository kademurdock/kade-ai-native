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
///
/// Session 16 adds file import (Kade: "add a button to upload a file to the
/// transcribe thing") — picking an existing recording from Files, iCloud
/// Drive, or another app's share destination, matching the web page's own
/// upload feature (`accept="audio/*,video/mp4,.m4a,.mp3,.wav,.ogg,.opus,
/// .aac,.amr,.flac"`, read straight off `kadeTranscribe.js`'s served HTML
/// rather than assumed). `transcribeUploaded(data:mimeType:)` is the
/// counterpart to `transcribe(fileURL:)` for that path — see its own doc
/// comment for the one deliberate way it differs from a recorded take.
@MainActor
final class TranscribeService: ObservableObject {
    @Published private(set) var isWorking = false
    /// Plain-language description of what's happening right now, wired to an
    /// `aria-live`-equivalent on the screen (a `.updatesFrequently` element
    /// VoiceOver re-reads). Mirrors the web page's own status line.
    @Published private(set) var statusMessage = "Ready."

    private let client: KadeAPIClient

    /// Mirrors `kadeTranscribe.js`'s own `MAX_UPLOAD = '150mb'`. Checked
    /// client-side before a big file is ever sent, so a doomed upload fails
    /// in under a second with a plain-language reason instead of after a
    /// long wait on someone's data plan.
    static let maxUploadBytes: Int64 = 150 * 1024 * 1024

    init(client: KadeAPIClient) {
        self.client = client
    }

    struct TranscribeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct ServerError: Decodable { let error: String? }
    private struct TranscribeResponse: Decodable { let transcript: String; let seconds: Int? }

    /// Uploads one recorded take and returns its transcript. Deletes the
    /// temp file either way — same contract as `VoiceService.transcribe`,
    /// for the same reason: there is nothing useful to retry from a stale
    /// recording, only from a fresh one. This file was CREATED by this app
    /// (`VoiceService.startRecording`'s temp `.m4a`), which is what makes
    /// deleting it the right call — contrast `transcribeUploaded`, which
    /// never deletes anything because it never created anything.
    func transcribe(fileURL: URL) async throws -> String {
        let audio: Data
        do {
            audio = try Data(contentsOf: fileURL)
        } catch {
            throw TranscribeError(message: "Couldn't read that recording. Try again.")
        }
        try? FileManager.default.removeItem(at: fileURL)

        guard !audio.isEmpty else {
            throw TranscribeError(message: "That recording came out empty. Try again.")
        }
        return try await upload(audio, contentType: "audio/mp4", startMessage: "Transcribing…")
    }

    /// Uploads an already-in-memory file picked from Files, iCloud Drive, or
    /// another app's share sheet, and returns its transcript.
    ///
    /// The one deliberate difference from the web page's own upload button:
    /// the page REPLACES whatever text was already on screen
    /// (`showResult(j, /* append */ false)` in `kadeTranscribe.js`'s served
    /// script), because the page has nothing else going on. This app's
    /// transcript can already hold earlier recorded takes or an organized
    /// rewrite by the time someone imports a file, and this app's whole
    /// design position — the Retry-button fix, the undo-clears-on-new-take
    /// rule, the captured-state pattern generally — is that nothing here
    /// silently throws away text she hasn't chosen to discard. So the
    /// caller (`TranscribeView.importFile`) appends this result through the
    /// exact same `append(_:)` a recorded take goes through, rather than
    /// overwriting. Deliberately never deletes the source file: unlike a
    /// recording this app made in its own temp directory, this file
    /// belongs to her (or whoever sent it to her) and lives somewhere this
    /// app doesn't own.
    func transcribeUploaded(data: Data, mimeType: String?) async throws -> String {
        guard !data.isEmpty else {
            throw TranscribeError(message: "That file came out empty. Try a different one.")
        }
        return try await upload(
            data,
            contentType: mimeType ?? "application/octet-stream",
            startMessage: "Uploading and transcribing…"
        )
    }

    /// Shared by both transcribe paths above — one place that builds the
    /// request, reads the response, and turns a non-200 into the server's
    /// own `{error}` text rather than a generic failure message.
    private func upload(_ body: Data, contentType: String, startMessage: String) async throws -> String {
        isWorking = true
        statusMessage = startMessage
        defer { isWorking = false }

        var req = client.request(path: "api/kade/transcribe", method: "POST", authorized: true)
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            let decoded = try? JSONDecoder().decode(ServerError.self, from: data)
            statusMessage = "Ready."
            throw TranscribeError(message: decoded?.error ?? "Couldn't transcribe that. Try again.")
        }
        guard let decoded = try? JSONDecoder().decode(TranscribeResponse.self, from: data) else {
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
