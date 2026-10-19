import SwiftUI
import UIKit

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

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        _service = ObservedObject(wrappedValue: ArcadeService.shared(apiClient: apiClient))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Old console games made to play by ear: the game's own sounds placed around you, and its menus read aloud. Play by touch with VoiceOver on, or with a keyboard or a game controller.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                gamesSection

                if let lastReport {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            UIPasteboard.general.string = lastReport
                            UIAccessibility.post(notification: .announcement, argument: "Test report copied. Paste it to Claude.")
                        } label: {
                            Label("Copy test report", systemImage: "doc.on.clipboard")
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
            ArcadeGameView(launch: launch) { report in
                lastReport = report
                playing = nil
            }
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

    /// Greyed, never hidden: the reason is part of the spoken label (heard even
    /// with VoiceOver hints off, as the Library's greyed local row does) and
    /// shown beneath it; the caption is the hint.
    private func greyedRow(title: String, caption: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {} label: {
                Label(title, systemImage: "lock.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(KadeCardButtonStyle())
            .labelStyle(KadeRowLabelStyle(tint: .gray, caption: caption))
            .disabled(true)
            .accessibilityLabel("\(title), \(reason)")
            .accessibilityHint(caption)
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private func caption(_ entry: ArcadeCatalogEntry) -> String {
        var parts: [String] = []
        if let console = entry.console { parts.append(console) }
        if let size = entry.size { parts.append(ArcadeText.size(size)) }
        return parts.isEmpty ? "A classic game" : parts.joined(separator: ", ")
    }

    private func playableRow(_ entry: ArcadeCatalogEntry) -> some View {
        let installedVersion = service.installed[entry.id]
        let isInstalled = installedVersion != nil
        let isDownloading = service.downloading == entry.id
        let needsUpdate = isInstalled && installedVersion != entry.version
        return VStack(alignment: .leading, spacing: 8) {
            if isInstalled {
                Button { play(entry) } label: {
                    Label(entry.title, systemImage: "gamecontroller.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(KadeCardButtonStyle())
                .labelStyle(KadeRowLabelStyle(tint: .purple, caption: caption(entry) + (needsUpdate ? ", update ready" : ", downloaded")))
                .accessibilityLabel("Play \(entry.title)")
                .accessibilityValue(needsUpdate ? "Downloaded. An update is ready." : "Downloaded")
                .accessibilityHint(entry.summary ?? "Opens the game full screen.")
                .accessibilityAction(named: "Delete download") { deleteDownload(entry) }
                .contextMenu {
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
                    Button("Stop download") { service.cancelDownload() }
                        .buttonStyle(KadeCardButtonStyle())
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
