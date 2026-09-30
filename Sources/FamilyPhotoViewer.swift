import SwiftUI
import UIKit

// MARK: - Family history: the photo viewer (Sep 29 2026)
//
// DESIGN 1.5, with her Sep 29 answers (ADDENDUM B, D): one picture at a
// time, full screen, presented (never pushed) from the screen that opened
// it. Close is top left and VoiceOver starts there; the escape gesture closes
// it too, and the opener hands focus back to the picture it came from.
// - The picture: FamilyZoomImage (pinch, double tap, a swipe when not zoomed
//   in). Past 2 times on a record or document scan the large copy loads
//   ("Sharper copy loading"). Neighbours are loaded ahead.
// - VoiceOver: the picture is ONE adjustable element: its label the alt
//   text (which says "Restored with AI" on a restored copy), its value "3 of
//   12". Swipe up or down changes the picture and says the new one; double
//   tap reads the whole description. The Previous, Next and zoom buttons are
//   for sight and Voice Control, hidden while VoiceOver runs.
// - The panel under it (solid under Reduce Transparency): the caption, the
//   Original/Restored switch when there is a restored copy (restored first,
//   with its label), the people as links, the date and place, the
//   Description ("Described automatically"), the words in the picture ("Read
//   automatically"), Do you know who this is?, and Ask for this photo to be
//   restored (into the owner's notes; nothing is restored on the phone).
// - Save to Photos and Share, for any family picture (her yes): the copy on
//   screen, a restored copy named so.
// - Play slideshow (FamilySlideshow.swift).

/// What the viewer opens: the pictures (as the screen shows them: a person's
/// page restored copies first), where to start, and how.
struct FamilyViewerRequest: Identifiable {
    let id = UUID()
    let items: [FHImage]
    var start: Int = 0
    /// Open straight into the slideshow (the gallery's Play slideshow).
    var slideshow: Bool = false
}

struct FamilyPhotoViewer: View {
    let request: FamilyViewerRequest

    @Environment(\.dismiss) private var dismiss
    @Environment(\.kadeNavigation) private var nav
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @KadeMotionPolicy private var motionAllowed: Bool
    @State private var index: Int
    @State private var zoom: CGFloat = 1
    /// Pictures whose other copy (restored or original) is on screen.
    @State private var swapped: Set<String> = []
    @State private var infos: [String: FHMediaInfo] = [:]
    @State private var loaded: FamilyViewerPicture?
    @State private var showDescription = false
    @State private var slideshow: Bool
    @State private var note: FamilyNoteRequest?
    @State private var share: ShareItem?
    @State private var said: String?
    @State private var busy = false
    @AccessibilityFocusState private var closeFocused: Bool

    init(request: FamilyViewerRequest) {
        self.request = request
        let start: Int = min(max(0, request.start), max(0, request.items.count - 1))
        _index = State(initialValue: start)
        _slideshow = State(initialValue: request.slideshow)
    }

    // MARK: What is on screen

    private var item: FHImage? {
        request.items.indices.contains(index) ? request.items[index] : nil
    }

    /// The copy on screen: the item, or its other copy after the switch
    /// (with that copy's own words once /media/:id/info has answered).
    private var shown: FHImage? {
        guard let item else { return nil }
        guard swapped.contains(item.id), let other = item.otherCopyImage() else { return item }
        return infos[other.id]?.image ?? other
    }

    private var info: FHMediaInfo? {
        guard let shown else { return nil }
        return infos[shown.id]
    }

    private var label: String {
        FamilyAccessRules.nonEmpty(shown?.label) ?? "A family picture"
    }

    private var position: String {
        "\(index + 1) of \(request.items.count)"
    }

    private var isScan: Bool {
        let kind: FHImageCategory = shown?.categoryKind ?? .other
        return kind == .record || kind == .document || kind == .story
    }

    /// Past 2 times on a scan: the large copy.
    private var wantSharper: Bool {
        zoom > 2 && isScan && (shown?.has(.l) ?? false)
    }

    private var pictureKey: String {
        "\(shown?.id ?? "")|\(wantSharper ? "l" : "s")"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if slideshow {
                FamilySlideshow(items: request.items, index: $index) {
                    if request.slideshow { dismiss() } else { slideshow = false }
                }
            } else if request.items.isEmpty {
                emptyViewer
            } else {
                viewer
            }
        }
        .accessibilityAction(.escape) { dismiss() }
        .sheet(item: $note) { asked in
            FamilyNoteSheet(request: asked)
        }
        .sheet(item: $share) { item in
            ShareSheet(item: item)
        }
        .task(id: pictureKey) { await loadPicture() }
        .task(id: shown?.id ?? "") { await prepare() }
    }

    private var emptyViewer: some View {
        VStack(spacing: 16) {
            closeButton
            Text("There is no picture to show.")
                .foregroundStyle(.white)
            Spacer()
        }
        .padding()
    }

    private var viewer: some View {
        VStack(spacing: 0) {
            topBar
            pictureArea
            moveButtons
            panel
        }
    }

    private var panel: some View {
        FamilyViewerPanel(image: shown, item: item, info: info, showDescription: $showDescription,
                          said: said, busy: busy,
                          onSwitch: { (restored: Bool) in setRestored(restored) },
                          onPerson: { (person: FHPerson) in openPerson(person) },
                          onWho: { askWho() },
                          onRestore: { Task { await askRestore() } })
    }

    // MARK: Top bar

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Label("Close", systemImage: "xmark")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .accessibilityFocused($closeFocused)
        .task {
            try? await Task.sleep(nanoseconds: 550_000_000)
            if Task.isCancelled { return }
            closeFocused = true
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            closeButton
            Spacer(minLength: 4)
            Text(position)
                .font(.subheadline)
                .foregroundStyle(.white)
                .accessibilityHidden(true)
            Spacer(minLength: 4)
            Menu {
                Button {
                    Task { await saveToPhotos() }
                } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                }
                Button {
                    Task { await shareShown() }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                if request.items.count > 1 {
                    Button {
                        startSlideshow()
                    } label: {
                        Label("Play slideshow", systemImage: "play.rectangle")
                    }
                }
            } label: {
                Label("Save and share", systemImage: "square.and.arrow.up")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Save, share or play")
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: The picture

    private var pictureArea: some View {
        let picture: UIImage? = loaded?.id == shown?.id ? loaded?.picture : nil
        return ZStack {
            FamilyZoomImage(picture: picture, identity: shown?.id ?? "", zoom: $zoom,
                            motionAllowed: motionAllowed) { step in move(step) }
            if picture == nil {
                FamilyPictureWords(words: label)
                    .frame(maxHeight: 260)
                    .padding()
            }
            if wantSharper && loaded?.sharp != true && picture != nil {
                VStack {
                    Spacer()
                    Text("Sharper copy loading")
                        .font(.footnote)
                        .padding(8)
                        .background(Capsule().fill(Color(.systemBackground)))
                        .padding(.bottom, 8)
                }
                .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(position)
        .accessibilityAddTraits(.isImage)
        .accessibilityHint("Swipe up or down for another picture. Double tap to hear its description.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(1)
            case .decrement: move(-1)
            @unknown default: break
            }
        }
        .accessibilityAction { readDescription() }
        .accessibilityIgnoresInvertColors(true)
    }

    /// Previous, Next and the zoom: for sight, Voice Control and Switch
    /// Control. VoiceOver has the adjustable picture instead.
    private var moveButtons: some View {
        HStack(spacing: 12) {
            Button { move(-1) } label: { Label("Previous", systemImage: "chevron.left") }
                .disabled(index <= 0)
            Spacer(minLength: 0)
            Button { setZoom(zoom / 2) } label: { Label("Zoom out", systemImage: "minus.magnifyingglass") }
                .labelStyle(.iconOnly)
                .disabled(zoom <= 1.01)
            Button { setZoom(zoom * 2) } label: { Label("Zoom in", systemImage: "plus.magnifyingglass") }
                .labelStyle(.iconOnly)
                .disabled(zoom >= FamilyZoomImage.maxZoom - 0.01)
            Spacer(minLength: 0)
            Button { move(1) } label: { Label("Next", systemImage: "chevron.right") }
                .disabled(index >= request.items.count - 1)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .accessibilityHidden(voiceOverOn)
    }

    // MARK: Moving and zooming

    private func move(_ step: Int) {
        let target: Int = index + step
        guard request.items.indices.contains(target) else { return }
        zoom = 1
        showDescription = false
        said = nil
        index = target
        if voiceOverOn {
            let next: FHImage = request.items[target]
            FamilyAnnounce.say(FamilyAccessRules.nonEmpty(next.label) ?? "A family picture")
        }
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(max(1, value), FamilyZoomImage.maxZoom)
    }

    private func readDescription() {
        showDescription = true
        let words: String = FamilyAccessRules.nonEmpty(info?.description) ?? FamilyAccessRules.nonEmpty(shown?.description)
            ?? "There is no description of this picture yet."
        FamilyAnnounce.say(words)
    }

    private func startSlideshow() {
        zoom = 1
        slideshow = true
    }

    // MARK: Original and restored

    /// Shows the restored copy (true) or the original (false).
    private func setRestored(_ restored: Bool) {
        guard let item, item.otherCopy != nil else { return }
        let itemIsRestored: Bool = item.isRestoredCopy
        if restored == itemIsRestored {
            swapped.remove(item.id)
        } else {
            swapped.insert(item.id)
        }
        zoom = 1
        let words: String = restored ? (FamilyAccessRules.nonEmpty(item.restoredLabel) ?? "Restored with AI") : "Original"
        FamilyAnnounce.say(words)
    }

    // MARK: People and notes

    private func openPerson(_ person: FHPerson) {
        let route = FamilyPersonRoute(id: person.id, name: person.shownName)
        let navigation = nav
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            navigation.pushLibrary(.family(.person(route)))
        }
    }

    private func askWho() {
        guard let shown else { return }
        note = FamilyNoteRequest(personId: nil, mediaId: shown.id, kind: "who", title: "Do you know who this is?",
                                 prompt: "Who is in this picture, or where was it taken?")
    }

    @MainActor
    private func askRestore() async {
        guard let shown, !busy else { return }
        busy = true
        let words: String = await FamilyRestoreAsk.send(mediaId: shown.id)
        busy = false
        said = words
        FamilyAnnounce.say(words)
    }

    // MARK: Save and share

    @MainActor
    private func saveToPhotos() async {
        guard let shown, !busy else { return }
        busy = true
        let file: URL? = await FamilyImageLoader.shared.shareFile(for: shown)
        guard let file, let picture = UIImage(contentsOfFile: file.path) else {
            busy = false
            report("Could not get this picture to save. Try again in a moment.")
            return
        }
        FamilyPhotoSaver.shared.save(picture) { (problem: Error?) in
            busy = false
            if problem == nil {
                Earcons.shared.play(.actionDone)
                report("Saved to Photos.")
            } else {
                report("Could not save to Photos. Photos may need permission in Settings, Kade-AI.")
            }
        }
    }

    @MainActor
    private func shareShown() async {
        guard let shown, !busy else { return }
        busy = true
        let file: URL? = await FamilyImageLoader.shared.shareFile(for: shown)
        busy = false
        guard let file else {
            report("Could not get this picture to share. Try again in a moment.")
            return
        }
        share = ShareItem(fileURL: file)
    }

    private func report(_ words: String) {
        said = words
        FamilyAnnounce.say(words)
    }

    // MARK: Loading

    @MainActor
    private func loadPicture() async {
        guard let shown, !shown.id.isEmpty else { return }
        let sharp: Bool = wantSharper
        let size: FHSize = sharp ? .l : shown.best(.s)
        let pixels: Int = sharp ? 4096 : 2048
        let picture: UIImage? = await FamilyImageLoader.shared.image(for: shown, size: size, pixels: pixels)
        if Task.isCancelled { return }
        if let picture {
            loaded = FamilyViewerPicture(id: shown.id, picture: picture, sharp: sharp)
        }
    }

    /// This picture's words (/media/:id/info), then its neighbours ahead.
    @MainActor
    private func prepare() async {
        if let shown, infos[shown.id] == nil {
            if let answer = try? await FamilyHistoryService.shared.mediaInfo(shown.id) {
                infos[shown.id] = answer
            }
        }
        for step in [1, -1] {
            let near: Int = index + step
            guard request.items.indices.contains(near) else { continue }
            if Task.isCancelled { return }
            let neighbour: FHImage = request.items[near]
            _ = await FamilyImageLoader.shared.image(for: neighbour, size: neighbour.best(.s), pixels: 2048)
        }
    }
}

/// The picture on screen, and whether it is the large copy.
struct FamilyViewerPicture {
    let id: String
    let picture: UIImage
    let sharp: Bool
}

// MARK: - Saving to Photos

/// UIImageWriteToSavedPhotosAlbum with an answer: add-only, so the app never
/// reads the photo library (NSPhotoLibraryAddUsageDescription).
final class FamilyPhotoSaver: NSObject {
    static let shared = FamilyPhotoSaver()
    private var done: ((Error?) -> Void)?

    @MainActor
    func save(_ picture: UIImage, done: @escaping (Error?) -> Void) {
        self.done = done
        UIImageWriteToSavedPhotosAlbum(picture, self, #selector(image(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    @objc private func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeMutableRawPointer?) {
        let finish = done
        done = nil
        DispatchQueue.main.async {
            finish?(error)
        }
    }
}
