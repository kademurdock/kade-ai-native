import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import UIKit

/// Photo and document description — see `DescribeService`'s doc comment for
/// the server contract. This screen's job: get a photo or document into
/// the app by whichever route makes sense (camera, photo library, or Files)
/// through one entry point, then present the result so it's genuinely easy
/// to use by ear, not just technically present.
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
        var types: [UTType] = [.pdf, .plainText, .image]
        for ext in ["docx", "rtf", "md", "csv"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Get a photo, flyer, letter, or document described to you, or read back word for word.")
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
        .confirmationDialog("Add a photo or document", isPresented: $showingSourceMenu) {
            Button("Take a photo") { showingCamera = true }
            Button("Choose a photo") { showingPhotosPicker = true }
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
        .photosPicker(isPresented: $showingPhotosPicker, selection: $photoPickerItem, matching: .images)
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await loadPickedPhoto(newItem)
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
            Label("Add a photo or document", systemImage: "plus.viewfinder")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isBusy)
        .accessibilityHint("Take a photo, choose one from your library, or pick a file from Files.")
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
        let mimeType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.preferredMIMEType
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
