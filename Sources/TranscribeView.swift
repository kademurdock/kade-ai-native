import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Voice-memo transcriber — the native port of the `/transcribe` web page.
///
/// Kade's ask, session 15: "consider the transcriber app and similar apps
/// like that. They need to go native as well. As much accessible native as
/// possible." The web page works, but reaching it meant leaving the app
/// into a web view, and a web view is exactly where this app's careful
/// VoiceOver work stops applying — focus order, rotor headings, spoken
/// status and the Actions rotor are all whatever the page happens to give.
///
/// What it does, matching the page feature for feature:
/// - Press to record a take, press again to stop. Each take is transcribed
///   and APPENDED to what's already there, so a long thought can be
///   recorded in pieces without losing the earlier pieces.
/// - The transcript is editable text, not a read-only result.
/// - "Organize into notes" (bold title + bullets) and "Clean up text"
///   (smooth prose, nothing dropped) run it through the server's organizer,
///   with Undo that puts the previous version straight back.
/// - Copy and Share.
///
/// Accessibility notes that are load-bearing rather than decoration:
/// - The status line is a single `.updatesFrequently` element, the same job
///   the page's `aria-live` region does — it is how you find out a take
///   landed without hunting for it.
/// - Every state change that has no natural focus target announces itself
///   through `UIAccessibility.post`. Focus moves to the transcript only
///   when there is genuinely new text in it to read.
/// - Buttons that can't do anything yet are `disabled`, not hidden: a
///   control that appears and disappears under your fingers is much harder
///   to navigate by touch than one that is consistently there and says it
///   is dimmed.
///
/// Session 16 ("Can we do an app keyboard like wispr flow?"): researched
/// live before proposing anything, and it's genuinely not a small build --
/// iOS does not let a keyboard extension touch the microphone at all, so
/// EVERY voice keyboard (Wispr Flow's included, confirmed off their own
/// support docs) has to hop out to its full app to record, then hop back,
/// and as of iOS 26.4 that hop-back needs a manual swipe, not an automatic
/// one. Asked her which way to go rather than guess; she picked the light
/// option. `quickMode` is that: a way to LAND on this screen already
/// listening (Siri, a Home Screen Quick Action, or an Action Button --
/// `KadeAppShortcuts` makes this selectable as an Action Button target for
/// free, no extra code) and have the clean transcript land on the
/// clipboard the instant a take finishes, so the whole trip from "say
/// something" to "paste it" is: trigger, talk, tap Stop, switch apps,
/// paste. No keyboard extension, no App Group, no OS wall to fight.
struct TranscribeView: View {
    @EnvironmentObject private var voiceService: VoiceService
    @StateObject private var service: TranscribeService

    @State private var transcript = ""
    /// The version of the transcript from before the last organize run.
    /// `nil` means there is nothing to undo — organizing is the only thing
    /// that ever sets it, and using it clears it, so Undo can never walk
    /// back further than one step and surprise someone.
    @State private var undoBuffer: String?
    @State private var activeSheet: TranscribeSheet?
    @State private var errorMessage: String?
    @State private var showingFileImporter = false

    private enum Focus: Hashable { case status, transcript }
    @AccessibilityFocusState private var a11yFocus: Focus?

    /// `quickMode` is set only by the fast entry points (Siri "Quick
    /// dictate," the Quick Action, an Action Button) -- the plain
    /// "Transcribe a voice memo" home screen button always opens this at
    /// `false`, unchanged from session 15's behavior: manual start, no
    /// surprise clipboard writes while she's mid-way through building up a
    /// longer note to organize.
    let quickMode: Bool

    init(apiClient: KadeAPIClient, quickMode: Bool = false) {
        _service = StateObject(wrappedValue: TranscribeService(client: apiClient))
        self.quickMode = quickMode
    }

    private var isRecording: Bool { voiceService.isRecording }
    private var isBusy: Bool { service.isWorking || voiceService.isTranscribing }
    private var hasText: Bool { !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var introText: String {
        quickMode
            ? "Listening for a quick dictate. Say what you want, tap Stop when you're done, and it copies straight to your clipboard, ready to paste."
            : "Record a thought, or import an audio file someone sent you, and get it back as text you can edit, tidy up, and share."
    }

    /// Matches the web `/transcribe` page's own file input exactly:
    /// `accept="audio/*,video/mp4,.m4a,.mp3,.wav,.ogg,.opus,.aac,.amr,.flac"`
    /// (read off `kadeTranscribe.js`'s served HTML, not guessed). `.audio`
    /// covers `audio/*` for any properly-tagged audio file, and
    /// `.mpeg4Movie` covers `video/mp4` (a short video someone sends you —
    /// Deepgram reads the audio track out of the container fine). The
    /// per-extension lookups exist because several of these formats
    /// (ogg, opus, amr, flac) have no dedicated named `UTType` constant in
    /// the SDK; `UTType(filenameExtension:)` synthesizes a working dynamic
    /// type from the extension even when the system has no built-in one,
    /// which is what actually lets the picker recognize a `.opus` file
    /// someone AirDropped over rather than silently graying it out.
    private static let importTypes: [UTType] = {
        var types: [UTType] = [.audio, .mpeg4Movie]
        for ext in ["m4a", "mp3", "wav", "ogg", "opus", "aac", "amr", "flac"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(introText)
                    .font(.body)

                statusLine
                importButton
                recordButton
                transcriptEditor
                organizeButtons
                shareButtons
            }
            .padding()
        }
        .navigationTitle(quickMode ? "Quick Dictate" : "Transcribe")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Auto-start exactly once, and only in quick mode -- an
            // ordinary visit to Transcribe (the home screen button) never
            // starts recording on its own. Guarded against `isRecording`
            // so returning to an already-in-progress quick-dictate screen
            // (e.g. after a transient view reload) can't double-start.
            guard quickMode, !isRecording, !isBusy else { return }
            await toggleRecording()
        }
        // ONE sheet for this whole screen, behind one enum binding. Two
        // chained `.sheet` modifiers at the same level is genuinely
        // unreliable in SwiftUI — one can win and the other never present —
        // and this app has already been bitten by it once (build 121,
        // ConversationDetailView). See `DetailSheet` for the same pattern.
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .share(let item):
                ShareSheet(item: item)
            }
        }
        // A DIFFERENT presentation mechanism from `.sheet`/`.fullScreenCover`
        // (backed by `UIDocumentPickerViewController`, driven by its own
        // `isPresented` binding rather than an identifiable item) — doesn't
        // compete with `activeSheet` for the "one presentation per view"
        // rule the rest of this app follows, so it's safe alongside it.
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: Self.importTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .alert(
            "Transcribe",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
            presenting: errorMessage
        ) { _ in
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Pieces

    private var statusLine: some View {
        Text(statusText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Status. \(statusText)")
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityFocused($a11yFocus, equals: .status)
    }

    private var statusText: String {
        if isRecording { return "Recording. Press Stop when you're done." }
        if voiceService.isTranscribing { return "Transcribing…" }
        return service.statusMessage
    }

    /// "Choose an audio file" on the web page — a friend's long voice
    /// memo, something recorded in another app and saved to Files, an
    /// attachment saved out of Mail or Messages. `UIDocumentPickerViewController`
    /// under the hood (via `.fileImporter`), which already knows how to
    /// reach iCloud Drive and any third-party file provider (Google Drive,
    /// Dropbox, and so on) that's installed — this app doesn't have to know
    /// about any of them individually.
    private var importButton: some View {
        Button {
            showingFileImporter = true
        } label: {
            Label("Import audio file", systemImage: "square.and.arrow.down")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isBusy)
        .accessibilityHint("Pick a recording from Files or another app — up to about two hours long — and add its words to the transcript.")
    }

    private var recordButton: some View {
        Button {
            Task { await toggleRecording() }
        } label: {
            Label(
                isRecording ? "Stop recording" : "Start recording",
                systemImage: isRecording ? "stop.circle.fill" : "mic.circle.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(isRecording ? .red : .accentColor)
        .disabled(isBusy)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
        .accessibilityHint(
            isRecording
                ? "Stops recording and turns what you said into text."
                : "Records what you say. You can record as many takes as you like; each one is added on the end."
        )
        // Start and stop feel different by design — the same distinct
        // recording feedback the composer's mic button uses.
        .sensoryFeedback(.impact(weight: .medium), trigger: isRecording)
    }

    private var transcriptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transcript")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            TextEditor(text: $transcript)
                .frame(minHeight: 220)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                )
                .accessibilityLabel("Transcript")
                .accessibilityHint("Editable. Everything you record lands here.")
                .accessibilityFocused($a11yFocus, equals: .transcript)
            if !hasText {
                Text("Nothing recorded yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var organizeButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tidy it up")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Button {
                Task { await organize(.notes) }
            } label: {
                Label("Organize into notes", systemImage: "list.bullet")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!hasText || isBusy)
            .accessibilityHint("Rewrites what you said as a title and bullet points, without adding anything you didn't say.")

            Button {
                Task { await organize(.prose) }
            } label: {
                Label("Clean up text", systemImage: "text.alignleft")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!hasText || isBusy)
            .accessibilityHint("Fixes grammar and filler words and keeps everything you said, as paragraphs.")

            Button {
                undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(undoBuffer == nil)
            .accessibilityHint("Puts the transcript back the way it was before the last tidy-up.")
        }
    }

    private var shareButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                voiceService.enqueueSpeak(text: transcript, agentId: nil, agentName: nil)
            } label: {
                Label("Read transcript aloud", systemImage: "speaker.wave.2")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!hasText)
            .accessibilityHint("Speaks the current transcript back to you -- the quickest way to confirm it came out right without reading the screen.")

            Button {
                UIPasteboard.general.string = transcript
                UIAccessibility.post(notification: .announcement, argument: "Transcript copied.")
            } label: {
                Label("Copy transcript", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!hasText)

            Button {
                activeSheet = .share(ShareItem(text: transcript))
            } label: {
                Label("Share transcript", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!hasText)
            .accessibilityHint("Opens the share sheet, where you can send it or save it to Files.")

            Button(role: .destructive) {
                clearAll()
            } label: {
                Label("Clear transcript", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!hasText)
            .accessibilityHint("Deletes everything in the transcript and starts over.")
        }
    }

    // MARK: - Actions

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await importFile(url) }
        }
    }

    /// Reads the picked file into memory and uploads it. Handles the two
    /// things that are specific to "a file that isn't ours": the security-
    /// scoped bookmark the system hands back for anything outside this
    /// app's own sandbox (Files, iCloud Drive, another app's container) —
    /// skipping `startAccessingSecurityScopedResource()` doesn't crash, it
    /// just fails the subsequent read with a permission error, which is a
    /// much more confusing thing to debug from a bug report than from
    /// reading this comment — and a size check against the server's own
    /// cap so a doomed upload fails immediately instead of after a long,
    /// silent wait.
    private func importFile(_ url: URL) async {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }

        let name = url.lastPathComponent
        let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        let mimeType = resourceValues?.contentType?.preferredMIMEType
        if let size = resourceValues?.fileSize, Int64(size) > TranscribeService.maxUploadBytes {
            errorMessage = "\(name) is larger than 150 megabytes, which is more than this can transcribe. Try a shorter file."
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            errorMessage = "Couldn't read \(name). Try again."
            return
        }

        UIAccessibility.post(notification: .announcement, argument: "Uploading \(name).")
        do {
            let text = try await service.transcribeUploaded(data: data, mimeType: mimeType)
            append(text)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't transcribe that file. Try again."
        }
    }

    private func toggleRecording() async {
        if isRecording {
            guard let url = voiceService.stopRecording() else { return }
            UIAccessibility.post(notification: .announcement, argument: "Stopped. Transcribing.")
            do {
                let text = try await service.transcribe(fileURL: url)
                append(text)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn't transcribe that. Try again."
            }
        } else {
            service.resetStatus()
            let started = await voiceService.startRecording()
            if started {
                UIAccessibility.post(notification: .announcement, argument: "Recording.")
            } else {
                errorMessage = voiceService.recordError ?? "Couldn't start recording. Try again."
            }
        }
    }

    /// Appends a take rather than replacing, matching the web page ("appends
    /// takes"). A blank line between takes so the paragraph structure the
    /// organizer sees actually reflects where she stopped and started.
    private func append(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            UIAccessibility.post(notification: .announcement, argument: "No speech found in that take.")
            return
        }
        // A take that lands INVALIDATES the undo buffer: undo means "put
        // back the text from before the last tidy-up," and that text no
        // longer includes what was just recorded, so restoring it would
        // silently throw away a whole take. Better to lose the undo than
        // the recording.
        undoBuffer = nil
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transcript = trimmed
        } else {
            transcript += "\n\n" + trimmed
        }
        a11yFocus = .transcript

        // The whole point of quick mode: by the time she's done talking,
        // the clean text is already sitting on the clipboard. Re-copies
        // the FULL transcript (not just this take) after every completed
        // take, not only the first, so a second dictate in the same
        // session keeps the clipboard in sync with everything said so
        // far -- never a stale partial copy of just the earlier piece.
        if quickMode {
            UIPasteboard.general.string = transcript
            UIAccessibility.post(notification: .announcement, argument: "Transcript copied. Ready to paste.")
        }
    }

    private func organize(_ style: TranscribeService.OrganizeStyle) async {
        let before = transcript
        do {
            let result = try await service.organize(text: transcript, style: style)
            undoBuffer = before
            transcript = result
            a11yFocus = .transcript
            UIAccessibility.post(
                notification: .announcement,
                argument: style == .notes ? "Organized into notes." : "Text cleaned up."
            )
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't organize that. Try again."
        }
    }

    private func undo() {
        guard let previous = undoBuffer else { return }
        transcript = previous
        undoBuffer = nil
        service.resetStatus()
        a11yFocus = .transcript
        UIAccessibility.post(notification: .announcement, argument: "Undone.")
    }

    private func clearAll() {
        transcript = ""
        undoBuffer = nil
        service.resetStatus()
        a11yFocus = .status
        UIAccessibility.post(notification: .announcement, argument: "Transcript cleared.")
    }
}

/// Everything this screen can present modally, behind one binding — same
/// single-sheet rule as `DetailSheet`.
enum TranscribeSheet: Identifiable {
    case share(ShareItem)

    var id: String {
        switch self {
        case .share(let item): return "share-\(item.id.uuidString)"
        }
    }
}
