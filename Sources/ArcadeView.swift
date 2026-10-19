import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// THE ARCADE (Oct 18 2026): classic games, playable by ear. Play tab, Arcade.
///
/// - Family games are visible but greyed outside the Family feature pack, with
///   KadeFamilyFeatures.note beside them, never hidden. For an account outside
///   the pack (the App Review seat included) every family game folds into ONE
///   greyed "Family shelf" row that names no game.
/// - A game downloads once (size said before anything starts, and asked
///   about), with progress spoken at 25, 50 and 75 percent while this screen
///   is open. The download belongs to the app session (ArcadeService.shared),
///   not to this screen: leaving and coming back finds it still going, with
///   its Stop button, and its end is spoken wherever she is. The Actions rotor
///   on a downloaded game has Delete download.
/// - Play opens the game in one full-screen cover (ArcadeGameView). A phone
///   call comes first.
/// - Oct 19 2026, her decision: in every build, the public App Store one
///   included. The screen says plainly what the Arcade is and who each shelf
///   is for (App Store 2.5.19: nothing hidden or undocumented). A greyed row
///   says its reason first and never downloads or launches (4.7.5). Every
///   playable game has "Report a problem with this game" in its Actions
///   rotor and long-press menu, and the game's Settings sheet has it too
///   (4.7.1); the foot of the screen reports a problem with the Arcade.
/// - Oct 19 2026, her decision ("People can add roms to the arcade for their
///   own personal use"): My games, for every account. Add a game opens Files
///   for an NES, Game Boy, Game Boy Color, Game Boy Advance or N64 file, or a
///   zip holding one; it stays on this iPhone and is never uploaded. Each row
///   says its accessibility pack status (or why the pack is locked) first,
///   and has Play, Rename, Delete (asked first) and Report a problem.
struct ArcadeView: View {
    let apiClient: KadeAPIClient
    @ObservedObject private var service: ArcadeService
    @State private var playing: ArcadeLaunch?
    @State private var offer: ArcadeDownloadOffer?
    @State private var checking: String?
    @State private var problem: String?
    @State private var waitingForCall = false
    @State private var lastReport: String?
    @State private var speaker = ArcadeProgressSpeaker()
    @State private var reporting: ArcadeReportTarget?
    // My games (Oct 19 2026)
    @State private var showImporter = false
    @State private var importOffer: ArcadeImportOffer?
    @State private var importProblem: String?
    @State private var checkingImport: String?
    @State private var renaming: ArcadeImportRecord?
    @State private var renameText = ""
    @State private var deleting: ArcadeImportRecord?

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        _service = ObservedObject(wrappedValue: ArcadeService.shared(apiClient: apiClient))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Oct 19 2026: what the Arcade is, in plain words, first on
                // the screen (App Store 2.5.19). No game is named.
                Text(ArcadeShelf.about)
                    .font(.body)
                Text("The game's own sounds are placed around you, and its menus are read aloud. Play by touch with VoiceOver on, or with a keyboard or a game controller.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                myGamesSection

                gamesSection

                if let lastReport {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            UIPasteboard.general.string = lastReport
                            UIAccessibility.post(notification: .announcement, argument: "Copied.")
                        } label: {
                            Label("Copy how the game ran", systemImage: "doc.on.clipboard")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(KadeCardButtonStyle())
                        Text("From your last game: how it ran on this iPhone. No account details.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Before you play")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("Wired headphones are best. In the VoiceOver rotor, turn Audio Ducking off so VoiceOver does not lower the game.")
                    Text("In the game, the strip at the top has Leave game, Pause, Status, Repeat and Settings. Everything below it is the game pad: double-tap it once, then touches go to the game.")
                }
                .font(.callout)

                // Oct 19 2026 (App Store 4.7.1): always on screen, so a report
                // is possible even before any game is downloaded.
                VStack(alignment: .leading, spacing: 6) {
                    Button { reporting = .arcade } label: {
                        Label(ArcadeReport.arcadeActionName, systemImage: "exclamationmark.bubble")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(KadeCardButtonStyle())
                    .accessibilityHint("Tell Kade what went wrong. Each game also has Report a problem with this game in its Actions rotor.")
                    Text("For one game, use Report a problem with this game in its Actions rotor, its long-press menu, or the game's Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding()
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Arcade")
        .navigationBarTitleDisplayMode(.inline)
        // Every visit asks again: the service outlives this screen, and the
        // shelf is this account's answer of the moment.
        .task { await service.load() }
        .refreshable { await service.load() }
        .onChange(of: service.progress) { _, value in
            guard service.downloading != nil, let step = speaker.next(fraction: value) else { return }
            UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
                string: "\(step) percent", attributes: [.accessibilitySpeechQueueAnnouncement: NSNumber(value: true)]))
        }
        .alert(offer.map { "Download \($0.entry.title)?" } ?? "Download?",
               isPresented: Binding(get: { offer != nil }, set: { if !$0 { offer = nil } }),
               presenting: offer) { pending in
            Button("Download") { startDownload(pending) }
            Button("Not now", role: .cancel) {}
        } message: { pending in
            Text(offerMessage(pending))
        }
        .alert("Not yet", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: {
            Text(problem ?? "")
        }
        .alert("You're on a call", isPresented: $waitingForCall) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The Arcade waits until the call ends.")
        }
        .fullScreenCover(item: $playing, onDismiss: { service.stoppedPlaying() }) { launch in
            ArcadeGameView(launch: launch, apiClient: apiClient) { report in
                lastReport = report
                playing = nil
            }
        }
        .sheet(item: $reporting) { target in
            ArcadeReportView(apiClient: apiClient, target: target,
                             place: target.gameId.isEmpty ? "Arcade screen"
                                 : (target.gameId.hasPrefix("import-") ? "My games" : "Arcade list"))
        }
    }

    // MARK: Rows

    @ViewBuilder
    private var gamesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Games")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if service.loading && service.shelf == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Opening the Arcade")
                }
                .accessibilityElement(children: .combine)
            }
            if let error = service.loadError {
                Text(error)
                    .foregroundStyle(.secondary)
                Button("Try again") { Task { await service.load() } }
                    .buttonStyle(KadeCardButtonStyle())
            }
            if let message = service.shelf?.message {
                Text(message).font(.callout)
            }
            if let rows = service.shelf?.rows {
                ForEach(rows) { row in
                    rowView(row)
                }
                if !ArcadeShelf.hasPublicGame(rows) {
                    Text(ArcadeShelf.noPublicGames)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ArcadeShelfRow) -> some View {
        switch row {
        case .playable(let entry):
            playableRow(entry)
        case .locked(let entry, let reason):
            greyedRow(title: entry.title, caption: caption(entry), reason: reason)
        case .familyShelf(let reason):
            greyedRow(title: ArcadeShelf.shelfTitle, caption: "Classic games for the family", reason: reason)
        }
    }

    /// Greyed, never hidden: the reason is part of the spoken label, FIRST
    /// (heard even with VoiceOver hints off), and shown beneath it; the
    /// caption is the hint. The button does nothing and is disabled, and it
    /// has no actions: nothing about a locked game downloads or launches.
    private func greyedRow(title: String, caption: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {} label: {
                Label(title, systemImage: "lock.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(KadeCardButtonStyle())
            .labelStyle(KadeRowLabelStyle(tint: .gray, caption: caption))
            .disabled(true)
            .accessibilityLabel(ArcadeShelf.lockedLabel(title: title, reason: reason))
            .accessibilityHint(caption)
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    /// Grown-ups only first when the catalog says so (App Store 4.7.5).
    private func caption(_ entry: ArcadeCatalogEntry) -> String {
        ArcadeShelf.caption(entry)
    }

    private func playableRow(_ entry: ArcadeCatalogEntry) -> some View {
        let installedVersion = service.installed[entry.id]
        let isInstalled = installedVersion != nil
        let isDownloading = service.downloading == entry.id
        let needsUpdate = isInstalled && installedVersion != entry.version
        let downloaded: String = needsUpdate ? "Downloaded. An update is ready." : "Downloaded"
        let playValue: String = entry.grownUpsOnly ? ArcadeShelf.grownUpsOnly + ". " + downloaded : downloaded
        return VStack(alignment: .leading, spacing: 8) {
            if isInstalled {
                Button { play(entry) } label: {
                    Label(entry.title, systemImage: "gamecontroller.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(KadeCardButtonStyle())
                .labelStyle(KadeRowLabelStyle(tint: .purple, caption: caption(entry) + (needsUpdate ? ", update ready" : ", downloaded")))
                .accessibilityLabel("Play \(entry.title)")
                .accessibilityValue(playValue)
                .accessibilityHint(entry.summary ?? "Opens the game full screen.")
                .accessibilityAction(named: "Delete download") { deleteDownload(entry) }
                .accessibilityAction(named: ArcadeReport.actionName) { report(entry) }
                .contextMenu {
                    Button { report(entry) } label: {
                        Label(ArcadeReport.actionName, systemImage: "exclamationmark.bubble")
                    }
                    Button(role: .destructive) { deleteDownload(entry) } label: {
                        Label("Delete download", systemImage: "trash")
                    }
                }
            }
            if isDownloading {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: service.progress)
                        .accessibilityLabel("Downloading \(entry.title)")
                        .accessibilityValue(service.verifying ? "Checking the download" : "\(Int(service.progress * 100)) percent")
                    // A download going wrong can be reported while it runs.
                    Button("Stop download") { service.cancelDownload() }
                        .buttonStyle(KadeCardButtonStyle())
                        .accessibilityAction(named: ArcadeReport.actionName) { report(entry) }
                        .contextMenu {
                            Button { report(entry) } label: {
                                Label(ArcadeReport.actionName, systemImage: "exclamationmark.bubble")
                            }
                        }
                }
            } else if !isInstalled || needsUpdate {
                Button { askToDownload(entry) } label: {
                    Label(checking == entry.id ? "Checking the size" : (needsUpdate ? "Download the update" : "Download \(entry.title)"),
                          systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(KadeCardButtonStyle())
                .labelStyle(KadeRowLabelStyle(tint: .purple, caption: caption(entry)))
                .disabled(checking != nil || service.downloading != nil)
                .accessibilityHint("Says the size and asks before anything downloads.")
                .accessibilityAction(named: ArcadeReport.actionName) { report(entry) }
                .contextMenu {
                    Button { report(entry) } label: {
                        Label(ArcadeReport.actionName, systemImage: "exclamationmark.bubble")
                    }
                }
            }
            if let error = service.downloadErrors[entry.id] {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    private func askToDownload(_ entry: ArcadeCatalogEntry) {
        guard checking == nil else { return }
        checking = entry.id
        Task {
            defer { checking = nil }
            do {
                let next = try await service.offer(for: entry)
                if next.bytes <= 0 {
                    startDownload(next)
                } else {
                    offer = next
                }
            } catch {
                problem = (error as? ArcadeServiceError)?.message ?? "The game's size could not be checked. Try again."
            }
        }
    }

    /// The version on this iPhone when there is one, else the catalog's.
    private func report(_ entry: ArcadeCatalogEntry) {
        reporting = ArcadeReportTarget(gameId: entry.id, title: entry.title,
                                       version: service.installed[entry.id] ?? entry.version)
    }

    private func deleteDownload(_ entry: ArcadeCatalogEntry) {
        service.delete(entry)
        UIAccessibility.post(notification: .announcement, argument: "Deleted the download of \(entry.title).")
    }

    private func offerMessage(_ offer: ArcadeDownloadOffer) -> String {
        "\(ArcadeText.size(offer.bytes)). Wi-Fi is best. It stays on this iPhone, is not backed up, and you can delete it any time from the Actions rotor."
    }

    private func startDownload(_ offer: ArcadeDownloadOffer) {
        speaker.reset()
        UIAccessibility.post(notification: .announcement, argument: "Downloading \(offer.entry.title).")
        service.startDownload(offer)
    }

    private func play(_ entry: ArcadeCatalogEntry) {
        guard service.isPlayable(entry) else {
            problem = ArcadeService.notOpenHere
            return
        }
        guard ArcadeAudioGuard.check() == .clear else {
            waitingForCall = true
            return
        }
        guard let launch = service.launch(for: entry) else {
            problem = "The download is incomplete. Delete it from the Actions rotor and download it again."
            return
        }
        service.willPlay(launch)
        playing = launch
    }
}

// MARK: - My games (Oct 19 2026)

extension ArcadeView {
    /// What Files offers. No type is declared by the app (project.yml stays
    /// as it is): the types come from the extensions at run time, plus .zip,
    /// and .data so a game file whose extension this iPhone does not know can
    /// still be picked. Anything else picked is refused with its reason.
    private static let importTypes: [UTType] = {
        var types: [UTType] = []
        for ext in ArcadeSystem.romExtensions {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        types.append(.zip)
        types.append(.data)
        return types
    }()

    private var myGamesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("My games")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(ArcadeImportText.about)
                .font(.callout)
                .foregroundStyle(.secondary)
            addGameButton
            ForEach(service.imports) { record in
                importRow(record)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                addGame(url)
            case .failure:
                importProblem = "Files could not hand over that file. Try again."
            }
        }
        .modifier(ArcadeImportAlerts(offer: $importOffer, problem: $importProblem, renaming: $renaming,
                                     renameText: $renameText, deleting: $deleting,
                                     offerMessage: { importOfferMessage($0) },
                                     download: { startImportDownload($0) },
                                     rename: { rename($0) },
                                     delete: { deleteImport($0) }))
    }

    private var addGameButton: some View {
        Button { showImporter = true } label: {
            Label(service.adding.map { "Adding \($0)" } ?? "Add a game", systemImage: "plus.circle.fill")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(KadeCardButtonStyle())
        .labelStyle(KadeRowLabelStyle(tint: .teal, caption: "From Files, kept on this iPhone"))
        .disabled(service.adding != nil)
        .accessibilityLabel(service.adding == nil ? "Add a game" : "Adding the game")
        .accessibilityHint("Opens Files. Pick a game file you own, or a zip holding one. It stays on this iPhone and is never uploaded.")
    }

    /// The status (or the locked reason) is said FIRST, then the title; the
    /// system is the value. Play is the button; Rename, Delete and Report a
    /// problem are in the Actions rotor and the long-press menu.
    private func importRow(_ record: ArcadeImportRecord) -> some View {
        let status = service.importStatus[record.localId] ?? .unchecked
        let key = ArcadeImportText.downloadKey(record.localId)
        let isDownloading = service.downloading == key
        return VStack(alignment: .leading, spacing: 8) {
            Button { playImport(record) } label: {
                Label(record.title, systemImage: status == .pack ? "gamecontroller.fill" : "gamecontroller")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(KadeCardButtonStyle())
            .labelStyle(KadeRowLabelStyle(tint: .teal, caption: record.system.name + ", " + status.words))
            .accessibilityLabel(ArcadeImportText.rowLabel(title: record.title, status: status))
            .accessibilityValue(record.system.name)
            .accessibilityHint("Plays it full screen. The Actions rotor has Rename, Delete and Report a problem.")
            .accessibilityAction(named: "Rename") { startRename(record) }
            .accessibilityAction(named: "Delete") { deleting = record }
            .accessibilityAction(named: ArcadeReport.actionName) { reportImport(record) }
            .accessibilityAction(named: "Check for an accessibility pack") { recheck(record) }
            .contextMenu {
                Button { playImport(record) } label: { Label("Play", systemImage: "play.fill") }
                Button { startRename(record) } label: { Label("Rename", systemImage: "pencil") }
                Button { recheck(record) } label: { Label("Check for an accessibility pack", systemImage: "arrow.clockwise") }
                Button { reportImport(record) } label: { Label(ArcadeReport.actionName, systemImage: "exclamationmark.bubble") }
                Button(role: .destructive) { deleting = record } label: { Label("Delete", systemImage: "trash") }
            }
            if isDownloading {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: service.progress)
                        .accessibilityLabel("Downloading for \(record.title)")
                        .accessibilityValue(service.verifying ? "Checking the download" : "\(Int(service.progress * 100)) percent")
                    Button("Stop download") { service.cancelDownload() }
                        .buttonStyle(KadeCardButtonStyle())
                }
            } else if status.isPackReady {
                Button { askImportDownload(record, withPack: true) } label: {
                    Label(checkingImport == record.localId ? "Checking the size" : "Download the accessibility pack",
                          systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(KadeCardButtonStyle())
                .labelStyle(KadeRowLabelStyle(tint: .teal, caption: record.title))
                .disabled(checkingImport != nil || service.downloading != nil)
                .accessibilityHint("Says the size and asks before anything downloads. Without it the game plays as the original.")
            }
            if let error = service.downloadErrors[key] {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: My games actions

    private func addGame(_ url: URL) {
        UIAccessibility.post(notification: .announcement, argument: "Adding \(url.lastPathComponent).")
        Task {
            switch await service.addGame(from: url) {
            case .failure(let problem):
                importProblem = problem.spoken
            case .success(let added):
                let status = service.importStatus[added.record.localId] ?? .unchecked
                let first = added.already
                    ? "\(added.record.title) is already in My games."
                    : "Added \(added.record.title), \(added.record.system.name)."
                UIAccessibility.post(notification: .announcement, argument: first + " " + status.words + ".")
                if status.isPackReady && service.downloading == nil { askImportDownload(added.record, withPack: true) }
            }
        }
    }

    /// The size first, then the question (or straight on when nothing is missing).
    private func askImportDownload(_ record: ArcadeImportRecord, withPack: Bool) {
        guard checkingImport == nil else { return }
        checkingImport = record.localId
        Task {
            defer { checkingImport = nil }
            do {
                let next = try await service.importOffer(for: record.localId, withPack: withPack)
                if next.bytes <= 0 {
                    startImportDownload(next)
                } else {
                    importOffer = next
                }
            } catch {
                importProblem = (error as? ArcadeServiceError)?.message
                    ?? "The size could not be checked. Check the connection and try again."
            }
        }
    }

    private func importOfferMessage(_ offer: ArcadeImportOffer) -> String {
        let size = ArcadeText.size(offer.bytes)
        if offer.accessPack != nil {
            return "\(size), for \(offer.record.title): the voices, sounds and words that make it playable by ear. The game itself stays your own file. Wi-Fi is best."
        }
        return "\(size), once, for every game you add: the player that runs them. Wi-Fi is best. It stays on this iPhone and is not backed up."
    }

    private func startImportDownload(_ offer: ArcadeImportOffer) {
        speaker.reset()
        UIAccessibility.post(notification: .announcement,
                             argument: offer.accessPack == nil ? "Downloading the player." : "Downloading the accessibility pack.")
        service.startImportDownload(offer)
    }

    private func playImport(_ record: ArcadeImportRecord) {
        guard ArcadeAudioGuard.check() == .clear else {
            waitingForCall = true
            return
        }
        switch service.importLaunch(record.localId) {
        case .ready(let launch):
            service.willPlay(launch)
            playing = launch
        case .needsPlayer:
            askImportDownload(record, withPack: false)
        case .problem(let message):
            importProblem = message
        }
    }

    private func startRename(_ record: ArcadeImportRecord) {
        renameText = record.title
        renaming = record
    }

    private func rename(_ record: ArcadeImportRecord) {
        if service.renameImport(record.localId, to: renameText) {
            UIAccessibility.post(notification: .announcement, argument: "Renamed.")
        } else {
            importProblem = "That name is empty, so the game keeps its old one."
        }
    }

    private func deleteImport(_ record: ArcadeImportRecord) {
        service.deleteImport(record.localId)
        UIAccessibility.post(notification: .announcement, argument: "Deleted \(record.title).")
    }

    private func reportImport(_ record: ArcadeImportRecord) {
        reporting = ArcadeImportPlay.reportTarget(record)
    }

    private func recheck(_ record: ArcadeImportRecord) {
        Task {
            let status = await service.recheckImport(record.localId)
            UIAccessibility.post(notification: .announcement, argument: (status ?? .unchecked).words + ".")
        }
    }
}

/// My games' questions, kept apart so the Arcade screen's own alerts stay as they were.
private struct ArcadeImportAlerts: ViewModifier {
    @Binding var offer: ArcadeImportOffer?
    @Binding var problem: String?
    @Binding var renaming: ArcadeImportRecord?
    @Binding var renameText: String
    @Binding var deleting: ArcadeImportRecord?
    let offerMessage: (ArcadeImportOffer) -> String
    let download: (ArcadeImportOffer) -> Void
    let rename: (ArcadeImportRecord) -> Void
    let delete: (ArcadeImportRecord) -> Void

    private var offerTitle: String {
        guard let offer else { return "Download?" }
        return offer.accessPack == nil ? "Download the player?" : "Download the accessibility pack?"
    }

    private var deleteTitle: String {
        deleting.map { "Delete \($0.title)?" } ?? "Delete?"
    }

    func body(content: Content) -> some View {
        content
            .alert(offerTitle, isPresented: Binding(get: { offer != nil }, set: { if !$0 { offer = nil } }),
                   presenting: offer) { pending in
                Button("Download") { download(pending) }
                Button("Not now", role: .cancel) {}
            } message: { pending in
                Text(offerMessage(pending))
            }
            .alert("My games", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) { problem = nil }
            } message: {
                Text(problem ?? "")
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                   presenting: renaming) { record in
                TextField("Name", text: $renameText)
                Button("Save") { rename(record) }
                Button("Cancel", role: .cancel) {}
            } message: { record in
                Text("A new name for \(record.title). It changes only in My games.")
            }
            .alert(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                   presenting: deleting) { record in
                Button("Delete", role: .destructive) { delete(record) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The game file is removed from this iPhone. Its saves stay, in case you add it again.")
            }
    }
}
