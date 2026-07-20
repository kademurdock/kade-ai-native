import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import UIKit

/// Photo, video, and document description — see `DescribeService`'s doc
/// comment for the server contract. This screen's job: get a photo, video,
/// or document into the app by whichever route makes sense (camera, photo
/// library, or Files) through one entry point, then present the result so
/// it's genuinely easy to use by ear, not just technically present.
///
/// Session 17 note on video specifically: `PhotosPickerItem.loadTransferable
/// (type: Data.self)` -- the path this file already used for photos -- is
/// documented as a fallback for video, not the reliable route; the
/// established, Apple/community-precedent pattern is a small custom
/// `Transferable` conforming type backed by `FileRepresentation`, which
/// copies the picked asset to a real file this app owns rather than trying
/// to pull the whole thing through as raw `Data` directly. See `PickedMovie`
/// below.
///
/// Accessibility notes specific to this screen, beyond the app-wide
/// conventions (status line as one `.updatesFrequently` element, entries as
/// one swipe each, focus moved deliberately rather than left to land
/// wherever):
/// - The three ways to add something (camera, photo library, Files) sit
///   behind ONE button and a `.confirmationDialog` rather than three
///   permanently visible buttons — mirrors the single native file input on
///   the web page, which iOS itself already turns into exactly this same
///   three-way choice for a sighted user tapping it in Safari. Fewer
///   controls to navigate past for the common case.
/// - `UIImagePickerController` (camera) and `PhotosPicker` (library) are
///   both Apple's own system UI and already VoiceOver-accessible without
///   this app doing anything extra — same trust placed in
///   `SFSafariViewController` elsewhere in this app.
/// - Description text is the main event once it arrives: focus moves
///   straight to it and Read Aloud is right there, because for this
///   screen specifically, hearing the description IS the point.
struct DescribeView: View {
    @EnvironmentObject private var voiceService: VoiceService
    @StateObject private var service: DescribeService

    @State private var showingSourceMenu = false
    @State private var showingCamera = false
    @State private var showingPhotosPicker = false
    @State private var showingFileImporter = false
    @State private var photoPickerItem: PhotosPickerItem?

    @State private var outcome: DescribeService.Outcome?
    @State private var savedReminderKeys: Set<String> = []
    @State private var activeSheet: DescribeSheet?
    @State private var errorMessage: String?

    private enum Focus: Hashable { case status, result }
    @AccessibilityFocusState private var a11yFocus: Focus?

    init(apiClient: KadeAPIClient) {
        _service = StateObject(wrappedValue: DescribeService(client: apiClient))
    }

    private var isBusy: Bool { service.isWorking }

    /// PDF, Word, and plain-text formats the server documents as supported
    /// for the file-import route specifically (photos already have their
    /// own dedicated camera/library buttons, so this list leans toward
    /// documents). Built the same way as `TranscribeView.importTypes`: a
    /// couple of named constants plus `UTType(filenameExtension:)` for
    /// formats (docx, rtf) with no guaranteed named constant in the SDK.
    private static let fileImportTypes: [UTType] = {
        // Session 17: widened to include video containers someone might
        // pick from Files rather than the Photos library (an AirDropped
        // clip saved into Files, a video pulled out of Messages) -- .movie
        // is the umbrella UTType (matches anything QuickTime/AVFoundation
        // recognizes as playable video), .mpeg4Movie/.quickTimeMovie are
        // named explicitly so the two most common containers are never
        // left to chance.
        var types: [UTType] = [.pdf, .plainText, .image, .movie, .mpeg4Movie, .quickTimeMovie]
        for ext in ["docx", "rtf", "md", "csv"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Get a photo, video, flyer, letter, or document described to you, or read back word for word.")
                    .font(.body)

                statusLine
                addButton

                if let outcome {
                    resultSection(outcome)
                } else if !isBusy {
                    Text("Nothing described yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("Describe")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Add a photo, video, or document", isPresented: $showingSourceMenu) {
            Button("Take a photo") { showingCamera = true }
            Button("Choose a photo or video") { showingPhotosPicker = true }
            Button("Choose a file") { showingFileImporter = true }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapturePicker(
                onImage: { data in Task { await upload(data: data, mimeType: "image/jpeg", fileName: "photo.jpg") } },
                onCancel: {}
            )
            .ignoresSafeArea()
        }
        // Session 17: widened from `.images` to also offer videos in the
        // SAME library picker, matching the confirmation dialog's "Choose a
        // photo or video" -- one control, one extra content kind, rather
        // than a second picker to navigate past.
        .photosPicker(isPresented: $showingPhotosPicker, selection: $photoPickerItem, matching: .any(of: [.images, .videos]))
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await loadPickedItem(newItem)
                photoPickerItem = nil
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: Self.fileImportTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileImportResult(result)
        }
        // ONE sheet for this screen, same rule as everywhere else in this
        // app: a second `.sheet` at this level risks one silently never
        // presenting.
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .share(let item):
                ShareSheet(item: item)
            }
        }
        .alert(
            "Describe",
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
        Text(service.statusMessage)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Status. \(service.statusMessage)")
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityFocused($a11yFocus, equals: .status)
    }

    private var addButton: some View {
        Button {
            showingSourceMenu = true
        } label: {
            Label("Add a photo, video, or document", systemImage: "plus.viewfinder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isBusy)
        .accessibilityHint("Take a photo, choose a photo or video from your library, or pick a file from Files.")
    }

    private func resultSection(_ outcome: DescribeService.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(outcome.result.description)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Description. \(outcome.result.description)")
            .accessibilityFocused($a11yFocus, equals: .result)

            HStack(spacing: 12) {
                Button {
                    voiceService.enqueueSpeak(text: outcome.result.description, agentId: nil, agentName: nil)
                } label: {
                    Label("Read aloud", systemImage: "speaker.wave.2")
                }
                .buttonStyle(.bordered)

                Button {
                    activeSheet = .share(ShareItem(text: outcome.result.description))
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }

            if let readText = outcome.result.readText, !readText.isEmpty {
                documentTextSection(readText)
            }

            if !outcome.result.dates.isEmpty {
                datesSection(outcome)
            }
        }
    }

    /// The verbatim extracted text, distinct from the spoken-friendly
    /// `description` above it — for a document, she may want the summary
    /// OR the exact wording (amounts, reference numbers, a name spelled a
    /// particular way), and those are genuinely different needs.
    private func documentTextSection(_ readText: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Document text")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(readText)
                .font(.body)
                .textSelection(.enabled)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Document text. \(readText)")

            Button {
                voiceService.enqueueSpeak(text: readText, agentId: nil, agentName: nil)
            } label: {
                Label("Read the document text aloud", systemImage: "speaker.wave.2")
            }
            .buttonStyle(.bordered)
        }
    }

    private func datesSection(_ outcome: DescribeService.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dates found")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(outcome.result.dates) { date in
                let saved = savedReminderKeys.contains(date.id)
                Button {
                    Task { await saveReminder(itemId: outcome.itemId, date: date) }
                } label: {
                    Label(
                        saved ? "Saved: \(date.label)" : "Save reminder: \(date.label)",
                        systemImage: saved ? "checkmark.circle.fill" : "calendar.badge.plus"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(saved || isBusy)
                .accessibilityLabel(saved ? "Saved. \(date.label), \(date.when) Central time." : "Save reminder. \(date.label), \(date.when) Central time.")
                .accessibilityHint(saved ? "Already saved to your reminders." : "Adds this to your Kade-AI reminders.")
            }
        }
    }

    // MARK: - Actions

    /// Single entry point from the library picker's `onChange` -- decides
    /// image vs. video from the item's OWN reported content types (no way
    /// to know which the person picked until this point, since `.any(of:
    /// [.images, .videos])` hands back one `PhotosPickerItem` either way)
    /// and calls the loader built for that kind. Keeps the two loaders
    /// genuinely separate rather than one function branching internally,
    /// because they don't share a `Transferable` type -- see
    /// `loadPickedVideo`'s doc comment for why video can't just reuse
    /// `loadPickedPhoto`'s `Data.self` approach.
    private func loadPickedItem(_ item: PhotosPickerItem) async {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            await loadPickedVideo(item)
        } else {
            await loadPickedPhoto(item)
        }
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        let contentType = item.supportedContentTypes.first
        let mimeType = contentType?.preferredMIMEType ?? "image/jpeg"
        let ext = contentType?.preferredFilenameExtension ?? "jpg"
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            errorMessage = "Couldn't load that photo. Try again."
            return
        }
        await upload(data: data, mimeType: mimeType, fileName: "photo.\(ext)")
    }

    /// `loadTransferable(type: Data.self)` -- what `loadPickedPhoto` above
    /// uses -- is documented as a fallback for video specifically, not the
    /// reliable path; video needs a real `Transferable` conformance backed
    /// by `FileRepresentation`, which is what `PickedMovie` (bottom of this
    /// file) provides. That import copies the asset to a temp file THIS APP
    /// created, which is why -- unlike `importFile` below, which never
    /// deletes a file it didn't create -- this one cleans up after itself.
    ///
    /// Checks size against `DescribeService.maxUploadBytes` (30MB, matches
    /// the server's real `MAX_MEDIA_BYTES`) BEFORE reading the file into
    /// memory, the same early-exit shape `TranscribeView.importFile` and
    /// this file's own `importFile` use -- a video is far more likely than
    /// a photo to actually hit that ceiling, so failing in under a second
    /// off the file's own size attribute matters more here than it ever did
    /// for a photo.
    private func loadPickedVideo(_ item: PhotosPickerItem) async {
        guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else {
            errorMessage = "Couldn't load that video. Try again."
            return
        }
        defer { try? FileManager.default.removeItem(at: movie.url) }

        if let size = (try? movie.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
           Int64(size) > DescribeService.maxUploadBytes {
            errorMessage = "That video is larger than 30 megabytes, which is more than this can describe. Try a shorter clip."
            return
        }

        let contentType = item.supportedContentTypes.first(where: { $0.conforms(to: .movie) }) ?? .movie
        let mimeType = contentType.preferredMIMEType ?? "video/mp4"
        let ext = contentType.preferredFilenameExtension ?? "mov"
        guard let data = try? Data(contentsOf: movie.url) else {
            errorMessage = "Couldn't read that video. Try again."
            return
        }
        await upload(data: data, mimeType: mimeType, fileName: "video.\(ext)")
    }

    private func handleFileImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await importFile(url) }
        }
    }

    private func importFile(_ url: URL) async {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }

        let name = url.lastPathComponent
        let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        let mimeType = resourceValues?.contentType?.preferredMIMEType
        // Session 17: this screen had NO size guard at all before now, for
        // any file picked here -- a document or a video. Matches
        // `TranscribeView.importFile`'s established shape: check the size
        // attribute before reading bytes, so an oversized pick fails fast
        // instead of after loading the whole thing into memory first.
        if let size = resourceValues?.fileSize, Int64(size) > DescribeService.maxUploadBytes {
            errorMessage = "\(name) is larger than 30 megabytes, which is more than this can describe. Try a smaller file."
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = "Couldn't read \(name). Try again."
            return
        }
        await upload(data: data, mimeType: mimeType ?? "application/octet-stream", fileName: name)
    }

    private func upload(data: Data, mimeType: String, fileName: String) async {
        outcome = nil
        savedReminderKeys.removeAll()
        UIAccessibility.post(notification: .announcement, argument: "Uploading.")
        do {
            let result = try await service.describe(data: data, mimeType: mimeType, fileName: fileName)
            outcome = result
            a11yFocus = .result
            UIAccessibility.post(notification: .announcement, argument: service.statusMessage)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't describe that. Try again."
        }
    }

    private func saveReminder(itemId: String, date: DescribeService.DateOffer) async {
        do {
            try await service.saveReminder(itemId: itemId, when: date.when, label: date.label)
            savedReminderKeys.insert(date.id)
            UIAccessibility.post(
                notification: .announcement,
                argument: "Reminder saved for \(date.label), \(date.when) Central time."
            )
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Couldn't save that reminder. Try again."
        }
    }
}

/// Everything this screen can present as a sheet, behind one binding —
/// same single-sheet rule as `DetailSheet`/`TranscribeSheet`.
enum DescribeSheet: Identifiable {
    case share(ShareItem)

    var id: String {
        switch self {
        case .share(let item): return "share-\(item.id.uuidString)"
        }
    }
}

/// A video picked via `PhotosPicker`, imported the way Apple/community
/// precedent actually recommends for video specifically (`Data.self` is a
/// documented fallback, not the reliable path -- see `loadPickedVideo`'s
/// doc comment). `FileRepresentation`'s `importing` closure hands back a
/// short-lived file the system owns; this copies it to a UUID-named file in
/// THIS app's own temporary directory (never `documentsDirectory` -- that's
/// for a user's own documents, not a scratch copy this screen deletes the
/// moment it's uploaded) so it survives long enough for `loadPickedVideo` to
/// read and upload it, then clean it up.
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("kade-describe-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

/// Camera capture for a single still photo. SwiftUI has no native "take a
/// photo" view (`PhotosPicker` is library-only), so this wraps
/// `UIImagePickerController` with `sourceType = .camera` — old, simple,
/// already-accessible system UI, the standard bridge for exactly this case
/// and lower-risk than driving `CameraCaptureController`'s live
/// `AVCaptureSession` (built for streaming frames during a call, not for
/// "take one photo and hand it back").
private struct CameraCapturePicker: UIViewControllerRepresentable {
    var onImage: (Data) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCapturePicker
        init(_ parent: CameraCapturePicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            picker.dismiss(animated: true)
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.9) else {
                parent.onCancel()
                return
            }
            parent.onImage(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            parent.onCancel()
        }
    }
}
