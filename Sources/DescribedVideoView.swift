import SwiftUI
import AVKit
import AVFoundation
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import UIKit

// MARK: - Make a described video (Sep 24 2026)
//
// The website's describer (kademurdock.com/described-video) on the phone:
// choose a video (Files, Photos, a YouTube link, or a Library video), choose
// the narration, hear the price, then watch, read, save or share the copy.
//
// SHAPE, top to bottom:
//   status   the ONE live region; every announcement is written here too.
//   choose   Files, Photos, YouTube, or the Library video she came from.
//   video    the open video: its stage, progress, time left, cost so far,
//            Cancel, Continue, Go back to version N, Rename, Delete.
//   narration + cost   (a checked video, or one that stopped) the voice, the
//            speeds, detail, pauses, volume, the two paid passes, notes, part
//            of the video; then the server's price on each spend button.
//   result   play, listen, read, save or share, versions, Describe the rest,
//            Try again on the parts that could not be described, Library.
//   videos   every video she has, one button each.
//
// NO LAZY CONTAINER on this screen: it changes state on a timer while
// VoiceOver may be reading it (the Part-87 freeze law). Every list is a plain
// VStack over a bounded set; the long voice and transcript lists live in
// sheets that change only at her hand (a voice starred in the voice sheet).

struct DescribedVideoView: View {
    let apiClient: KadeAPIClient
    let start: DescribedVideoStart

    @StateObject private var service: DescribedVideoService
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    /// Part 291: off by default. With VoiceOver on, the player keeps the
    /// system captions off (VoiceOver would read them over the film) and
    /// draws them itself for anyone watching with her.
    @AppStorage("kade.describedVideo.readCaptions") private var readCaptions = false

    // Opening
    @State private var config: DVConfig?
    @State private var loaded = false
    @State private var loading = false
    @State private var loadFailed = false
    @State private var refused = false
    @State private var statusLine = "Opening the video describer…"
    /// False once she has left (another tab, another screen): nothing is
    /// said, sounded or polled until the screen shows again.
    @State private var onScreen = false
    @State private var pendingFocus: DVPendingFocus?
    /// What would have been said while a sheet was up (the player, the
    /// transcript): said once the sheet closes, never over the film.
    @State private var heldAnnouncement: String?
    /// "Notes are empty and the extra passes are off", said with the next
    /// price when opening a new video cleared them.
    @State private var freshNote = ""
    @State private var retrying = false
    /// The narration as a newly opened video seeded it (see settingsChanged).
    @State private var seededSignature = ""

    // Your videos
    @State private var jobs: [DVJob] = []
    @State private var job: DVJob?

    // Choosing a video
    @State private var showFileImporter = false
    @State private var showPhotosPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var youtubeLink = ""
    @State private var pendingLibrary: DescribedVideoStart?
    /// The upload lives outside the screen (DescribedVideoUploads): a screen
    /// that replaced the one that started it still shows it and its Stop.
    @ObservedObject private var uploads = DescribedVideoUploads.shared
    /// Upload endings up to here happened before this screen was made.
    @State private var seenUploadEnding: Int
    @State private var uploadStep = -1
    @State private var uploadSpokenAt = Date.distantPast
    @State private var isBusy = false

    // Narration
    @State private var voice = ""
    @State private var rate = 1.5
    @State private var maxRate = 2.25
    @State private var mode = "extended"
    @State private var detail = "standard"
    @State private var volume = "balanced"
    @State private var closeLook = false
    @State private var firstLook = false
    @State private var notes = ""
    @State private var partOn = false
    @State private var partFrom = ""
    @State private var partTo = ""
    @State private var samplePlayer: AVAudioPlayer?
    @State private var sampling = false
    /// Her default narrator, favourites and recently used voices, kept on
    /// the server (Sep 25 2026) so the website and the phone agree.
    @State private var prefs = DVPrefs()
    @State private var savingPrefs = false
    /// The pending save of her speeds (see saveSpeedsSoon).
    @State private var speedSave: Task<Void, Never>?

    // Cost
    @State private var estimates: [String: DVEstimate] = [:]
    @State private var estimating = false
    @State private var estimateTask: Task<Void, Never>?
    @State private var estimateRound = 0

    // Progress
    @State private var pollTask: Task<Void, Never>?
    @State private var appActive = true
    @State private var spokenState = ""
    @State private var spokenStage = ""
    @State private var spokenProgress = -1.0
    @State private var spokenAt = Date.distantPast

    // Result
    @State private var viewVersion = 0
    @State private var files: DVFiles?
    @State private var filesKey = ""
    @State private var filesAt = Date.distantPast
    @State private var fetching = ""
    @State private var libraryFolder = ""
    @State private var libraryFolders: [String] = []
    @State private var shareWithFamily = true
    @State private var savingToLibrary = false
    /// The downloaded copy in the share sheet, deleted when the sheet closes
    /// (a film can be a gigabyte or two).
    @State private var sharedFile: URL?

    // Presentations: ONE sheet, one confirmation alert, and the rename alert
    // on a view of its own.
    @State private var activeSheet: DVSheet?
    @State private var confirm: DVConfirm?
    @State private var showRename = false
    @State private var renameText = ""
    /// The video the Rename alert was opened for.
    @State private var renameJobId = ""

    @AccessibilityFocusState private var focus: DVFocus?

    init(apiClient: KadeAPIClient, start: DescribedVideoStart = DescribedVideoStart()) {
        self.apiClient = apiClient
        self.start = start
        _service = StateObject(wrappedValue: DescribedVideoService(client: apiClient))
        _seenUploadEnding = State(initialValue: DescribedVideoUploads.shared.endingNumber)
    }

    // MARK: - Types

    fileprivate enum DVFocus: Hashable { case status, choose, library, jobHeading, voice, results, librarySave }

    fileprivate struct DVPendingFocus: Equatable {
        let text: String
        let target: DVFocus
    }

    fileprivate struct DVPlayerItem {
        let url: URL
        let title: String
        let isVideo: Bool
        /// The captions file's signed link (video only), for the captions
        /// the player draws itself while VoiceOver is on.
        let captions: URL?
    }

    fileprivate enum DVSheet: Identifiable {
        case voices
        case player(DVPlayerItem)
        case transcript(String, String)
        case share(ShareItem)

        var id: String {
            switch self {
            case .voices: return "voices"
            case .player(let item): return "player-\(item.url.absoluteString)"
            case .transcript(_, let title): return "transcript-\(title)"
            case .share(let item): return "share-\(item.id.uuidString)"
            }
        }
    }

    /// A question and the ONE video it is about: the open video can change
    /// while the alert is up (an upload ending opens its video).
    fileprivate struct DVConfirm: Identifiable {
        enum Kind { case start(preview: Bool), finish, resume, allowMore(Double), redo, cancel, delete, abandon }
        let kind: Kind
        let title: String
        let message: String
        let button: String
        let jobId: String
        var destructive = false
        var keep = "Not now"
        var id: String { "\(jobId)|\(title)" }
    }

    fileprivate struct DVOption: Identifiable {
        let value: String
        let label: String
        var id: String { value }
    }

    static let speeds: [Double] = [1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 3]
    private static let settingsKey = "kade.describedVideo.settings"

    fileprivate static let detailOptions: [DVOption] = [
        DVOption(value: "essential", label: "Essentials only: key actions, scene changes and on-screen text"),
        DVOption(value: "standard", label: "Standard: essentials plus people, places and expressions"),
        DVOption(value: "rich", label: "Rich detail: colors, clothing, logos and more, as room allows"),
    ]
    fileprivate static let modeOptions: [DVOption] = [
        DVOption(value: "extended", label: "Pause the picture and sound, describe, then carry on"),
        DVOption(value: "standard", label: "Keep the original length and leave that description out"),
    ]
    fileprivate static let volumeOptions: [DVOption] = [
        DVOption(value: "softer", label: "Softer: a little below the dialogue"),
        DVOption(value: "balanced", label: "Balanced: just above the dialogue"),
        DVOption(value: "louder", label: "Louder: well above it"),
    ]

    /// Video files Files can hand over. `.movie` covers what AVFoundation
    /// plays; the rest are containers the server's ffmpeg reads.
    private static let movieTypes: [UTType] = {
        var types: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie]
        for ext in ["mkv", "webm", "avi", "wmv", "flv", "3gp", "m4v", "mpg", "mpeg", "vob", "ts", "mts", "m2ts", "dv", "mxf"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }()

    // MARK: - Body

    var body: some View {
        uploadWatchers(watchers(lifecycle(presentations(page))))
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Part 292: the projection booth. Its words are the last thing
                // on this screen for VoiceOver, after Your videos.
                KadePaintedHeader(imageName: "ArtDescriberBooth", symbol: "film", tint: .teal, height: 120, described: true)
                Text("Keep the actors, music and sound. A narrator describes what happens on screen in the pauses. Then watch it here, save the video or the audio, or read it as a described transcript.")
                    .font(.body)
                statusBlock
                // Under the status whatever is open, so a screen that did not
                // start the upload still shows it and can stop it.
                if uploads.isRunning {
                    uploadProgressRow
                }
                if refused {
                    Text("Described video isn't available on this account.")
                        .font(.body)
                } else if config != nil {
                    mainContent
                } else if loadFailed {
                    // The button goes once the load works; VoiceOver is
                    // moved on (openStart) instead of being left nowhere.
                    Button("Try again") {
                        retrying = true
                        Task { await load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            // One container, so the booth's words (sorted last) never come
            // ahead of the intro, the status or any control.
            .accessibilityElement(children: .contain)
        }
        .navigationTitle("Described video")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var mainContent: some View {
        if let current = job {
            jobSection(current)
            if current.state == "ready" {
                narrationSection(voiceOnly: false)
                costSection(current)
            } else if current.resumable == true {
                narrationSection(voiceOnly: true)
                costSection(current)
            }
            if !current.finishedCopies.isEmpty {
                resultsSection(current)
            }
        } else {
            chooseSection
        }
        yourVideosSection
    }

    private func presentations<Content: View>(_ base: Content) -> some View {
        base
            .sheet(item: $activeSheet) { sheet in sheetView(sheet) }
            .alert(
                confirm?.title ?? "",
                isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                presenting: confirm
            ) { item in
                Button(item.button, role: item.destructive ? ButtonRole.destructive : nil) {
                    Task { await perform(item) }
                }
                Button(item.keep, role: .cancel) {}
            } message: { item in
                Text(item.message)
            }
            .background {
                Color.clear
                    .alert("Rename this video", isPresented: $showRename) {
                        TextField("Name", text: $renameText)
                        Button("Save") { Task { await rename() } }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("The new name is used for the downloads and the Library.")
                    }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: Self.movieTypes,
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            // `.current` hands over the video as it is stored, so a long
            // phone video is not transcoded on the phone before it uploads.
            .photosPicker(isPresented: $showPhotosPicker, selection: $photoItem, matching: .videos, preferredItemEncoding: .current)
    }

    private func lifecycle<Content: View>(_ base: Content) -> some View {
        base
            .onAppear {
                onScreen = true
                releaseHeldAnnouncement()
                fillCopiedYouTubeLink()
            }
            // Coming back refreshes the video, which starts polling again.
            .task { await load() }
            .onDisappear {
                onScreen = false
                stopPolling()
                estimateTask?.cancel()
                samplePlayer?.stop()
                removeSharedFile()
            }
            .onChange(of: scenePhase) { _, phase in
                appActive = phase == .active
                if phase == .active, onScreen, let current = job, current.needsWatching {
                    Task { await refreshJob(current.id) }
                }
                if phase == .active, onScreen { fillCopiedYouTubeLink() }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    await loadPicked(item)
                    photoItem = nil
                }
            }
            /* An announcement is heard in full, THEN VoiceOver moves (the
             * Sound Booth's rule): moving focus on top of it would cut it off. */
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.announcementDidFinishNotification)) { note in
                // A high-priority announcement is posted as attributed text;
                // its finish may name it either way.
                let value = note.userInfo?[UIAccessibility.announcementStringValueUserInfoKey]
                let spoken = (value as? String) ?? (value as? NSAttributedString)?.string
                guard onScreen, let waiting = pendingFocus, spoken == waiting.text else { return }
                pendingFocus = nil
                if activeSheet == nil { focus = waiting.target }
            }
            .onChange(of: activeSheet?.id) { old, id in
                if id == nil { releaseHeldAnnouncement() }
                // The share sheet has closed: its downloaded copy goes.
                if let old, old.hasPrefix("share-"), old != id { removeSharedFile() }
            }
    }

    /// The upload's bar and ending, whichever screen started it.
    private func uploadWatchers<Content: View>(_ base: Content) -> some View {
        base
            .onChange(of: uploads.progress) { _, value in
                if let value { uploadMoved(value) }
            }
            .onChange(of: uploads.endingNumber) { _, _ in
                takeUploadEnding()
            }
    }

    /// The settings' own rules, kept apart from `lifecycle` so neither chain
    /// is long enough to slow the type-checker.
    private func watchers<Content: View>(_ base: Content) -> some View {
        base
            .onChange(of: settingsSignature) { _, _ in settingsChanged() }
            .onChange(of: viewVersion) { _, _ in files = nil }
            .onChange(of: notes) { _, value in
                if value.count > 600 { notes = String(value.prefix(600)) }
            }
            .onChange(of: rate) { _, value in
                if maxRate < value { maxRate = value }
            }
            .onChange(of: maxRate) { _, value in
                if value < rate { rate = value }
            }
            .onChange(of: partOn) { _, on in
                if on { fillPartDefaults() }
            }
    }

    @ViewBuilder
    private func sheetView(_ sheet: DVSheet) -> some View {
        switch sheet {
        case .voices:
            voiceSheet
        case .player(let item):
            DescribedVideoPlayerSheet(url: item.url, title: item.title, isVideo: item.isVideo, captionsURL: item.captions,
                                      playbackRate: rememberedPlaybackRate, onPlaybackRate: { value in keepPlaybackRate(value) })
        case .transcript(let text, let title):
            DescribedTranscriptSheet(text: text, title: title)
        case .share(let item):
            ShareSheet(item: item)
        }
    }

    // MARK: - Status

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusLine)
                .font(.subheadline)
            if isBusy || loading || uploads.progress != nil {
                ProgressView().accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        /* ONE live region. The price, the stage, every error and every
         * confirmation speak through this single line. */
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status. \(statusLine)")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityFocused($focus, equals: .status)
    }

    // MARK: - Choose a video

    private var choosingDisabled: Bool {
        uploads.isRunning || isBusy || config?.enabled == false
    }

    private var chooseSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a video")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focus, equals: .choose)
            if let pending = pendingLibrary {
                libraryChoice(pending)
            }
            chooseButtons
            youtubeRow
            Text(limitsSentence)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Checking a video is free. Paid processing starts only when you choose to describe it, and the price is said first.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func libraryChoice(_ pending: DescribedVideoStart) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The video you chose in the Library is ready to check.")
                .font(.subheadline)
            Button {
                Task { await importLibrary(pending) }
            } label: {
                Label("Check this Library video", systemImage: "books.vertical")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(KadeCardButtonStyle())
            .disabled(choosingDisabled)
            .accessibilityHint("Checks the video for free. Nothing is uploaded again.")
            .accessibilityFocused($focus, equals: .library)
        }
    }

    private var chooseButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showFileImporter = true
            } label: {
                Label("Choose a video from Files", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(KadeCardButtonStyle())
            .disabled(choosingDisabled)
            .accessibilityHint("Opens Files. The video is uploaded and checked for free. If an upload stopped, choose the same video to carry on where it stopped.")

            Button {
                showPhotosPicker = true
            } label: {
                Label("Choose a video from Photos", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(KadeCardButtonStyle())
            .disabled(choosingDisabled)
            .accessibilityHint("Opens your photo library's videos. The video is uploaded and checked for free.")
        }
    }

    private var uploadProgressRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: min(1, max(0, uploads.progress ?? 0)), total: 1)
                .accessibilityLabel("Upload progress")
                .accessibilityValue("\(Int(((uploads.progress ?? 0) * 100).rounded())) percent")
            Button("Stop the upload") { uploads.stop() }
                .buttonStyle(.bordered)
                .accessibilityHint("Choosing the same video again later carries on from where it stopped.")
        }
    }

    /// Part 293: the reason the link import is greyed out (no Family feature
    /// pack), or nil when it can be used.
    private var linkLock: String? { config?.linkImportLock }

    /// Part 293: without the Family feature pack the same row is drawn greyed
    /// out, never hidden: the box and the button are disabled, VoiceOver's
    /// hint on each says why, and the reason shows as text beneath them.
    private var youtubeRow: some View {
        let lock = linkLock
        let fieldHint: String = lock ?? "One finished video, not a channel or playlist."
        let buttonHint: String = lock ?? "Checks the video for free. If YouTube refuses the server, save the video and choose it from Files instead."
        return VStack(alignment: .leading, spacing: 6) {
            Text("Or a YouTube link")
                .font(.subheadline)
                .accessibilityHidden(true)
            TextField("YouTube video link", text: $youtubeLink)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(lock != nil)
                .accessibilityLabel("YouTube video link")
                .accessibilityHint(fieldHint)
            Button("Import from YouTube") { Task { await importYouTube() } }
                .buttonStyle(.bordered)
                .disabled(choosingDisabled || lock != nil || youtubeLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityHint(buttonHint)
            if let lock {
                Text(lock)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private var limitsSentence: String {
        guard let c = config else { return "" }
        var words = "Videos up to \(Self.bytesWords(c.maxBytes ?? 2_147_483_648))"
        if let longest = c.maxSourceMinutes, longest > 0 {
            words += " and \(Self.lengthWords(longest * 60)) long"
        }
        words += "."
        if let run = c.maxMinutes, run > 0 {
            words += " One run describes up to \(Self.lengthWords(run * 60)); for a longer video, describe it in parts."
        }
        return words + " Your video stays private to your account."
    }

    // MARK: - The open video

    private func jobSection(_ current: DVJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(current.title)
                .font(.title3.bold())
                .accessibilityLabel("\(current.title), \(current.stateWord)")
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focus, equals: .jobHeading)
            Text(jobFacts(current))
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            if current.state == "running" {
                ProgressView(value: min(100, max(0, current.progress ?? 0)), total: 100)
                    .accessibilityLabel("Progress")
                    .accessibilityValue("\(Int((current.progress ?? 0).rounded())) percent")
            }
            if current.state == "uploading" {
                Text("The upload did not finish. Choose the same video again from Files or Photos to carry on where it stopped.")
                    .font(.footnote)
                chooseButtons
            }
            jobButtons(current)
        }
    }

    private func jobButtons(_ current: DVJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if current.isWorking {
                Button(current.cancelStuck == true ? "Cancel again" : "Cancel processing") {
                    confirm = cancelConfirm(current)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy || (current.cancelRequested == true && current.cancelStuck != true))
                .accessibilityHint("Asks first. Finished sections are kept, so you can continue later.")
            }
            if current.canRecheck {
                Button("Check again") {
                    Task { await recheck(current) }
                }
                .buttonStyle(KadeCardButtonStyle())
                .disabled(isBusy)
                .accessibilityHint("The check was interrupted before it finished. Checking again is free.")
            }
            if current.abandonable == true, let last = current.finishedCopies.last {
                Button("Go back to version \(last.number)") {
                    confirm = abandonConfirm(current, version: last.number)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
                .accessibilityHint("Sets the stopped remake aside, and version \(last.number) is the current copy again.")
            }
            // Not while an upload runs: when it ends, its video opens here.
            Button("Rename") {
                renameText = current.title
                renameJobId = current.id
                showRename = true
            }
            .buttonStyle(.bordered)
            .disabled(isBusy || uploads.isRunning)
            if ["ready", "uploading", "done", "failed", "cancelled", "deleting"].contains(current.state) {
                Button(current.state == "deleting" ? "Finish deleting" : "Delete this video and its files", role: .destructive) {
                    confirm = deleteConfirm(current)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy || uploads.isRunning)
                .accessibilityHint("Asks first. This cannot be undone.")
            }
            Button("Choose another video") { closeJob() }
                .buttonStyle(.bordered)
                .disabled(uploads.isRunning)
                .accessibilityHint("This video stays in Your videos below.")
        }
    }

    private func jobFacts(_ current: DVJob) -> String {
        var parts: [String] = []
        if current.state == "failed" {
            if current.overQuote == true {
                // The numbers are under Cost, beside the button that uses
                // them, when it can carry on.
                parts.append(current.resumable == true ? "Stopped because it is costing more than quoted." : overQuoteSentence(current))
            } else if current.recheckable == true {
                parts.append("The check was interrupted before it finished. Checking again is free.")
            } else {
                parts.append("Stopped before finishing.")
            }
        } else {
            parts.append(stageSentence(current))
        }
        if let seconds = current.seconds, seconds > 0 {
            parts.append("Video length: \(Self.lengthWords(seconds)).")
        }
        if let part = current.range {
            parts.append("Describing \(Self.clock(part.start)) to \(Self.clock(part.end)).")
        }
        if current.isWorking, let eta = current.etaSeconds, eta > 0 {
            parts.append("About \(Self.lengthWords(max(60, (eta / 60).rounded() * 60))) left.")
        }
        if current.isWorking, let cost = current.runCostUSD ?? current.costUSD, cost > 0 {
            var line = "Cost so far: \(Self.money(cost))"
            if let estimated = current.estimatedUSD, estimated > 0 {
                line += " of about \(Self.money(estimated))"
            }
            parts.append(line + ". Work already sent to a service may still be charged if you cancel.")
        } else if !current.isWorking, let total = current.costUSD, total > 0 {
            parts.append("Processing cost: \(Self.money(total)).")
        }
        // An over-quote stop's own message repeats the numbers just said.
        if !current.isWorking, current.overQuote != true, let error = current.error, !error.isEmpty {
            parts.append(Self.sentence(error))
        }
        if current.cancelStuck == true {
            parts.append("Still stopping. Press Cancel again if it does not stop.")
        }
        if current.sourceGrownUps == true {
            parts.append("The original is marked grown-ups only.")
        }
        return parts.joined(separator: " ")
    }

    private func stageSentence(_ current: DVJob) -> String {
        let stage = (current.stage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch current.state {
        case "running":
            let percent = Int((current.progress ?? 0).rounded())
            return stage.isEmpty ? "Describing, \(percent) percent." : "\(Self.sentence(stage)) \(percent) percent."
        case "reserving", "queued":
            return "Waiting for its turn." + queueWords(current)
        default:
            return stage.isEmpty ? "\(current.title): \(current.stateWord)." : Self.sentence(stage)
        }
    }

    /// What is said when a run or a check stops.
    private func failedSentence(_ fresh: DVJob) -> String {
        if fresh.overQuote == true {
            let words = overQuoteSentence(fresh)
            return fresh.resumable == true
                ? words + " To let it carry on, choose Allow more and continue; it asks before spending."
                : words
        }
        if fresh.recheckable == true {
            return "The check was interrupted before it finished. Choose Check again; checking is free."
        }
        return "Stopped before finishing. " + Self.sentence(fresh.error ?? "")
    }

    private func queueWords(_ current: DVJob) -> String {
        guard let ahead = current.queuePosition, ahead.isFinite, ahead < 100_000 else { return "" }
        let count = Int(ahead)
        if count <= 0 { return " Next in line." }
        return count == 1 ? " 1 video ahead of this one." : " \(count) videos ahead of this one."
    }

    // MARK: - Narration

    private func narrationSection(voiceOnly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Narration")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            if voiceOnly {
                Text("Carrying on keeps the detail, notes and inspection choices it started with. The voice, speeds, pauses and volume can change.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            voiceRow
            speedRow("Usual narration speed", hint: "Only the narrator speeds up. Dialogue keeps its own pace, and the voice keeps its pitch. Remembered for your account.", selection: usualSpeedChoice)
            speedRow("Fastest it may go to fit a gap", hint: "Used only when a description would not fit at the usual speed. Remembered for your account.", selection: fastestSpeedChoice)
            if !voiceOnly {
                choiceRow("How much to describe", hint: "Rich detail suits commercials, logos and VHS openings. Essentials suit dialogue-heavy shows.", options: Self.detailOptions, selection: $detail)
            }
            choiceRow("When a description cannot fit between lines", hint: "Pausing makes the copy a little longer. Minor details are left out rather than pausing for them.", options: Self.modeOptions, selection: $mode)
            choiceRow("Narrator volume", hint: "How loud the narrator is next to the dialogue.", options: Self.volumeOptions, selection: $volume)
            if !voiceOnly {
                extrasRows
                notesRow
                partRows
            }
        }
    }

    private var voiceRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            voiceButton
            Text(voiceDescription(voice))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // Said in the voice button's hint, so it adds no VoiceOver stop.
            if !voiceNote(voice).isEmpty {
                Text(voiceNote(voice))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            if offersMakeDefault {
                makeDefaultButton
            }
            Button {
                Task { await playSample() }
            } label: {
                Label(sampling ? "Making a sample…" : "Play a sample of this voice", systemImage: "play.circle")
            }
            .buttonStyle(.bordered)
            .disabled(sampling || voice.isEmpty)
            .accessibilityHint("Plays a few seconds of this narrator at your usual speed. Narration samples are included.")
            if config?.voicesAvailable == false {
                Text("The voice list could not be loaded just now. Playback and downloads still work; open this screen again later to change the voice.")
                    .font(.footnote)
            }
        }
    }

    private func voiceDescription(_ name: String) -> String {
        let about = (config?.describe?[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return about.isEmpty ? "One of your platform voices." : Self.sentence(about)
    }

    private var voiceButton: some View {
        Button {
            activeSheet = .voices
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Narrator voice")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Self.voiceName(voice))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(KadeCardButtonStyle())
        .disabled((config?.voices ?? []).isEmpty)
        .accessibilityLabel("Narrator voice")
        .accessibilityValue(Self.voiceName(voice))
        .accessibilityHint(voiceHint)
        .accessibilityFocused($focus, equals: .voice)
        .accessibilityActions {
            if offersMakeDefault {
                Button("Use this voice for new videos") {
                    Task { await makeDefault(voice) }
                }
            }
        }
    }

    /// The voice's description, what it is to her, then what a double tap does.
    private var voiceHint: String {
        let note = voiceNote(voice)
        let about = note.isEmpty ? voiceDescription(voice) : voiceDescription(voice) + " " + note
        return about + " Double tap to choose another voice."
    }

    /// For sight and Voice Control. VoiceOver has the same action in the
    /// voice button's Actions rotor, so this adds no stop there.
    private var makeDefaultButton: some View {
        Button {
            Task { await makeDefault(voice) }
        } label: {
            Label("Use this voice for new videos", systemImage: "checkmark.seal")
        }
        .buttonStyle(.bordered)
        .disabled(savingPrefs)
        .accessibilityHidden(voiceOverOn)
    }

    /// Servers from Sep 25 2026 keep her narrator choices; older ones send none.
    private var prefsOnServer: Bool {
        config?.favorites != nil
    }

    /// The narrator on screen is a listed voice her new videos do not start with yet.
    private var offersMakeDefault: Bool {
        guard prefsOnServer, !voice.isEmpty, voice != prefs.myDefaultVoice else { return false }
        return (config?.voices ?? []).contains(voice)
    }

    /// What the narrator is to her, in the website's words: her default, or
    /// the describer's own narrator until she chooses one; then the Fish note
    /// when the voice speaks through Fish. Empty when none applies.
    private func voiceNote(_ name: String) -> String {
        guard !name.isEmpty else { return "" }
        var notes: [String] = []
        if name == prefs.myDefaultVoice {
            notes.append("Your new videos start with this voice.")
        } else if prefs.myDefaultVoice == nil, name == prefs.houseVoice {
            notes.append("The describer's own narrator, used until you choose a default.")
        }
        if let fishNote = config?.fishNote, !fishNote.isEmpty, (config?.fish ?? []).contains(name) {
            notes.append(fishNote)
        }
        return notes.joined(separator: " ")
    }

    /// The website's marks after a voice's name in the picker's wheel and search list.
    private func voiceMark(_ name: String) -> String? {
        var marks: [String] = []
        if name == prefs.myDefaultVoice {
            marks.append("your default")
        } else if prefs.myDefaultVoice == nil, name == prefs.houseVoice {
            marks.append("used until you choose a default")
        }
        if prefs.favorites.contains(name) { marks.append("favourite") }
        return marks.isEmpty ? nil : marks.joined(separator: ", ")
    }

    // MARK: - The voice sheet

    /// What each voice reads in the picker: lines of description, like the
    /// website's samples, so a narrator is heard doing the job.
    static let auditionLines = [
        "A woman in a yellow raincoat hurries across the wet street, glances back once, and ducks into a small bookshop.",
        "Text on screen: Channel 27 News at Ten. A man in a gray suit straightens his papers.",
        "The camera pulls back from the scoreboard. The crowd is on its feet, waving orange towels.",
    ]

    /// The shared voice picker (the agent builder's wheels and search) with
    /// her narrator shelves, the Fish note, and favourite and default
    /// actions. Auditions play at her usual speed, up to 1.5×, and Steady.
    private var voiceSheet: some View {
        VoicePickerView(
            apiClient: apiClient,
            selection: $voice,
            agentLines: Self.auditionLines,
            voiceList: config?.voices,
            shelves: narratorShelves,
            previewSpeed: rate,
            previewDelivery: "STABLE",
            noteFor: { (name: String) -> String? in voiceNote(name) },
            markFor: { (name: String) -> String? in voiceMark(name) },
            favorites: Set(prefs.favorites),
            onToggleFavorite: favoriteAction,
            defaultVoice: prefs.myDefaultVoice,
            onMakeDefault: defaultAction
        )
    }

    /// Shown before the four groups; an empty one is left out.
    private var narratorShelves: [VoicePickerView.Shelf] {
        let all = [
            VoicePickerView.Shelf(name: "My favourites", voices: prefs.favorites),
            VoicePickerView.Shelf(name: "Recently used", voices: prefs.recent),
            VoicePickerView.Shelf(name: "Good for describing", voices: config?.suggested ?? []),
        ]
        return all.filter { !$0.voices.isEmpty }
    }

    private var favoriteAction: ((String) async -> Void)? {
        guard prefsOnServer else { return nil }
        return { name in await toggleFavorite(name) }
    }

    private var defaultAction: ((String) async -> Void)? {
        guard prefsOnServer else { return nil }
        return { name in await makeDefault(name) }
    }

    /// "Use this voice for new videos" here, "Make default" in the picker.
    /// Saved on the server, so the website starts new videos with it too.
    private func makeDefault(_ name: String) async {
        guard !name.isEmpty, !savingPrefs else { return }
        savingPrefs = true
        defer { savingPrefs = false }
        do {
            prefs = try await service.setDefaultVoice(name)
            sayVoiceNews("New videos will start with \(Self.voiceName(name)). You can still change the voice for any one video.")
        } catch {
            voiceChoiceFailed(error, "Couldn't save your default narrator. Try again.")
        }
    }

    private func toggleFavorite(_ name: String) async {
        guard !name.isEmpty, !savingPrefs else { return }
        let adding = !prefs.favorites.contains(name)
        savingPrefs = true
        defer { savingPrefs = false }
        do {
            prefs = try await service.setFavorite(name, on: adding)
            let change = adding ? "added to" : "removed from"
            sayVoiceNews("\(Self.voiceName(name)) \(change) My favourites.")
        } catch {
            voiceChoiceFailed(error, "Couldn't change your favourite narrators. Try again.")
        }
    }

    /// Said at once, also while the voice sheet is up: that sheet is hers to
    /// hear, not a film, so nothing is held for later. Anywhere else it is a
    /// confirmation through the live region, as usual.
    private func sayVoiceNews(_ text: String) {
        guard activeSheet != nil else {
            confirmAloud(text)
            return
        }
        statusLine = text
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// A narrator choice that did not save: the screen's error sound, and the
    /// server's own words ("You can keep up to 12 favourite narrators. Remove
    /// one first."), said at once while the voice sheet is up.
    private func voiceChoiceFailed(_ error: Error, _ fallback: String) {
        guard activeSheet != nil else {
            fail(error, fallback)
            return
        }
        if error is CancellationError { return }
        sound(.error)
        buzz(success: false)
        sayVoiceNews(Self.message(error, fallback))
    }

    private func speedRow(_ title: String, hint: String, selection: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .accessibilityHidden(true)
            Picker(title, selection: selection) {
                ForEach(Self.speeds, id: \.self) { value in
                    Text(Self.speedLabel(value)).tag(value)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(title)
            .accessibilityHint(hint)
            Text(hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choiceRow(_ title: String, hint: String, options: [DVOption], selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .accessibilityHidden(true)
            Picker(title, selection: selection) {
                ForEach(options) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(title)
            .accessibilityHint(hint)
            Text(hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var extrasRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            toggleRow("Take a closer look at fast scenes, text and logos", isOn: $closeLook, hint: extraHint(
                "Inspects a slower, larger copy. The finished video keeps its normal pace. Costs more and takes longer.",
                perMinute: config?.extrasPerMinuteUSD?.closeLook
            ))
            toggleRow("Look through the whole film first to learn who is who", isOn: $firstLook, hint: extraHint(
                "An extra pass for consistent names and appearances. People are still named only when the film reveals their names; famous cartoon, puppet and game characters are named when they appear. Adds time and cost.",
                perMinute: config?.extrasPerMinuteUSD?.firstLook
            ))
        }
    }

    private func extraHint(_ words: String, perMinute: Double?) -> String {
        guard let perMinute, perMinute > 0 else { return words }
        return words + " About \(Self.money(perMinute)) a minute more."
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
                .accessibilityHint(hint)
            Text(hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var notesRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes for the describer (optional)")
                .font(.subheadline)
                .accessibilityHidden(true)
            TextField("What the video is and who is in it", text: $notes, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .accessibilityLabel("Notes for the describer, optional")
                .accessibilityHint("What the video is and who is in it. For example: a 1996 VHS opening; the man in the red sweater is Uncle Bob. Up to 600 characters.")
            Text("For example: a 1996 VHS opening; the man in the red sweater is Uncle Bob.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var partRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Describe only part of it", isOn: $partOn)
                .accessibilityHint("Choose where to start and stop, in hours, minutes and seconds. Good for one commercial in a long tape, or a film too long for one run.")
            if partOn {
                clockField("From", text: $partFrom, hint: "Where the part starts, like 0:00 or 1:02:30.")
                clockField("To", text: $partTo, hint: "Where the part ends, like 3:00 or 1:30:00.")
                if let current = job, let problem = partProblem(current) {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func clockField(_ title: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .accessibilityHidden(true)
            TextField("h:mm:ss", text: text)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel(title)
                .accessibilityHint(hint)
        }
    }

    // MARK: - Cost

    private func costSection(_ current: DVJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cost")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            Text(costSummary(current))
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            if current.state == "ready" {
                if offersPreview(current) {
                    spendButton("preview", title: previewTitle, kind: .start(preview: true))
                }
                spendButton("start", title: "Create described copy", kind: .start(preview: false))
            }
            if current.stoppedOverQuote {
                allowMoreButton(current)
            } else if current.resumable == true {
                spendButton("resume", title: resumeTitle(current), kind: .resume)
            }
        }
    }

    /// After an over-quote stop the plain Continue is not offered: carrying on
    /// means agreeing to a higher limit, so the button names that amount, and
    /// cannot be pressed until the server has priced it.
    private func allowMoreButton(_ current: DVJob) -> some View {
        let quote = estimates["resume"]
        let raise = raiseAmount(quote)
        let blocked = quote == nil || quote?.isAllowed == false || raise <= 0 || isBusy || uploads.isRunning
        return Button {
            askToAllowMore(current)
        } label: {
            Text(allowMoreTitle(raise))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(KadeCardButtonStyle())
        .disabled(blocked)
        .accessibilityHint(allowMoreHint(quote))
    }

    private func allowMoreHint(_ quote: DVEstimate?) -> String {
        guard let quote, quote.isAllowed else { return spendHint(quote) }
        guard raiseAmount(quote) > 0 else { return "How much more it would need could not be worked out." }
        return "Asks before spending. It stops again if it would go past that amount."
    }

    private func allowMoreTitle(_ raise: Double) -> String {
        raise > 0 ? "Allow up to \(Self.money(raise)) more and continue" : "Allow more and continue"
    }

    /// The new limit to agree to: the server's own figure when it gives one
    /// (the resume estimate's approval, which the server works out from how
    /// far over the stopped run went), else the rule an approval is made with
    /// (the price × 1.5 + 10 cents). Never past the limit for one run or what
    /// the account balance has left, which the server would refuse. With no
    /// figure at all there is nothing to agree to: 0, and the button stays
    /// off.
    private func raiseAmount(_ quote: DVEstimate?) -> Double {
        guard let quote else { return 0 }
        let byRule: Double? = quote.estimateUSD.map { $0 * 1.5 + 0.1 }
        guard let wanted = quote.allowUpToUSD ?? quote.approvedUSD ?? byRule else { return 0 }
        var cap = quote.limitUSD ?? config?.limitUSD ?? Double.greatestFiniteMagnitude
        if let left = quote.remainingUSD, left > 0 { cap = min(cap, left) }
        return (min(cap, wanted) * 100).rounded(.down) / 100
    }

    private func overQuoteSentence(_ current: DVJob) -> String {
        var words = "Stopped because it is costing more than quoted: \(Self.money(current.runCostUSD)) spent"
        if let quoted = current.estimatedUSD ?? current.approvedUSD, quoted > 0 {
            words += " of about \(Self.money(quoted))"
        }
        return words + ". It stopped so you can decide."
    }

    /// What carrying on keeps (the website's words).
    private func keptSentence(_ current: DVJob) -> String {
        let finished = current.done ?? 0
        let total = current.sections ?? 0
        if total <= 0 { return "Finished sections are kept and not paid for again." }
        if finished <= 0 { return "No section had finished, so it starts again from the beginning." }
        return "\(finished) of \(total) section\(total == 1 ? "" : "s") finished; they are kept and not paid for again."
    }

    /// A button that spends. Its label carries the server's price; with no
    /// price yet, an answer without a readable price, or a refusal, it cannot
    /// be pressed, because the price is always said before anything is spent.
    private func spendButton(_ action: String, title: String, kind: DVConfirm.Kind) -> some View {
        let quote = estimates[action]
        let price = quote?.estimateUSD
        let label = price.map { "\(title), about \(Self.money($0))" } ?? title
        let blocked = price == nil || quote?.isAllowed == false || isBusy || uploads.isRunning
        return Button {
            askToSpend(action, title: title, kind: kind)
        } label: {
            Text(label)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(KadeCardButtonStyle())
        .disabled(blocked)
        .accessibilityHint(spendHint(quote))
    }

    private func accountPrice(_ quote: DVEstimate) -> String {
        let mode = quote.billingMode ?? config?.billingMode
        // Sep 25 2026: when the server includes dialogue timing (its
        // dialogueIncluded field, on the estimate or in /config), say so,
        // the same words as the website.
        let dialogueIncluded = quote.dialogueIncluded == true || config?.dialogueIncluded == true
        let included = dialogueIncluded ? "Narration and dialogue timing are included." : "Narration is included."
        if mode == "platform" { return "Admin processing is paid by the platform. \(included)" }
        if mode == "balance" {
            if let left = quote.remainingUSD { return "\(Self.money(left)) is available in your account. \(included)" }
            return included
        }
        if let left = quote.remainingUSD, let daily = quote.dailyUSD {
            return "\(Self.money(left)) of \(Self.money(daily)) is left today."
        }
        return ""
    }

    private func spendHint(_ quote: DVEstimate?) -> String {
        guard let quote else {
            return estimating ? "Working out the price." : "The price is not ready yet."
        }
        if !quote.isAllowed {
            return Self.sentence(quote.reason ?? "This run needs more available account balance")
        }
        if quote.estimateUSD == nil {
            return "The price could not be worked out, so this cannot start yet. Change a setting, or open the video again, to ask again."
        }
        var words = "Asks before spending."
        if let aside = quote.setAsideUSD, aside > 0 {
            words += " \(Self.money(aside)) is reserved until it finishes; unused money is returned."
        }
        words += " " + accountPrice(quote)
        return words
    }

    private func costSummary(_ current: DVJob) -> String {
        if current.state == "ready", let problem = partProblem(current) { return problem }
        if current.stoppedOverQuote { return overQuoteExplanation(current) }
        if estimating && estimates.isEmpty { return "Working out the price…" }
        let sentence = priceSentence(current)
        return sentence.isEmpty ? "The price shows here once it is worked out." : sentence
    }

    /// The numbers, what carrying on would allow, and what is kept.
    private func overQuoteExplanation(_ current: DVJob) -> String {
        var words = overQuoteSentence(current)
        let quote = estimates["resume"]
        let raise = raiseAmount(quote)
        if let quote, !quote.isAllowed {
            words += " " + Self.sentence(quote.reason ?? "Carrying on is not possible right now")
        } else if raise > 0 {
            words += " Allowing up to \(Self.money(raise)) more lets it carry on."
        } else if estimating {
            words += " Working out how much more it needs…"
        } else if quote != nil {
            words += " How much more it would need could not be worked out."
        }
        return words + " " + keptSentence(current)
    }

    private func priceSentence(_ current: DVJob) -> String {
        if current.stoppedOverQuote { return overQuoteExplanation(current) }
        let titled: [(String, String)] = [
            ("preview", previewTitle),
            ("start", "Create described copy"),
            ("resume", resumeTitle(current)),
            ("finish", "Describe the rest"),
            ("redo", redoTitle(current)),
        ]
        var parts: [String] = []
        for (action, title) in titled {
            guard let quote = estimates[action] else { continue }
            if !quote.isAllowed {
                parts.append("\(title): \(Self.sentence(quote.reason ?? "not available right now"))")
            } else if let usd = quote.estimateUSD {
                parts.append("\(title), about \(Self.money(usd)).")
            } else {
                parts.append("\(title): the price could not be worked out, so it cannot start yet.")
            }
        }
        if let first = estimates.values.first { parts.append(accountPrice(first)) }
        return parts.joined(separator: " ")
    }

    private var previewTitle: String {
        "Try the first \(Self.lengthWords(config?.previewSeconds ?? 180))"
    }

    private func resumeTitle(_ current: DVJob) -> String {
        (current.done ?? 0) > 0 ? "Continue where it stopped" : "Try again"
    }

    private func redoTitle(_ current: DVJob) -> String {
        let count = current.retryableCount
        return count == 1
            ? "Try again on the part that could not be described"
            : "Try again on the \(count) parts that could not be described"
    }

    private func offersPreview(_ current: DVJob) -> Bool {
        let previewLength = config?.previewSeconds ?? 180
        let length: Double
        if let part = partRange(current) {
            length = part.end - part.start
        } else {
            length = current.seconds ?? 0
        }
        return length > previewLength + 5
    }

    // MARK: - Result

    private func resultsSection(_ current: DVJob) -> some View {
        let copies = current.finishedCopies
        let chosen = copies.first(where: { $0.number == viewVersion }) ?? copies.last
        return VStack(alignment: .leading, spacing: 12) {
            Text("Your described copy")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focus, equals: .results)
            if let chosen {
                Text(copySummary(current, chosen))
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if current.keepable == true {
                Button("Keep 7 more days") {
                    Task { await keepLonger(current) }
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
                .accessibilityHint("Free. Moves the end date on by a week, up to 30 days from today.")
            }
            if copies.count > 1 {
                versionPicker(copies)
            }
            watchButtons
            saveButtons
            if current.state == "done" && current.finishable == true {
                spendButton("finish", title: "Describe the rest", kind: .finish)
            }
            if current.state == "done" && current.retryableCount > 0 {
                spendButton("redo", title: redoTitle(current), kind: .redo)
            }
            if config?.library == true, let chosen {
                librarySave(current, chosen)
            }
        }
    }

    private func copySummary(_ current: DVJob, _ chosen: DVCopy) -> String {
        var parts: [String] = []
        parts.append("Version \(chosen.number)\(chosen.preview == true ? ", a preview" : ""): \(chosen.count ?? 0) descriptions.")
        if chosen.rehearsal == true {
            parts.append("A free rehearsal: a test tone stands in for the narrator.")
        }
        if let part = chosen.range ?? chosen.settings?.range {
            parts.append("It covers \(Self.clock(part.start)) to \(Self.clock(part.end)) of the original.")
        }
        if let seconds = current.seconds, seconds > 0 {
            parts.append("Original length \(Self.lengthWords(seconds)).")
        }
        if let output = chosen.outputSeconds, output > 0 {
            parts.append("Described copy \(Self.lengthWords(output)).")
        }
        if let skipped = chosen.skipped, skipped > 0 {
            parts.append(skipped == 1 ? "1 description was left out; the transcript says why." : "\(skipped) descriptions were left out; the transcript says why.")
        }
        if let failed = chosen.failedSections, failed > 0 {
            parts.append(failed == 1 ? "1 section could not be described." : "\(failed) sections could not be described.")
        }
        if chosen.isSaved {
            parts.append("Saved to your Library.")
        }
        if let expires = current.expiresAt, let when = KadeDateFormatting.stamp(from: expires) {
            let left = KadeDateFormatting.date(from: expires)?.timeIntervalSinceNow ?? 999_999
            parts.append(left < 86_400
                ? "Less than a day left: available until \(when). Save it or put it in the Library to keep it."
                : "Available until \(when).")
            if current.keepable == true {
                parts.append("You can also keep it 7 more days.")
            }
        }
        return parts.joined(separator: " ")
    }

    private func versionLabel(_ chosen: DVCopy) -> String {
        var bits = ["Version \(chosen.number)"]
        if chosen.preview == true { bits.append("preview") }
        if chosen.rehearsal == true { bits.append("rehearsal, test tone") }
        if let settings = chosen.settings {
            if let name = settings.voice { bits.append(Self.voiceName(name)) }
            if let speed = settings.rate { bits.append(Self.speedNumber(speed) + "×") }
            if let level = settings.detail { bits.append(level) }
        }
        if let count = chosen.count { bits.append("\(count) descriptions") }
        if chosen.isSaved { bits.append("saved to Library") }
        return bits.joined(separator: ", ")
    }

    private func versionPicker(_ copies: [DVCopy]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Finished version")
                .font(.subheadline)
                .accessibilityHidden(true)
            Picker("Finished version", selection: $viewVersion) {
                ForEach(copies) { chosen in
                    Text(versionLabel(chosen)).tag(chosen.number)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Finished version")
            .accessibilityHint("Every finished version stays until the video expires.")
        }
    }

    private var watchButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            actionButton("Play the described video", icon: "play.rectangle", key: "play-video", hint: "Opens the player. Done, or the escape gesture, closes it.") {
                Task { await play(video: true) }
            }
            actionButton("Listen to the described audio", icon: "headphones", key: "play-audio", hint: "The soundtrack with the narration, without the picture.") {
                Task { await play(video: false) }
            }
            if voiceOverOn {
                Toggle("Read captions with VoiceOver", isOn: $readCaptions)
                    .accessibilityHint("Off, the captions stay on screen for anyone watching with you, and VoiceOver does not read them over the film. On, VoiceOver reads them, the way Media Descriptions in VoiceOver's Verbosity settings says.")
            }
            actionButton("Read the described transcript", icon: "text.alignleft", key: "read", hint: "Dialogue and descriptions in order, one line at a time.") {
                Task { await readTranscript() }
            }
        }
    }

    private var saveButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Save or share")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            actionButton("Save or share the video", icon: "square.and.arrow.down", key: "save-video", hint: "Downloads the described video, an MP4, then opens the share sheet, where Save to Files is. A long video takes a few minutes.") {
                Task { await saveFile(kind: "video") }
            }
            actionButton("Save or share the audio", icon: "square.and.arrow.down", key: "save-audio", hint: "Downloads the described audio, an M4A, then opens the share sheet.") {
                Task { await saveFile(kind: "audio") }
            }
            actionButton("Save or share the transcript", icon: "doc.text", key: "save-transcript", hint: "The described transcript as a text file, in the share sheet.") {
                Task { await saveFile(kind: "transcript") }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, key: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(fetching == key ? "\(title)…" : title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(KadeCardButtonStyle())
        .disabled(!fetching.isEmpty)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }

    private func librarySave(_ current: DVJob, _ chosen: DVCopy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keep it in your Library")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focus, equals: .librarySave)
            if chosen.isSaved {
                Text("This version is saved to your Library.")
                    .font(.subheadline)
            } else if chosen.rehearsal == true {
                Text("A rehearsal copy is a test tone, so it is not saved to the Library.")
                    .font(.subheadline)
            } else {
                libraryForm(current, chosen)
            }
            Text("Finished copies are kept for seven days. Save yours to Files or put it in the Library to keep it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func libraryForm(_ current: DVJob, _ chosen: DVCopy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Library folder", text: $libraryFolder)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel("Library folder")
                .accessibilityHint("Type a folder path, such as Audio/Commercials/1996, or choose an existing folder below.")
            if !libraryFolders.isEmpty {
                Menu {
                    ForEach(libraryFolders, id: \.self) { folder in
                        Button(folder) { libraryFolder = folder }
                    }
                } label: {
                    Label("Choose an existing folder", systemImage: "folder")
                }
                .accessibilityHint("Fills in the folder box.")
            }
            Toggle("Share it with the family", isOn: $shareWithFamily)
                .accessibilityHint(shareHint(current))
            Button {
                Task { await saveToLibrary(current, version: chosen.number) }
            } label: {
                Text(savingToLibrary ? "Saving…" : "Save this version to my Library")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(KadeCardButtonStyle())
            .disabled(savingToLibrary || libraryFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func shareHint(_ current: DVJob) -> String {
        var words: String
        if current.sourceOwner == "someone else" {
            words = "Off to start with, because the original belongs to someone else."
        } else if current.sourcePrivate == true {
            words = "Off to start with, because the original is private."
        } else {
            words = "On, the family can find it in the Library. Off, only you can."
        }
        if current.sourceGrownUps == true {
            words += " The copy stays grown-ups only, like the original."
        }
        return words
    }

    // MARK: - Your videos

    private var yourVideosSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your videos")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            if jobs.isEmpty {
                Text("No videos yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(jobs) { item in
                jobRow(item)
            }
            Button("Refresh the list") {
                Task {
                    await reloadList()
                    announce("List refreshed. \(jobs.count) video\(jobs.count == 1 ? "" : "s").")
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private func jobRow(_ item: DVJob) -> some View {
        let summary = rowDetail(item)
        return Button {
            Task { await openJob(item.id) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(KadeCardButtonStyle())
        .disabled(uploads.isRunning)
        .accessibilityLabel("\(item.title), \(summary)")
        .accessibilityValue(job?.id == item.id ? "Open" : "")
        .accessibilityHint("Opens this video.")
    }

    private func rowDetail(_ item: DVJob) -> String {
        var bits = [item.stateWord]
        if let seconds = item.seconds, seconds > 0 { bits.append(Self.lengthWords(seconds)) }
        if let created = item.createdAt, let when = KadeDateFormatting.stamp(from: created) { bits.append(when) }
        return bits.joined(separator: ", ")
    }

    // MARK: - Speaking and focus

    /// Writes the live region and says it. With `thenFocus`, VoiceOver moves
    /// there once the sentence has been heard. `high` is for a confirmation
    /// whose moment is now (it started, it saved), which nothing may cut off.
    ///
    /// While a sheet is up (the film playing, the transcript being read) the
    /// line is written but held, and only the latest is said once the sheet
    /// closes: the describer never talks over the described video. The same
    /// while she is away from the screen (another tab, another screen): it is
    /// said when the screen shows again, never over her chat.
    private func announce(_ text: String, thenFocus target: DVFocus? = nil, high: Bool = false) {
        statusLine = text
        if activeSheet != nil || !onScreen {
            if let target {
                pendingFocus = DVPendingFocus(text: text, target: target)
            } else if let waiting = pendingFocus {
                pendingFocus = DVPendingFocus(text: text, target: waiting.target)
            }
            heldAnnouncement = text
            return
        }
        if let target {
            pendingFocus = DVPendingFocus(text: text, target: target)
        }
        if high {
            KadeAnnounce.high(text)
        } else {
            UIAccessibility.post(notification: .announcement, argument: text)
        }
    }

    /// A confirmation whose moment is now (it started, it saved, it's gone).
    private func confirmAloud(_ text: String, thenFocus target: DVFocus? = nil) {
        announce(text, thenFocus: target, high: true)
    }

    /// The sheet has closed, or the screen shows again: say the latest held
    /// line, after VoiceOver has landed back on the screen.
    private func releaseHeldAnnouncement() {
        guard onScreen, activeSheet == nil, let held = heldAnnouncement else { return }
        heldAnnouncement = nil
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard onScreen, activeSheet == nil, heldAnnouncement == nil else { return }
            UIAccessibility.post(notification: .announcement, argument: held)
        }
    }

    /// One render pass for the target to exist, then VoiceOver moves.
    private func moveFocus(_ target: DVFocus) {
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if onScreen, activeSheet == nil { focus = target }
        }
    }

    /// Sounds and buzzes belong to this screen: work that ends after she has
    /// left it is said when she comes back, never sounded over another tab.
    private func sound(_ earcon: Earcon) {
        if onScreen { Earcons.shared.play(earcon) }
    }

    private func buzz(success: Bool) {
        guard onScreen else { return }
        if success { KadeHaptics.success() } else { KadeHaptics.error() }
    }

    private func fail(_ error: Error, _ fallback: String = "Something went wrong. Try again.", thenFocus target: DVFocus? = nil) {
        if error is CancellationError { return }
        sound(.error)
        buzz(success: false)
        announce(Self.message(error, fallback), thenFocus: target)
    }

    static func message(_ error: Error, _ fallback: String) -> String {
        let words = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return words.isEmpty ? fallback : words
    }

    // MARK: - Loading

    private func load() async {
        if loaded {
            await reloadList()
            if let current = job { await refreshJob(current.id) }
            // Prices cancelled when she left are asked for again, quietly.
            if let current = job, estimates.isEmpty, !neededActions(current).isEmpty {
                scheduleEstimates(speak: false)
            }
            takeUploadEnding()
            return
        }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        loadFailed = false
        let fetched: DVConfig
        do {
            fetched = try await service.config()
        } catch {
            if let refusal = error as? DescribedVideoService.DescribedVideoError, refusal.status == 403 {
                refused = true
                retrying = false
                DescribedVideoAccess.shared.record(allowed: false)
                statusLine = "Described video isn't available on this account."
            } else {
                loadFailed = true
                retrying = false
                announce(Self.message(error, "Couldn't open the video describer."))
            }
            return
        }
        prefs = DVPrefs(config: fetched)
        await carryOldVoiceOver(fetched)
        await carryOldSpeedsOver(fetched)
        config = fetched
        loaded = true
        DescribedVideoAccess.shared.record(allowed: true)
        seedDefaults(fetched)
        await reloadList()
        if fetched.library == true, let folders = try? await service.libraryFolders() {
            libraryFolders = folders
        }
        openStart(fetched)
        // An upload that ended while this screen was opening.
        loading = false
        takeUploadEnding()
    }

    private func openStart(_ fetched: DVConfig) {
        defer { retrying = false }
        if start.book != nil && fetched.library == true {
            pendingLibrary = start
            announce("Library video chosen. Choose Check this Library video to check it for free.", thenFocus: .library)
            return
        }
        // The "ready" push: the video it was about, even while another works.
        if start.openFinished, let latest = latestFinished() {
            open(latest)
            return
        }
        // An upload another screen started (or this one's own lock-screen
        // card): nothing is opened under it, and its video opens here when
        // it ends.
        if uploads.isRunning {
            let fraction = uploads.progress ?? 0
            uploadStep = Int(fraction * 10)
            uploadSpokenAt = Date()
            let landing: DVFocus? = retrying ? .choose : nil
            announce("A video is uploading, \(Int((fraction * 100).rounded())) percent. Its progress and Stop button are near the top of this screen; the video opens here when the upload finishes.", thenFocus: landing)
            return
        }
        // A video being described or checked, never one being deleted.
        if let working = jobs.first(where: { $0.isWorking }) {
            open(working)
            return
        }
        // A lock-screen card: every card has the same link, so the video
        // being worked on comes first, then the newest finished.
        if start.openLatest, let latest = latestFinished() {
            open(latest)
            return
        }
        // After Try again, that button has gone: VoiceOver is moved on.
        let target: DVFocus? = retrying ? .choose : nil
        retrying = false
        announce(fetched.enabled == false ? "The describer is not set up yet." : "Choose a video to get started.", thenFocus: target)
    }

    private func latestFinished() -> DVJob? {
        jobs.filter { $0.state == "done" }.max { ($0.finishedAt ?? "") < ($1.finishedAt ?? "") }
    }

    private static let fallbackFolder = "Audio/Described Movies & TV/Described by Kade-AI"

    /// Her last narration choices (never the notes, the part or the paid
    /// passes: those belong to one video) and her default narrator.
    private func seedDefaults(_ fetched: DVConfig) {
        applyRememberedNarration(fetched)
        libraryFolder = fetched.defaultLibraryPath ?? Self.fallbackFolder
    }

    /// Speeds, pauses, detail and volume as she last chose them on this
    /// phone, or the usual ones. The voice is the one her new videos start
    /// with, kept on the server: hers, else the describer's own narrator.
    /// Nothing here costs extra.
    private func applyRememberedNarration(_ fetched: DVConfig?) {
        let saved = UserDefaults.standard.dictionary(forKey: Self.settingsKey) ?? [:]
        let voices = fetched?.voices ?? []
        if let preferred = prefs.defaultVoice, voices.contains(preferred) {
            voice = preferred
        } else {
            voice = voices.first ?? prefs.defaultVoice ?? ""
        }
        // Her account's speeds first (the same on the website), then this
        // phone's memory, then the usual ones.
        let usual = Self.nearestSpeed(prefs.speeds?.rate ?? (saved["rate"] as? Double) ?? 1.5)
        rate = usual
        maxRate = max(usual, Self.nearestSpeed(prefs.speeds?.maxRate ?? (saved["maxRate"] as? Double) ?? 2.25))
        let savedMode = saved["mode"] as? String ?? ""
        mode = Self.modeOptions.contains(where: { $0.value == savedMode }) ? savedMode : "extended"
        let savedDetail = saved["detail"] as? String ?? ""
        detail = Self.detailOptions.contains(where: { $0.value == savedDetail }) ? savedDetail : "standard"
        let savedVolume = saved["volume"] as? String ?? ""
        volume = Self.volumeOptions.contains(where: { $0.value == savedVolume }) ? savedVolume : "balanced"
    }

    /// The paid passes (closer look, first look) are never remembered: each
    /// video asks for them afresh. Nor is the voice (Sep 25 2026): her
    /// default narrator lives on the server, the same on every device.
    private func remember() {
        let saved: [String: Any] = [
            "rate": rate, "maxRate": maxRate, "mode": mode,
            "detail": detail, "volume": volume,
        ]
        UserDefaults.standard.set(saved, forKey: Self.settingsKey)
    }

    // MARK: Speeds kept for her account (Sep 25 2026)

    /// The two narration speed pickers write through these, so only HER
    /// choice is saved (a video's own settings filling the form are not).
    private var usualSpeedChoice: Binding<Double> {
        Binding(get: { rate }, set: { value in
            rate = value
            saveSpeedsSoon()
        })
    }

    private var fastestSpeedChoice: Binding<Double> {
        Binding(get: { maxRate }, set: { value in
            maxRate = value
            saveSpeedsSoon()
        })
    }

    /// Servers from Sep 25 2026 keep her speeds; older ones send none.
    private var speedsOnServer: Bool { config?.speeds != nil }

    /// Saved a moment after she stops changing them, quietly: this phone keeps
    /// them too, and a failed save is tried again with her next change.
    private func saveSpeedsSoon() {
        remember()
        guard speedsOnServer else { return }
        speedSave?.cancel()
        speedSave = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            if let answer = try? await service.setSpeeds(rate: rate, maxRate: maxRate) {
                prefs.speeds = answer.speeds
            }
        }
    }

    private static let playbackRateKey = "kade.describedVideo.playbackRate"

    /// How fast finished videos play: her account's choice, else this phone's.
    private var rememberedPlaybackRate: Double {
        if let kept = prefs.speeds?.playbackRate { return kept }
        let local = UserDefaults.standard.double(forKey: Self.playbackRateKey)
        return local > 0 ? local : 1
    }

    private func keepPlaybackRate(_ value: Double) {
        UserDefaults.standard.set(value, forKey: Self.playbackRateKey)
        guard speedsOnServer else { return }
        Task {
            if let answer = try? await service.setSpeeds(playbackRate: value) {
                prefs.speeds = answer.speeds
            }
        }
    }

    private static let speedsCarriedKey = "kade.describedVideo.speedsCarried"

    /// Once per phone, like the narrator: speeds this phone remembered become
    /// her account's, unless her account already has some.
    private func carryOldSpeedsOver(_ fetched: DVConfig) async {
        let store = UserDefaults.standard
        guard let kept = fetched.speeds, kept.rate == nil, kept.maxRate == nil,
              !store.bool(forKey: Self.speedsCarriedKey) else { return }
        let saved = store.dictionary(forKey: Self.settingsKey) ?? [:]
        let oldRate = saved["rate"] as? Double
        let oldMax = saved["maxRate"] as? Double
        let oldPlayback = store.double(forKey: Self.playbackRateKey)
        guard oldRate != nil || oldMax != nil || oldPlayback > 0 else {
            store.set(true, forKey: Self.speedsCarriedKey)
            return
        }
        guard let answer = try? await service.setSpeeds(
            rate: oldRate.map { Self.nearestSpeed($0) },
            maxRate: oldMax.map { Self.nearestSpeed($0) },
            playbackRate: oldPlayback > 0 ? oldPlayback : nil
        ) else { return }
        prefs.speeds = answer.speeds
        store.set(true, forKey: Self.speedsCarriedKey)
    }

    private static let carriedKey = "kade.describedVideo.defaultCarried"
    /// The describer's old fallback: never carried over, since it was only
    /// ever the voice nobody chose.
    private static let oldFallbackVoice = "clear woman · flint"

    /// Once per phone, as the website does: the voice this phone remembered
    /// becomes her default on the server, unless she already has one there.
    /// A failure is quiet and tried again next time.
    private func carryOldVoiceOver(_ fetched: DVConfig) async {
        let store = UserDefaults.standard
        guard fetched.favorites != nil, fetched.myDefaultVoice == nil, !store.bool(forKey: Self.carriedKey) else { return }
        let saved = store.dictionary(forKey: Self.settingsKey) ?? [:]
        guard let old = saved["voice"] as? String, old != Self.oldFallbackVoice,
              (fetched.voices ?? []).contains(old) else { return }
        guard let answer = try? await service.setDefaultVoice(old) else { return }
        prefs = answer
        store.set(true, forKey: Self.carriedKey)
    }

    /// A video's own choices, when it has them. A new video starts from her
    /// remembered narration with empty notes, the paid passes off and the
    /// whole video, so nothing from the last video carries into the next.
    /// Answers whether that cleared anything she had set.
    private func seed(from settings: DVSettings?, range: DVRange?) -> Bool {
        let part = settings?.range ?? range
        let cleared = settings == nil
            && (!notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || closeLook || firstLook || partOn)
        notes = settings?.notes ?? ""
        closeLook = settings?.closeLook ?? false
        firstLook = settings?.firstLook ?? false
        partOn = part != nil
        partFrom = part.map { Self.clock($0.start) } ?? ""
        partTo = part.map { Self.clock($0.end) } ?? ""
        guard let settings else {
            applyRememberedNarration(config)
            return cleared
        }
        if let name = settings.voice, (config?.voices ?? []).contains(name) { voice = name }
        if let value = settings.rate { rate = Self.nearestSpeed(value) }
        if let value = settings.maxRate { maxRate = max(rate, Self.nearestSpeed(value)) }
        if let value = settings.mode, Self.modeOptions.contains(where: { $0.value == value }) { mode = value }
        if let value = settings.detail, Self.detailOptions.contains(where: { $0.value == value }) { detail = value }
        if let value = settings.volume, Self.volumeOptions.contains(where: { $0.value == value }) { volume = value }
        return false
    }

    private func reloadList() async {
        guard let list = try? await service.jobs() else { return }
        jobs = list.jobs
        service.settleCards(with: list.jobs)
    }

    private func upsert(_ fresh: DVJob) {
        if let index = jobs.firstIndex(where: { $0.id == fresh.id }) {
            jobs[index] = fresh
        } else {
            jobs.insert(fresh, at: 0)
        }
    }

    // MARK: - Opening and following one video

    /// With `saying`, that sentence is heard first and VoiceOver lands on the
    /// video's heading after it; without, it lands there at once.
    private func open(_ fresh: DVJob, saying: String? = nil) {
        // A sentence of its own is not talked over by the prices; they wait
        // on the buttons.
        apply(fresh, quiet: true, speakPrices: saying == nil ? nil : false)
        if let saying {
            let note = freshNote
            freshNote = ""
            announce(saying + (note.isEmpty ? "" : " " + note), thenFocus: .jobHeading)
        } else {
            statusLine = "\(fresh.title): \(fresh.stateWord)."
            moveFocus(.jobHeading)
        }
    }

    private func openJob(_ id: String) async {
        if job?.id == id {
            moveFocus(.jobHeading)
            return
        }
        do {
            let fresh = try await service.job(id)
            open(fresh)
        } catch {
            fail(error)
        }
    }

    private func refreshJob(_ id: String) async {
        guard let fresh = try? await service.job(id), job?.id == id else { return }
        apply(fresh)
    }

    /// `focusChoose` false when the caller says something first and moves
    /// VoiceOver after it (a deletion, a video that has gone).
    private func closeJob(focusChoose: Bool = true) {
        stopPolling()
        estimateTask?.cancel()
        job = nil
        files = nil
        estimates = [:]
        viewVersion = 0
        if focusChoose { moveFocus(.choose) }
    }

    /// Every fresh copy of a video comes through here: from the list, from a
    /// poll, or back from an action. `quiet` updates what has been said
    /// without saying it (the caller speaks for itself).
    private func apply(_ fresh: DVJob, quiet: Bool = false, speakPrices: Bool? = nil) {
        let previous: DVJob? = job?.id == fresh.id ? job : nil
        if previous == nil {
            stopPolling()
            resetForJob(fresh)
        }
        job = fresh
        upsert(fresh)
        updateCard(fresh)
        let copies = fresh.finishedCopies
        if let last = copies.last {
            let justFinished = previous != nil && previous?.state != "done" && fresh.state == "done"
            if viewVersion == 0 || justFinished || !copies.contains(where: { $0.number == viewVersion }) {
                viewVersion = last.number
            }
        } else {
            viewVersion = 0
        }
        if let previous {
            speakChanges(fresh, previous: previous, quiet: quiet)
        }
        if fresh.needsWatching { ensurePolling() }
        let actionsChanged = previous?.state != fresh.state
            || previous?.resumable != fresh.resumable
            || previous?.finishable != fresh.finishable
            || previous?.retryableCount != fresh.retryableCount
        // Prices are spoken when a video is opened or a setting changes; a
        // change of state says its own sentence and the prices wait on the
        // buttons, so the two never talk over each other.
        if actionsChanged {
            scheduleEstimates(speak: speakPrices ?? (previous == nil))
        }
    }

    private func resetForJob(_ fresh: DVJob) {
        files = nil
        filesKey = ""
        viewVersion = 0
        estimates = [:]
        estimateTask?.cancel()
        spokenState = fresh.state
        spokenStage = fresh.stage ?? ""
        spokenProgress = fresh.progress ?? 0
        spokenAt = Date()
        samplePlayer?.stop()
        let cleared = seed(from: fresh.settings, range: fresh.range)
        freshNote = cleared ? "New video: notes are empty and the extra passes are off. " : ""
        shareWithFamily = !(fresh.sourcePrivate == true || fresh.sourceOwner == "someone else")
        // The server's suggestion (the Audio mirror of the original's shelf)
        // first; a folder typed for the last video never carries over.
        let suggested = (fresh.libraryPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        libraryFolder = suggested.isEmpty ? (config?.defaultLibraryPath ?? Self.fallbackFolder) : suggested
        seededSignature = settingsSignature
    }

    /// Real changes only: a new state at once; the stage and percent at most
    /// every thirty seconds.
    private func speakChanges(_ fresh: DVJob, previous: DVJob, quiet: Bool) {
        let now = Date()
        if fresh.state != previous.state {
            spokenState = fresh.state
            spokenStage = fresh.stage ?? ""
            spokenProgress = fresh.progress ?? 0
            spokenAt = now
            if quiet { return }
            // A state that takes buttons away (Cancel, Check again) moves
            // VoiceOver to the video's heading once the news is heard, so it
            // is never left on a button that has gone.
            switch fresh.state {
            case "ready":
                sound(.actionDone)
                let note = freshNote
                freshNote = ""
                announce("Video checked. It is \(Self.lengthWords(fresh.seconds ?? 0)) long. \(note)Choose the narration, then how much to describe.", thenFocus: .voice)
            case "done":
                sound(.actionDone)
                buzz(success: true)
                announce(fresh.preview == true ? "Your preview is ready." : "Your described copy is ready.", thenFocus: .results)
            case "failed":
                sound(.error)
                buzz(success: false)
                announce(failedSentence(fresh), thenFocus: .jobHeading)
            case "cancelled":
                announce("Cancelled. Finished sections are kept, so you can continue later.", thenFocus: .jobHeading)
            default:
                announce(stageSentence(fresh), thenFocus: previous.isWorking == fresh.isWorking ? nil : .jobHeading)
            }
            return
        }
        if quiet { return }
        if fresh.cancelStuck == true && previous.cancelStuck != true {
            spokenAt = now
            announce("Still stopping. Press Cancel again if it does not stop.")
            return
        }
        guard now.timeIntervalSince(spokenAt) >= 30 else { return }
        let stage = fresh.stage ?? ""
        let progress = fresh.progress ?? 0
        guard stage != spokenStage || abs(progress - spokenProgress) >= 5 else { return }
        spokenStage = stage
        spokenProgress = progress
        spokenAt = now
        announce(stageSentence(fresh))
    }

    /// The lock-screen card follows a run: waiting, describing, then how it
    /// ended. Words change only with the stage; the bar carries the percent.
    private func updateCard(_ fresh: DVJob) {
        let title = "Described video: \(fresh.title)"
        switch fresh.state {
        case "reserving", "queued":
            service.showCard(jobId: fresh.id, title: title, status: "Waiting its turn", progress: nil)
        case "running":
            service.showCard(jobId: fresh.id, title: title, status: "Describing", progress: min(1, max(0, (fresh.progress ?? 0) / 100)))
        case "done":
            service.endCard(jobId: fresh.id, status: fresh.preview == true ? "Preview ready" : "Ready to watch")
        case "ready":
            service.endCard(jobId: fresh.id, status: "Checked and ready")
        case "cancelled":
            service.endCard(jobId: fresh.id, status: "Stopped", failed: true)
        case "failed":
            service.endCard(jobId: fresh.id, status: fresh.overQuote == true ? "Stopped: costing more than quoted" : "Didn't finish", failed: true)
        default:
            break
        }
    }

    /// Every five seconds while the screen is up; every fifteen while the app
    /// is in the background and iOS still lets it run. Never while she is
    /// away from the screen: coming back refreshes the video and starts it.
    private func ensurePolling() {
        guard onScreen, pollTask == nil, let current = job, current.needsWatching else { return }
        let jobId = current.id
        pollTask = Task {
            var misses = 0
            while !Task.isCancelled {
                let pause: UInt64 = appActive ? 5_000_000_000 : 15_000_000_000
                try? await Task.sleep(nanoseconds: pause)
                if Task.isCancelled || job?.id != jobId { return }
                do {
                    let fresh = try await service.job(jobId)
                    if Task.isCancelled || job?.id != jobId { return }
                    misses = 0
                    apply(fresh)
                    if !fresh.needsWatching {
                        pollTask = nil
                        await reloadList()
                        return
                    }
                } catch {
                    if Task.isCancelled { return }
                    let status = (error as? DescribedVideoService.DescribedVideoError)?.status ?? 0
                    if status == 404 {
                        pollTask = nil
                        closeJob(focusChoose: false)
                        announce("That video is gone. It may have been deleted.", thenFocus: .choose)
                        await reloadList()
                        return
                    }
                    // Signed out (the refresh was already tried once): stop
                    // asking every few seconds; opening the screen again
                    // after signing in picks it back up.
                    if status == 401 || status == 403 {
                        pollTask = nil
                        announce(Self.message(error, "Kade-AI can't check on this video right now. It keeps going on the server."))
                        return
                    }
                    misses += 1
                    if misses == 2 || misses % 8 == 0 {
                        announce("Can't check on the video right now. It keeps going on the server; checking again shortly.")
                    }
                }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Prices

    private var settingsSignature: String {
        "\(voice)|\(rate)|\(maxRate)|\(mode)|\(detail)|\(volume)|\(closeLook)|\(firstLook)|\(partOn)|\(partFrom)|\(partTo)"
    }

    private func settingsChanged() {
        samplePlayer?.stop()
        // Opening a video seeds these, and `apply` has already asked for its
        // prices (and decided whether to say them): the seeding is not a
        // change she made, so it neither restarts nor speaks them. One use.
        let seeded = seededSignature
        seededSignature = ""
        if !seeded.isEmpty && settingsSignature == seeded { return }
        guard let current = job, !neededActions(current).isEmpty else { return }
        scheduleEstimates(speak: true)
    }

    private func neededActions(_ current: DVJob) -> [String] {
        var actions: [String] = []
        if current.state == "ready" {
            if offersPreview(current) { actions.append("preview") }
            actions.append("start")
        }
        if current.resumable == true { actions.append("resume") }
        if current.state == "done" && current.finishable == true { actions.append("finish") }
        if current.state == "done" && current.retryableCount > 0 { actions.append("redo") }
        return actions
    }

    /// Old prices are dropped the moment anything changes, so a button can
    /// never spend on a price that no longer applies; the new ones are asked
    /// for a moment after the last change.
    private func scheduleEstimates(speak: Bool) {
        estimateTask?.cancel()
        estimates = [:]
        estimateRound += 1
        let round = estimateRound
        guard let current = job, !neededActions(current).isEmpty else {
            estimating = false
            return
        }
        let jobId = current.id
        estimating = true
        estimateTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if Task.isCancelled { return }
            await runEstimates(jobId: jobId, round: round, speak: speak)
        }
    }

    private func runEstimates(jobId: String, round: Int, speak: Bool) async {
        guard let current = job, current.id == jobId else { return }
        defer {
            if round == estimateRound { estimating = false }
        }
        if current.state == "ready", let problem = partProblem(current) {
            if speak { announce(problem) }
            return
        }
        for action in neededActions(current) {
            // Carrying on can change only the voice fields, and is priced
            // with exactly what Continue will send.
            let settings: [String: Any]?
            switch action {
            case "finish", "redo": settings = nil
            case "resume": settings = voiceFields
            default: settings = settingsBody(current)
            }
            let sections: [Int]? = action == "redo" ? current.retryableSections?.sections : nil
            do {
                let quote = try await service.estimate(jobId: jobId, action: action, settings: settings, sections: sections)
                if Task.isCancelled || round != estimateRound { return }
                estimates[action] = quote
            } catch {
                if Task.isCancelled || round != estimateRound { return }
                announce(Self.message(error, "Couldn't work out the price. Try again."))
                return
            }
        }
        if speak, let latest = job, latest.id == jobId {
            let note = freshNote
            freshNote = ""
            announce(note + priceSentence(latest))
        }
    }

    private func settingsBody(_ current: DVJob) -> [String: Any] {
        var body: [String: Any] = [
            "voice": voice,
            "rate": rate,
            "maxRate": maxRate,
            "mode": mode,
            "detail": detail,
            "volume": volume,
            "notes": notes.trimmingCharacters(in: .whitespacesAndNewlines),
            "closeLook": closeLook,
            "firstLook": firstLook,
        ]
        if let part = partRange(current) {
            let end = current.seconds.map { min(part.end, $0) } ?? part.end
            body["range"] = ["start": part.start, "end": end]
        }
        return body
    }

    private var voiceFields: [String: Any] {
        ["voice": voice, "rate": rate, "maxRate": maxRate, "mode": mode, "volume": volume]
    }

    private func partRange(_ current: DVJob) -> DVRange? {
        guard partOn, let from = Self.parseClock(partFrom), let to = Self.parseClock(partTo) else { return nil }
        return DVRange(start: from, end: to)
    }

    private func partProblem(_ current: DVJob) -> String? {
        guard partOn else { return nil }
        guard let from = Self.parseClock(partFrom) else { return "Type where the part starts, like 0:00 or 1:02:30." }
        guard let to = Self.parseClock(partTo) else { return "Type where the part ends, like 3:00 or 1:30:00." }
        if to - from < 1 { return "The part must end at least one second after it starts." }
        if let total = current.seconds, total > 0, from >= total {
            return "The part starts after the video ends. The video is \(Self.clock(total)) long."
        }
        if let limit = config?.maxMinutes, limit > 0, min(to, current.seconds ?? to) - from > limit * 60 + 0.5 {
            return "One run describes up to \(Self.lengthWords(limit * 60)). Choose a shorter part."
        }
        return nil
    }

    private func fillPartDefaults() {
        if partFrom.trimmingCharacters(in: .whitespaces).isEmpty { partFrom = "0:00" }
        if partTo.trimmingCharacters(in: .whitespaces).isEmpty, let total = job?.seconds, total > 0 {
            let limit = (config?.maxMinutes ?? 0) * 60
            partTo = Self.clock(limit > 0 ? min(total, limit) : total)
        }
    }

    // MARK: - Spending (asked first, price named)

    /// Never without a readable price: the price is said before anything is
    /// spent.
    private func askToSpend(_ action: String, title: String, kind: DVConfirm.Kind) {
        guard let current = job, let quote = estimates[action], quote.isAllowed, let usd = quote.estimateUSD else { return }
        let price = Self.money(usd)
        var message = "About \(price)."
        if let maximum = quote.approvedUSD { message += " Maximum charge: \(Self.money(maximum))." }
        message += " " + accountPrice(quote)
        if let aside = quote.setAsideUSD, aside > 0 {
            message += " \(Self.money(aside)) is reserved until it finishes; unused money is returned."
        }
        if case .resume = kind {
            message += " " + keptSentence(current)
        }
        message += " You can leave this screen. It keeps going on the server, and you'll get a notice when it's done."
        confirm = DVConfirm(kind: kind, title: "\(title)?", message: message, button: "\(title), about \(price)", jobId: current.id)
    }

    /// The new limit is named in the question and on the button that agrees.
    private func askToAllowMore(_ current: DVJob) {
        guard let quote = estimates["resume"], quote.isAllowed else { return }
        let raise = raiseAmount(quote)
        guard raise > 0 else { return }
        var message = overQuoteSentence(current)
        message += " Carrying on may spend up to \(Self.money(raise)) more, and it stops again if it would go past that."
        message += " " + keptSentence(current)
        message += " " + accountPrice(quote)
        confirm = DVConfirm(
            kind: .allowMore(raise),
            title: "Let \(current.title) carry on?",
            message: message,
            button: allowMoreTitle(raise),
            jobId: current.id
        )
    }

    private func cancelConfirm(_ current: DVJob) -> DVConfirm {
        DVConfirm(
            kind: .cancel,
            title: "Cancel processing?",
            message: "Cancel \(current.title)? Finished sections are kept, so you can continue later. Work already sent to a service may still be charged.",
            button: "Cancel processing",
            jobId: current.id,
            destructive: true,
            keep: "Keep going"
        )
    }

    private func deleteConfirm(_ current: DVJob) -> DVConfirm {
        DVConfirm(
            kind: .delete,
            title: "Delete this video?",
            message: "Delete \(current.title) and all its files? This cannot be undone.",
            button: "Delete",
            jobId: current.id,
            destructive: true
        )
    }

    private func abandonConfirm(_ current: DVJob, version: Int) -> DVConfirm {
        DVConfirm(
            kind: .abandon,
            title: "Go back to version \(version)?",
            message: "The stopped remake of \(current.title) is set aside, and version \(version) is the current copy again.",
            button: "Go back to version \(version)",
            jobId: current.id
        )
    }

    /// Acts only on the video the question named, and only while it is the
    /// open one (its prices and settings are the ones on screen).
    private func perform(_ item: DVConfirm) async {
        guard let current = job, current.id == item.jobId else {
            announce("That video is no longer open, so nothing was done.")
            return
        }
        let id = current.id
        switch item.kind {
        case .start(let preview):
            remember()
            // The server records it too; this keeps Recently used current until the next load.
            prefs.noteRecent(voice)
            let body = settingsBody(current)
            let said = preview
                ? "Started the preview. You can leave this screen; you'll get a notice when it's ready."
                : "Started. You can leave this screen; you'll get a notice when it's done."
            await act(said) { try await service.start(jobId: id, settings: body, preview: preview) }
        case .finish:
            await act("Describing the rest. You'll get a notice when it's done.") { try await service.finish(jobId: id) }
        case .resume:
            remember()
            prefs.noteRecent(voice)
            let fields = voiceFields
            await act("Carrying on from where it stopped.") { try await service.resume(jobId: id, voiceFields: fields) }
        case .allowMore(let raise):
            remember()
            prefs.noteRecent(voice)
            let fields = voiceFields
            await act("Carrying on, up to \(Self.money(raise)) more.") {
                try await service.resume(jobId: id, voiceFields: fields, allowUpToUSD: raise)
            }
        case .redo:
            let version = current.version ?? viewVersion
            await act("Trying those parts again. The rest of the copy is kept.") { try await service.redo(jobId: id, expectedVersion: version) }
        case .cancel:
            await act("Cancelling. Finished sections are kept, so you can continue later.", earcon: false) { try await service.cancel(jobId: id) }
        case .abandon:
            await act("Back to the earlier version.", earcon: false) { try await service.abandon(jobId: id) }
        case .delete:
            await deleteJob(id)
        }
    }

    /// Every action takes its own button away (Create, Continue, Check
    /// again, Go back...), so VoiceOver moves to the video's heading once
    /// the confirmation has been heard.
    private func act(_ said: String, earcon: Bool = true, _ work: () async throws -> DVJob) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let fresh = try await work()
            if earcon { sound(.actionStart) }
            confirmAloud(said, thenFocus: .jobHeading)
            apply(fresh, quiet: true)
            await reloadList()
        } catch {
            fail(error)
        }
    }

    private func recheck(_ current: DVJob) async {
        let id = current.id
        await act("Checking the video again. Checking is free.") { try await service.recheck(jobId: id) }
    }

    /// Free, so it is not asked first. When it can be kept no longer the
    /// button goes, and VoiceOver moves to the copy's heading.
    private func keepLonger(_ current: DVJob) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let fresh = try await service.keep(jobId: current.id)
            guard job?.id == current.id else { return }
            apply(fresh, quiet: true)
            let when = fresh.expiresAt.flatMap { KadeDateFormatting.stamp(from: $0) }
            var words = when.map { "Kept until \($0)." } ?? "Kept 7 more days."
            if fresh.keepable != true {
                words += " That is as long as it can be kept here; save it to Files or put it in the Library to keep it longer."
            }
            sound(.actionDone)
            confirmAloud(words, thenFocus: fresh.keepable == true ? nil : .results)
        } catch {
            fail(error)
        }
    }

    private func deleteJob(_ id: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.delete(jobId: id)
            service.endCard(jobId: id, status: "Deleted", failed: true)
            jobs.removeAll { $0.id == id }
            closeJob(focusChoose: false)
            confirmAloud("Deleted.", thenFocus: .choose)
            await reloadList()
        } catch {
            fail(error)
        }
    }

    private func rename() async {
        guard let current = job, current.id == renameJobId else {
            announce("That video is no longer open, so it was not renamed.")
            return
        }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != current.title else { return }
        do {
            let fresh = try await service.rename(jobId: current.id, name: name)
            apply(fresh, quiet: true)
            files = nil
            announce("Renamed to \(fresh.title).")
        } catch {
            fail(error)
        }
    }

    // MARK: - Choosing: Files, Photos, YouTube, Library

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            fail(error)
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if scoped { url.stopAccessingSecurityScopedResource() }
            let size = values?.fileSize ?? 0
            let stamp = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            let key = "files|\(url.lastPathComponent)|\(size)|\(stamp)"
            beginUpload(fileURL: url, name: url.lastPathComponent, recoveryKey: key, scoped: true, cleanUp: false)
        }
    }

    private func loadPicked(_ item: PhotosPickerItem) async {
        guard !uploads.isRunning else {
            announce("An upload is already running.")
            return
        }
        isBusy = true
        announce("Getting the video from Photos. A long video can take a minute.")
        let movie = try? await item.loadTransferable(type: DescribedVideoMovie.self)
        isBusy = false
        guard let movie else {
            fail(DescribedVideoService.DescribedVideoError(message: "Couldn't get that video from Photos. Try again, or save it to Files and choose it there."))
            return
        }
        let size = (try? movie.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let key = "photos|\(movie.originalName)|\(size)"
        beginUpload(fileURL: movie.url, name: movie.originalName, recoveryKey: key, scoped: false, cleanUp: true)
    }

    private func beginUpload(fileURL: URL, name: String, recoveryKey: String, scoped: Bool, cleanUp: Bool) {
        let began = uploads.run {
            await runUpload(fileURL: fileURL, name: name, recoveryKey: recoveryKey, scoped: scoped, cleanUp: cleanUp)
        }
        if !began {
            if cleanUp { try? FileManager.default.removeItem(at: fileURL) }
            announce("An upload is already running.")
        }
    }

    /// Checks what the phone can check for free (size, length), then uploads
    /// in the server's chunks. Stopping keeps what has arrived: the same video
    /// picked again carries on from there. How it ended is said by the screen
    /// she is on when it ends (takeUploadEnding), which may not be this one.
    private func runUpload(fileURL: URL, name: String, recoveryKey: String, scoped: Bool, cleanUp: Bool) async -> DescribedVideoUploads.Ending? {
        let access = scoped ? fileURL.startAccessingSecurityScopedResource() : false
        defer {
            if access { fileURL.stopAccessingSecurityScopedResource() }
            if cleanUp { try? FileManager.default.removeItem(at: fileURL) }
        }
        guard let current = config else { return nil }
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size > 0 else {
            return .failed(DescribedVideoService.DescribedVideoError(message: "That video could not be read. Try choosing it again."))
        }
        if let limit = current.maxBytes, size > limit {
            return .failed(DescribedVideoService.DescribedVideoError(message: "That video is larger than \(Self.bytesWords(limit)). Choose a smaller file, or trim it first."))
        }
        let seconds = (try? await AVURLAsset(url: fileURL).load(.duration).seconds) ?? 0
        if let longest = current.maxSourceMinutes, longest > 0, seconds.isFinite, seconds > longest * 60 + 1 {
            return .failed(DescribedVideoService.DescribedVideoError(message: "That video is \(Self.lengthWords(seconds)) long. The describer can check videos up to \(Self.lengthWords(longest * 60))."))
        }
        if Task.isCancelled { return .stopped }
        uploadStep = 0
        uploadSpokenAt = Date()
        DescribedVideoUploads.shared.started(name: name)
        sound(.actionStart)
        announce("Uploading \(name). Keep Kade-AI open until the upload finishes.")
        do {
            let fresh = try await service.upload(fileURL: fileURL, name: name, recoveryKey: recoveryKey) { fraction in
                DescribedVideoUploads.shared.moved(fraction)
            }
            return .uploaded(fresh)
        } catch {
            if error is CancellationError || Task.isCancelled { return .stopped }
            return .failed(error)
        }
    }

    /// The voice follows the bar at most every thirty seconds, on the screen
    /// she is on. (The bar and the lock-screen card are DescribedVideoUploads'.)
    private func uploadMoved(_ fraction: Double) {
        let step = Int(fraction * 10)
        guard onScreen, step != uploadStep else { return }
        uploadStep = step
        let now = Date()
        if step < 10 && now.timeIntervalSince(uploadSpokenAt) >= 30 {
            uploadSpokenAt = now
            announce("Uploading: \(step * 10) percent.")
        }
    }

    /// How an upload ended, said once by the screen she is on: the screen that
    /// started it may have been replaced by another since. A hidden screen
    /// leaves it for when it shows again; a screen made after the upload
    /// ended leaves it alone.
    private func takeUploadEnding() {
        guard onScreen, loaded, !loading, let ending = uploads.take(after: seenUploadEnding) else { return }
        // The progress row and its Stop button have gone with the upload.
        let landing: DVFocus = job == nil ? .choose : .jobHeading
        switch ending {
        case .uploaded(let fresh):
            sound(.actionDone)
            open(fresh)
        case .stopped:
            announce("Upload stopped. Choose the same video again to carry on from where it stopped.", thenFocus: landing)
        case .failed(let error):
            fail(error, thenFocus: landing)
        }
        // A half-uploaded video still shows in the list.
        Task { await reloadList() }
    }

    /// Sep 25 2026, her ask: a YouTube link copied in another app fills the
    /// link box by itself (once per copy), and says so. Importing still waits
    /// for her to choose Import from YouTube.
    private func fillCopiedYouTubeLink() {
        Task {
            // A greyed-out box (no Family feature pack) is never filled in.
            guard youtubeLink.isEmpty, !choosingDisabled, linkLock == nil,
                  let link = await CopiedLink.take("described-video-youtube", where: CopiedLink.isYouTube),
                  youtubeLink.isEmpty else { return }
            youtubeLink = link
            announce("Filled in the YouTube link you copied. Choose Import from YouTube to check it.")
        }
    }

    private func importYouTube() async {
        let link = youtubeLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, !isBusy else { return }
        if let lock = linkLock { announce(lock + "."); return }
        isBusy = true
        defer { isBusy = false }
        announce("Importing from YouTube.")
        do {
            let fresh = try await service.importYouTube(url: link)
            youtubeLink = ""
            sound(.actionStart)
            open(fresh)
            await reloadList()
        } catch {
            fail(error)
        }
    }

    private func importLibrary(_ pending: DescribedVideoStart) async {
        guard let book = pending.book, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        announce("Checking the Library video.")
        do {
            let fresh = try await service.importLibrary(book: book, track: pending.track ?? 0)
            pendingLibrary = nil
            if fresh.existing == true {
                // The server found one she already has (unfinished or
                // finished) instead of starting a second: open that one.
                sound(.actionDone)
                let copies = fresh.finishedCopies.isEmpty ? "." : "; your described copy is below."
                open(fresh, saying: "You already have this video: \(fresh.title), \(fresh.stateWord). It is open now\(copies)")
            } else {
                sound(.actionStart)
                open(fresh)
            }
            await reloadList()
        } catch {
            fail(error)
        }
    }

    // MARK: - Hearing, watching, saving

    private func playSample() async {
        guard !voice.isEmpty, !sampling else { return }
        sampling = true
        defer { sampling = false }
        statusLine = "Making a sample of \(Self.voiceName(voice))."
        do {
            let data = try await service.sample(voice: voice, rate: rate)
            // Made after she left: not played over another tab.
            guard onScreen else { return }
            LibraryNowPlaying.shared.pauseForOtherAudio("a voice sample")
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
            let player = try AVAudioPlayer(data: data)
            samplePlayer?.stop()
            samplePlayer = player
            if player.play() {
                statusLine = "Playing a sample of \(Self.voiceName(voice))."
            } else {
                announce("The sample could not play. Try again.")
            }
        } catch {
            fail(error)
        }
    }

    /// Signed links last six hours; they are asked for again after five.
    private func currentFiles(_ current: DVJob) async throws -> DVFiles {
        let key = "\(current.id)/\(viewVersion)"
        if let files, filesKey == key, Date().timeIntervalSince(filesAt) < 5 * 3600 {
            return files
        }
        let fresh = try await service.files(jobId: current.id, version: viewVersion)
        files = fresh
        filesKey = key
        filesAt = Date()
        return fresh
    }

    private func play(video: Bool) async {
        guard let current = job, fetching.isEmpty, viewVersion > 0 else { return }
        fetching = video ? "play-video" : "play-audio"
        defer { fetching = "" }
        do {
            let links = try await currentFiles(current)
            // She may have opened another video, or left, while the links came.
            guard job?.id == current.id, onScreen else { return }
            guard let link = video ? links.video : links.audio, let url = URL(string: link) else {
                announce("That file is not available for this copy.")
                return
            }
            samplePlayer?.stop()
            LibraryNowPlaying.shared.pauseForOtherAudio("a described video")
            let captions: URL? = video ? links.captions.flatMap { URL(string: $0) } : nil
            activeSheet = .player(DVPlayerItem(
                url: url,
                title: video ? "\(current.title), described" : "\(current.title), described audio",
                isVideo: video,
                captions: captions
            ))
        } catch {
            fail(error)
        }
    }

    private func readTranscript() async {
        guard let current = job, fetching.isEmpty, viewVersion > 0 else { return }
        fetching = "read"
        defer { fetching = "" }
        do {
            let text = try await service.text(jobId: current.id, kind: "transcript", version: viewVersion)
            guard job?.id == current.id, onScreen else { return }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                announce("The transcript is empty for this copy.")
                return
            }
            activeSheet = .transcript(text, "\(current.title), transcript")
        } catch {
            fail(error)
        }
    }

    private func saveFile(kind: String) async {
        guard let current = job, fetching.isEmpty, viewVersion > 0 else { return }
        fetching = "save-\(kind)"
        defer { fetching = "" }
        do {
            let fileURL: URL
            if kind == "transcript" {
                let text = try await service.text(jobId: current.id, kind: "transcript", version: viewVersion)
                fileURL = try service.textFile(text, fileName: DescribedVideoService.fileName(current.title, label: "described transcript", ext: "txt"))
            } else {
                let links = try await currentFiles(current)
                let isVideo = kind == "video"
                guard let link = isVideo ? (links.videoDownload ?? links.video) : (links.audioDownload ?? links.audio) else {
                    announce("That file is not available for this copy.")
                    return
                }
                announce(isVideo ? "Getting the described video. A long video takes a few minutes." : "Getting the described audio.")
                fileURL = try await service.download(
                    from: link,
                    fileName: DescribedVideoService.fileName(current.title, label: isVideo ? "described" : "described audio", ext: isVideo ? "mp4" : "m4a")
                )
            }
            // She opened another video, or left, while it came: the copy goes.
            guard job?.id == current.id, onScreen else {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            sound(.actionDone)
            buzz(success: true)
            if let old = sharedFile, old != fileURL { try? FileManager.default.removeItem(at: old) }
            sharedFile = fileURL
            activeSheet = .share(ShareItem(fileURL: fileURL))
        } catch {
            fail(error)
        }
    }

    /// The share sheet has closed (or the screen has gone): the downloaded
    /// copy is deleted rather than left in tmp, one per film.
    private func removeSharedFile() {
        guard let url = sharedFile else { return }
        sharedFile = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func saveToLibrary(_ current: DVJob, version: Int) async {
        let path = libraryFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !savingToLibrary else { return }
        savingToLibrary = true
        defer { savingToLibrary = false }
        announce("Saving to your Library.")
        do {
            let saved = try await service.saveToLibrary(jobId: current.id, version: version, path: path, share: shareWithFamily)
            sound(.actionDone)
            buzz(success: true)
            let place = (saved.path ?? "").isEmpty ? "" : " in \(saved.path ?? "")"
            // The folder form gives way to "saved"; VoiceOver lands on the
            // section's heading instead of nowhere.
            confirmAloud("Saved to your Library\(place).", thenFocus: .librarySave)
            await refreshJob(current.id)
        } catch {
            fail(error)
        }
    }

    // MARK: - Words

    static func voiceName(_ name: String) -> String {
        name.isEmpty ? "No voice chosen" : name.replacingOccurrences(of: " · ", with: ", ")
    }

    static func speedNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// "1.5×, roughly 220 words a minute": the voice's own pace is about 150.
    static func speedLabel(_ value: Double) -> String {
        let words = Int(150 * value / 10) * 10
        let own = value == 1 ? " (the voice's own pace)" : ""
        return "\(speedNumber(value))×\(own), roughly \(words) words a minute"
    }

    static func nearestSpeed(_ value: Double) -> Double {
        speeds.min(by: { abs($0 - value) < abs($1 - value) }) ?? 1.5
    }

    static func money(_ value: Double?) -> String {
        let amount = value ?? 0
        if amount > 0 && amount < 0.01 { return "under 1 cent" }
        return String(format: "$%.2f", amount)
    }

    /// A number from the server is never trusted to fit an Int.
    static func wholeSeconds(_ seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int(min(max(seconds, 0), 1_000_000_000))
    }

    static func lengthWords(_ seconds: Double) -> String {
        let total = wholeSeconds(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if minutes > 0 { parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes") }
        if secs > 0 || parts.isEmpty { parts.append(secs == 1 ? "1 second" : "\(secs) seconds") }
        return parts.joined(separator: " ")
    }

    static func clock(_ seconds: Double) -> String {
        let total = wholeSeconds(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%ld:%02ld:%02ld", hours, minutes, secs) }
        return String(format: "%ld:%02ld", minutes, secs)
    }

    /// "1:02:30", "2:30" or "90" as seconds; nil for anything else.
    static func parseClock(_ text: String) -> Double? {
        let pieces = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 3 else { return nil }
        var total = 0.0
        for piece in pieces {
            guard let number = Double(piece.trimmingCharacters(in: .whitespaces)), number >= 0 else { return nil }
            total = total * 60 + number
        }
        return total
    }

    static func bytesWords(_ bytes: Int) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        if gigabytes >= 1 {
            return gigabytes == gigabytes.rounded() ? "\(Int(gigabytes)) GB" : String(format: "%.1f GB", gigabytes)
        }
        return "\(max(1, bytes / 1_048_576)) MB"
    }

    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}

// MARK: - The player
//
// DescribedVideoPlayerSheet lives in DescribedVideoPlayer.swift (Part 291):
// it keeps playing outside the app, has Lock Screen controls, and keeps
// VoiceOver from reading the captions over the film unless she asks.

// MARK: - The transcript

/// One line per swipe. The sheet never changes while it is open.
private struct DescribedTranscriptSheet: View {
    let title: String
    let lines: [String]
    @Environment(\.dismiss) private var dismiss

    init(text: String, title: String) {
        self.title = title
        self.lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .textSelection(.enabled)
                }
            }
            .listStyle(.plain)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityAction(.escape) { dismiss() }
        }
    }
}

// MARK: - A video from Photos

/// DescribeView's `PickedMovie` idiom: the picked video is copied to a file
/// this app owns (the system's copy disappears when the closure returns), and
/// the upload deletes it when it is done. The original name is kept so the
/// same video picked again resumes its upload.
private struct DescribedVideoMovie: Transferable {
    let url: URL
    let originalName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let original = received.file.lastPathComponent
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("kade-described-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy, originalName: original.isEmpty ? "Video from Photos.\(ext)" : original)
        }
    }
}
