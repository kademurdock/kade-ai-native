import SwiftUI
import AVKit

// MARK: - My Creations + Wall of Fame (session 23)
//
// Kade: "It would be dope if we did most if not all the native port lol."
// These two close out the last user-facing web-only pages: the personal
// gallery of generated media (/my-creations) and the family Wall of Fame
// (/wall-of-fame). Contracts read straight off api/server/routes/kade.js:
//   GET  /api/kade/my-assets            -> { count, assets: [assetView] }
//   POST /api/kade/my-assets/:id/share  -> { ok, shared }   (owner only)
//   GET  /api/kade/wall                 -> assetView + by (first name)
//   GET  /api/kade/asset-download/:id   -> media bytes, Content-Disposition
// Asset URLs are re-signed server-side at read time (freshAssetUrl), so
// AsyncImage can load them with no auth header. Downloads DO need auth --
// they go through the API client and land in a temp file that feeds the
// same ShareSheet the voice-message save path already proved out.

struct KadeAssetItem: Decodable, Identifiable, Equatable {
    let id: String
    let kind: String
    let service: String?
    let url: String
    let backupUrl: String?
    let description: String?
    var shared: Bool
    var archived: Bool?
    let prompt: String?
    let model: String?
    let createdAt: String?
    let by: String?
    /// Part 91.7 — a document's generation-time spoken summary (what the
    /// spreadsheet's columns are, what the totals say). Optional so every
    /// pre-existing asset decodes exactly as before.
    let spoken: String?

    var kindLabel: String {
        switch kind {
        case "video": return "Video"
        case "audio": return "Audio"
        case "document": return "Document"
        default: return "Picture"
        }
    }
    var playable: Bool { kind == "video" || kind == "audio" }
    var bestText: String {
        // A document's spoken summary beats everything: it says what is IN
        // the file, which is the only thing that makes a file real by ear.
        let s = (spoken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { return s }
        let d = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { return d }
        let p = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? "No description" : p
    }
}

@MainActor
final class CreationsService: ObservableObject {
    struct CreationsError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let client: KadeAPIClient
    init(apiClient: KadeAPIClient) { client = apiClient }

    private struct AssetsResponse: Decodable { let assets: [KadeAssetItem] }

    func fetchMine() async throws -> [KadeAssetItem] {
        try await fetch(path: "api/kade/my-assets", fallback: "Couldn't load your creations.", queryItems: [URLQueryItem(name: "includeArchived", value: "1")])
    }

    func fetchWall() async throws -> [KadeAssetItem] {
        try await fetch(path: "api/kade/wall", fallback: "Couldn't load the Wall of Fame.")
    }

    private func fetch(path: String, fallback: String, queryItems: [URLQueryItem]? = nil) async throws -> [KadeAssetItem] {
        let req = client.request(path: path, method: "GET", authorized: true, queryItems: queryItems)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw CreationsError(message: fallback) }
        return try JSONDecoder().decode(AssetsResponse.self, from: data).assets
    }

    func setArchived(id: String, archived: Bool) async throws {
        var req = client.request(path: "api/kade/my-assets/\(id)/archive", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["archived": archived])
        let (_, http) = try await client.send(req)
        guard http.statusCode == 200 else { throw CreationsError(message: "Couldn't update your library. Try again.") }
    }

    func setShared(id: String, shared: Bool) async throws {
        var req = client.request(path: "api/kade/my-assets/\(id)/share", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{\"shared\":\(shared)}".utf8)
        let (_, http) = try await client.send(req)
        guard http.statusCode == 200 else {
            throw CreationsError(message: "Couldn't change sharing. Try again.")
        }
    }

    /// Downloads the media to a temp file named from the server's own
    /// Content-Disposition (falling back to kind-appropriate extensions),
    /// ready for the share sheet's "Save Image" / "Save Video" row.
    func download(asset: KadeAssetItem) async throws -> URL {
        let req = client.request(path: "api/kade/asset-download/\(asset.id)", method: "GET", authorized: true)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200, !data.isEmpty else {
            throw CreationsError(message: "Couldn't fetch that file. Try again.")
        }
        var name = "kade-ai-\(asset.kind)-\(asset.id.prefix(8))"
        var ext = asset.kind == "video" ? "mp4" : (asset.kind == "audio" ? "mp3" : "png")
        if let disp = http.value(forHTTPHeaderField: "Content-Disposition"),
           let range = disp.range(of: "filename=\"") {
            let tail = disp[range.upperBound...]
            if let end = tail.firstIndex(of: "\"") {
                let real = String(tail[..<end])
                let parts = real.split(separator: ".")
                if parts.count >= 2, let last = parts.last {
                    ext = String(last)
                    name = parts.dropLast().joined(separator: ".")
                }
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .appendingPathExtension(ext)
        try data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Shared row + sheet plumbing

/// ONE sheet per view (the DescribeView rule): every presentation both
/// screens can make lives in this enum, driving a single `.sheet(item:)`.
enum CreationSheet: Identifiable {
    case player(URL, String)
    case share(ShareItem)

    var id: String {
        switch self {
        case .player(let url, _): return "player-\(url.absoluteString)"
        case .share(let item): return "share-\(item.id)"
        }
    }
}

/// Full-screen-ish media player for videos and songs. VoiceOver gets the
/// system AVKit controls, which are properly labeled out of the box.
private struct CreationPlayerSheet: View {
    let url: URL
    let title: String
    @State private var player = AVPlayer()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    player.replaceCurrentItem(with: AVPlayerItem(url: url))
                    player.play()
                }
                .onDisappear { player.pause() }
                // The sheet had no way out: a swipe-down is not a VoiceOver
                // gesture and a label on the player hid AVKit's own controls.
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityHint("Stops playing and goes back.")
                    }
                }
                .accessibilityAction(.escape) { dismiss() }
        }
    }
}

private struct CreationRow: View {
    let asset: KadeAssetItem
    let showOwner: Bool
    let onPlay: () -> Void
    let onSave: () -> Void
    let isSaving: Bool
    /// nil on the Wall (only owners toggle sharing).
    let onToggleShare: (() -> Void)?

    private var dateLabel: String {
        guard let createdAt = asset.createdAt else { return "" }
        return KadeDateFormatting.relative(from: createdAt) ?? ""
    }

    private var summary: String {
        var parts: [String] = [asset.kindLabel]
        if showOwner, let by = asset.by { parts.append("by \(by)") }
        if !dateLabel.isEmpty { parts.append(dateLabel) }
        return parts.joined(separator: ", ") + ". " + asset.bestText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The info block is ONE spoken element; the controls below stay
            // their own siblings (the Amber rule -- nothing interactive
            // ever hides inside a flattened element).
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(asset.kindLabel).font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    if showOwner, let by = asset.by {
                        Text("by \(by)").font(.caption).foregroundStyle(.secondary)
                    }
                    if !dateLabel.isEmpty {
                        Text(dateLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if asset.kind == "image", let imageURL = URL(string: asset.url) {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                                .frame(maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        case .failure:
                            EmptyView()
                        default:
                            ProgressView().frame(maxHeight: 60)
                        }
                    }
                    .accessibilityHidden(true)
                }
                Text(asset.bestText)
                    .font(.body)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)

            HStack(spacing: 12) {
                if asset.playable {
                    Button("Play") { onPlay() }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Plays this \(asset.kindLabel.lowercased()) right here.")
                }
                Button {
                    onSave()
                } label: {
                    if isSaving { ProgressView() } else { Text("Save or share") }
                }
                .buttonStyle(.bordered)
                .disabled(isSaving)
                .accessibilityHint(asset.kind == "document"
                    ? "Downloads the file and opens the share sheet — save it to Files, or send it to someone."
                    : "Downloads it and opens the share sheet — Save \(asset.kind == "video" ? "Video" : "Image") puts it in your Photos.")
                if let onToggleShare {
                    Button {
                        onToggleShare()
                    } label: {
                        Text(asset.shared ? "On the Wall" : "Put on the Wall")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Wall of Fame")
                    .accessibilityValue(asset.shared ? "Shared" : "Not shared")
                    .accessibilityHint(asset.shared ? "Takes this off the family Wall of Fame." : "Shares this to the family Wall of Fame.")
                    .accessibilityAddTraits(.isToggle)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - My Creations

struct MyCreationsView: View {
    let apiClient: KadeAPIClient
    @StateObject private var serviceBox: ServiceBox
    @State private var assets: [KadeAssetItem] = []
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var activeSheet: CreationSheet?
    @State private var savingId: String?
    @State private var searchText = ""
    @State private var kindFilter = "all"
    @State private var showArchived = false
    @State private var archivingId: String?
    private var visibleAssets: [KadeAssetItem] {
        assets.filter { asset in
            (showArchived || asset.archived != true) &&
            (kindFilter == "all" || asset.kind == kindFilter) &&
            (searchText.isEmpty || (asset.bestText + " " + (asset.model ?? "")).localizedCaseInsensitiveContains(searchText))
        }
    }

    private enum Focus: Hashable { case status }
    @AccessibilityFocusState private var a11yFocus: Focus?

    /// StateObject wants an ObservableObject; the service is tiny, so a
    /// box keeps one instance alive per view without inventing state.
    @MainActor final class ServiceBox: ObservableObject { let service: CreationsService
        init(service: CreationsService) { self.service = service } }
    private var service: CreationsService { serviceBox.service }

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        _serviceBox = StateObject(wrappedValue: ServiceBox(service: CreationsService(apiClient: apiClient)))
    }

    var body: some View {
        Group {
            if let loadError, assets.isEmpty {
                errorState(loadError)
            } else if assets.isEmpty && hasLoaded {
                VStack(spacing: 8) {
                    Text("Nothing here yet.")
                        .font(.headline)
                    Text("Pictures, videos, and songs you make with your companions land here automatically — ask any of them to draw or film something.")
                        .font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasLoaded {
                ProgressView("Loading your creations…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading your creations")
            } else {
                List {
                    Section("Organize your library") {
                        Toggle("Show archived creations", isOn: $showArchived)
                        Picker("Kind", selection: $kindFilter) {
                            Text("All kinds").tag("all")
                            Text("Audio").tag("audio")
                            Text("Pictures").tag("image")
                            Text("Videos").tag("video")
                            Text("Documents").tag("document")
                        }
                        Text("\(visibleAssets.count) creations shown. Archive hides an item from this library; it keeps the file and its current sharing setting.")
                            .font(.footnote)
                        if let loadError { Text(loadError).foregroundStyle(.red) }
                    }
                    ForEach(visibleAssets) { asset in

                    CreationRow(
                        asset: asset,
                        showOwner: false,
                        onPlay: { play(asset) },
                        onSave: { Task { await save(asset) } },
                        isSaving: savingId == asset.id,
                        onToggleShare: { Task { await toggleShare(asset) } }
                    )
                    Button(asset.archived == true ? "Restore to library" : "Archive") {
                        Task {
                            archivingId = asset.id
                            defer { archivingId = nil }
                            do {
                                let archived = asset.archived != true
                                try await service.setArchived(id: asset.id, archived: archived)
                                if let index = assets.firstIndex(where: { $0.id == asset.id }) { assets[index].archived = archived }
                                loadError = nil
                                UIAccessibility.post(notification: .announcement, argument: archived ? "Archived. Use Show archived creations to restore it." : "Restored to library.")
                            } catch {
                                loadError = error.localizedDescription
                                UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
                            }
                        }
                    }
                    .disabled(archivingId != nil)
                    .accessibilityLabel("\(asset.archived == true ? "Restore" : "Archive") \(asset.bestText)")
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await reload()
                    KadeHaptics.tap()
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search your creations")
        .navigationTitle("My Creations")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !hasLoaded else { return }
            await reload()
            hasLoaded = true
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .player(let url, let title):
                CreationPlayerSheet(url: url, title: title)
            case .share(let item):
                ShareSheet(item: item)
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .multilineTextAlignment(.center)
                .accessibilityFocused($a11yFocus, equals: .status)
            Button("Try again") { Task { await reload() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { a11yFocus = .status }
    }

    private func reload() async {
        do {
            assets = try await service.fetchMine()
            loadError = nil
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "Couldn't load your creations."
        }
    }

    private func play(_ asset: KadeAssetItem) {
        guard let url = URL(string: asset.url) else { return }
        activeSheet = .player(url, asset.kindLabel)
    }

    private func save(_ asset: KadeAssetItem) async {
        guard savingId == nil else { return }
        savingId = asset.id
        defer { savingId = nil }
        do {
            let fileURL = try await service.download(asset: asset)
            Earcons.shared.play(.actionDone)
            KadeHaptics.success()
            activeSheet = .share(ShareItem(fileURL: fileURL))
        } catch {
            Earcons.shared.play(.error)
            KadeHaptics.error()
            UIAccessibility.post(
                notification: .announcement,
                argument: (error as? LocalizedError)?.errorDescription ?? "Couldn't fetch that file. Try again."
            )
        }
    }

    private func toggleShare(_ asset: KadeAssetItem) async {
        let target = !asset.shared
        do {
            try await service.setShared(id: asset.id, shared: target)
            if let idx = assets.firstIndex(where: { $0.id == asset.id }) {
                assets[idx].shared = target
            }
            Earcons.shared.play(.actionDone)
            KadeHaptics.success()
            UIAccessibility.post(
                notification: .announcement,
                argument: target ? "Shared to the Wall of Fame." : "Taken off the Wall of Fame."
            )
        } catch {
            Earcons.shared.play(.error)
            KadeHaptics.error()
            UIAccessibility.post(notification: .announcement, argument: "Couldn't change sharing. Try again.")
        }
    }
}

// MARK: - Wall of Fame

struct WallOfFameView: View {
    let apiClient: KadeAPIClient
    @StateObject private var serviceBox: MyCreationsView.ServiceBox
    @State private var assets: [KadeAssetItem] = []
    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var activeSheet: CreationSheet?
    @State private var savingId: String?

    private enum Focus: Hashable { case status }
    @AccessibilityFocusState private var a11yFocus: Focus?
    private var service: CreationsService { serviceBox.service }

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        _serviceBox = StateObject(wrappedValue: MyCreationsView.ServiceBox(service: CreationsService(apiClient: apiClient)))
    }

    var body: some View {
        Group {
            if let loadError, assets.isEmpty {
                VStack(spacing: 12) {
                    Text(loadError)
                        .multilineTextAlignment(.center)
                        .accessibilityFocused($a11yFocus, equals: .status)
                    Button("Try again") { Task { await reload() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { a11yFocus = .status }
            } else if assets.isEmpty && hasLoaded {
                VStack(spacing: 8) {
                    Text("The Wall is empty so far.")
                        .font(.headline)
                    Text("When anyone in the family puts a creation on the Wall, everyone sees it here.")
                        .font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasLoaded {
                ProgressView("Loading the Wall of Fame…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading the Wall of Fame")
            } else {
                List(assets) { asset in
                    CreationRow(
                        asset: asset,
                        showOwner: true,
                        onPlay: { play(asset) },
                        onSave: { Task { await save(asset) } },
                        isSaving: savingId == asset.id,
                        onToggleShare: nil
                    )
                }
                .listStyle(.plain)
                .refreshable {
                    await reload()
                    KadeHaptics.tap()
                }
            }
        }
        .navigationTitle("Wall of Fame")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !hasLoaded else { return }
            await reload()
            hasLoaded = true
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .player(let url, let title):
                CreationPlayerSheet(url: url, title: title)
            case .share(let item):
                ShareSheet(item: item)
            }
        }
    }

    private func reload() async {
        do {
            assets = try await service.fetchWall()
            loadError = nil
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "Couldn't load the Wall of Fame."
        }
    }

    private func play(_ asset: KadeAssetItem) {
        guard let url = URL(string: asset.url) else { return }
        activeSheet = .player(url, asset.kindLabel)
    }

    private func save(_ asset: KadeAssetItem) async {
        guard savingId == nil else { return }
        savingId = asset.id
        defer { savingId = nil }
        do {
            let fileURL = try await service.download(asset: asset)
            Earcons.shared.play(.actionDone)
            KadeHaptics.success()
            activeSheet = .share(ShareItem(fileURL: fileURL))
        } catch {
            Earcons.shared.play(.error)
            KadeHaptics.error()
            UIAccessibility.post(
                notification: .announcement,
                argument: (error as? LocalizedError)?.errorDescription ?? "Couldn't fetch that file. Try again."
            )
        }
    }
}
