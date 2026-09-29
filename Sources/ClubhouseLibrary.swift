import SwiftUI
import AVFoundation
import AVKit

@MainActor
final class ClubhouseLibraryService: ObservableObject {
    @Published private(set) var state = ClubLibraryState()
    @Published private(set) var status = "Choose a recording from the shared library."
    @Published private(set) var connected = false
    @Published private(set) var searching = false
    @Published private(set) var busy = false
    @Published private(set) var items: [ClubLibraryItem] = []
    @Published private(set) var tracks: ClubLibraryTracks?
    @Published private(set) var more = false
    @Published var showPicture = true
    @Published var volume: Double = 0.5 { didSet { player.volume = Float(volume) } }
    let player = AVPlayer()
    var onStarted: (() -> Void)?
    var onChanged: (() -> Void)?
    private let client: KadeAPIClient
    private var proof = ""
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var polling = false
    private var page = 0
    private var mediaID = ""
    private var urlAt = Date.distantPast
    private var lastGood = Date.distantPast
    private var receivedAt = ProcessInfo.processInfo.systemUptime
    private var halfTrip: Double = 0
    private var observer: NSKeyValueObservation?
    private var seeking = false
    private var locallyPaused = false
    private var audioObservers: [NSObjectProtocol] = []

    init(client: KadeAPIClient) {
        self.client = client
        player.volume = 0.5
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        let center = NotificationCenter.default
        audioObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            guard type == .began else { return }
            Task { @MainActor in self?.pauseLocally("Playback was interrupted. Tap Rejoin playback when you are ready.") }
        })
        audioObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            guard reason == .oldDeviceUnavailable else { return }
            Task { @MainActor in self?.pauseLocally("Your audio device disconnected. Tap Rejoin playback to continue.") }
        })
    }

    deinit { for observer in audioObservers { NotificationCenter.default.removeObserver(observer) } }

    private func pauseLocally(_ message: String) {
        guard connected else { return }
        locallyPaused = true
        player.pause()
        status = message
    }

    func rejoin() async {
        locallyPaused = false
        await refresh(forceURL: true)
        synchronize()
    }

    func start(proof: String?) {
        stop()
        guard let proof, !proof.isEmpty else { return }
        self.proof = proof
        connected = true
        lastGood = Date()
        let current = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == current else { return }
                await self.refresh()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        observer = nil; seeking = false
        proof = ""; mediaID = ""; connected = false
        locallyPaused = false
        state = ClubLibraryState(); items = []; tracks = nil
        urlAt = .distantPast
        status = "Choose a recording from the shared library."
    }

    private func request(_ path: String, body: [String: Any]? = nil, retry: Bool = true) async throws -> Data {
        let current = generation
        let components = URLComponents(string: path)
        var request = client.request(path: "api/community/" + (components?.path ?? path), method: body == nil ? "GET" : "POST", authorized: true, queryItems: components?.queryItems)
        request.setValue(proof, forHTTPHeaderField: "X-Clubhouse-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await client.send(request)
        if response.statusCode == 401 && retry {
            let refresh = client.request(path: "api/auth/refresh", method: "POST")
            let (fresh, http) = try await client.send(refresh)
            guard generation == current else { throw CancellationError() }
            struct Token: Decodable { let token: String }
            if http.statusCode == 200, let token = try? JSONDecoder().decode(Token.self, from: fresh) {
                Keychain.set(token.token, for: .accessToken)
                return try await self.request(path, body: body, retry: false)
            }
        }
        guard (200..<300).contains(response.statusCode) else {
            struct ServerError: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(ServerError.self, from: data).error) ?? "The library could not answer. Try again."
            throw RRError(message: message)
        }
        return data
    }

    func search(_ query: String, next: Bool = false) async {
        guard !searching, connected else { return }
        searching = true; defer { searching = false }
        let current = generation
        let wantedPage = next ? page + 1 : 0
        do {
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "page", value: String(wantedPage))]
            let data = try await request("library?" + (components.percentEncodedQuery ?? ""))
            let result = try JSONDecoder().decode(ClubLibrarySearch.self, from: data)
            guard generation == current else { return }
            items = next ? items + result.items : result.items
            more = result.more; page = wantedPage
            status = items.isEmpty ? "No shared recordings matched your search." : "Choose a recording below."
        } catch { if generation == current { status = error.localizedDescription } }
    }

    func choose(_ item: ClubLibraryItem) async {
        let current = generation
        do {
            let result = try JSONDecoder().decode(ClubLibraryTracks.self, from: await request("tracks/" + item.id))
            guard generation == current else { return }
            tracks = result
        } catch { if generation == current { status = error.localizedDescription } }
    }

    func command(_ action: String, extra: [String: Any] = [:]) async {
        guard connected, !busy else { return }
        busy = true; defer { busy = false }
        let current = generation
        do {
            var body: [String: Any] = ["action": action, "revision": state.revision]
            for (key, value) in extra { body[key] = value }
            _ = try await request("playback", body: body)
            guard generation == current else { return }
            if action == "load" || action == "play" { onStarted?() }
            onChanged?()
            await refresh(forceURL: true)
            if action == "load" { status = "Ready. Press Play for everyone when the room is ready." }
        } catch {
            guard generation == current else { return }
            await refresh()
            status = error.localizedDescription
            UIAccessibility.post(notification: .announcement, argument: status)
        }
    }

    func skip(_ seconds: Double) async {
        let position = player.currentTime().seconds
        guard position.isFinite else { return }
        await command("seek", extra: ["position": max(state.begin ?? 0, min(state.end ?? 604800, position + seconds))])
    }

    func refresh(forceURL: Bool = false) async {
        guard connected, !polling else { return }
        polling = true; defer { polling = false }
        let current = generation
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let needsURL = forceURL || mediaID.isEmpty || Date().timeIntervalSince(urlAt) > 1800
            let data = try await request("playback" + (needsURL ? "?url=1" : ""))
            let result = try JSONDecoder().decode(ClubLibraryState.self, from: data)
            guard generation == current else { return }
            lastGood = Date()
            let previous = state
            state = result
            receivedAt = ProcessInfo.processInfo.systemUptime
            halfTrip = (receivedAt - started) / 2
            guard result.active else {
                player.pause(); player.replaceCurrentItem(with: nil); observer = nil; mediaID = ""
                status = result.unavailable == true ? "This room’s recording is unavailable to your account. You can still join the conversation." : "Choose a recording from the shared library."
                return
            }
            if result.mediaID != mediaID || (needsURL && Date().timeIntervalSince(urlAt) > 1800) {
                guard let source = result.url, let url = URL(string: source), url.scheme == "https" else {
                    mediaID = ""; return
                }
                player.pause()
                let item = AVPlayerItem(url: url)
                if let end = result.end { item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600) }
                observer = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    let status = item.status
                    Task { @MainActor in
                        guard let self, self.generation == current else { return }
                        if status == .readyToPlay { self.synchronize() }
                        if status == .failed { self.player.pause(); self.urlAt = .distantPast; self.status = "This recording could not play. Try Rejoin playback." }
                    }
                }
                player.replaceCurrentItem(with: item)
                mediaID = result.mediaID; urlAt = Date(); seeking = false
            }
            synchronize()
            if !locallyPaused && (previous.revision != result.revision || !previous.active) {
                status = (result.playing == true ? "Playing: " : "Paused: ") + (result.title ?? "Library recording")
                UIAccessibility.post(notification: .announcement, argument: status)
            }
        } catch {
            guard generation == current else { return }
            if Date().timeIntervalSince(lastGood) > 10 { player.pause() }
            status = "Playback connection lost. " + error.localizedDescription
        }
    }

    private func synchronize() {
        guard connected, !locallyPaused, state.active, player.currentItem?.status == .readyToPlay, !seeking else { return }
        let target = state.target(after: ProcessInfo.processInfo.systemUptime - receivedAt + halfTrip)
        let position = player.currentTime().seconds
        let play = state.playing == true && (state.end == nil || target < state.end!)
        if position.isFinite && abs(position - target) > (play ? 0.8 : 0.15) {
            seeking = true
            let current = generation
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    self.seeking = false
                    let target = self.state.target(after: ProcessInfo.processInfo.systemUptime - self.receivedAt + self.halfTrip)
                    if !self.locallyPaused && self.state.playing == true && (self.state.end == nil || target < self.state.end!) { self.player.play() } else { self.player.pause() }
                }
            }
        } else if play { player.play() } else { player.pause() }
    }
}

private struct ClubLibraryPicture: UIViewRepresentable {
    let player: AVPlayer
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> Surface {
        let view = Surface(); view.backgroundColor = .black
        view.playerLayer.player = player; view.playerLayer.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ view: Surface, context: Context) { view.playerLayer.player = player }
}

struct ClubhouseLibrarySection: View {
    @ObservedObject var service: ClubhouseLibraryService
    @State private var query = ""
    @State private var choosing = false

    var body: some View {
        if service.connected {
            Section("Watch and listen together") {
                Text(service.status).font(.callout)
                if service.state.active {
                    Text(service.state.title ?? "Library recording").font(.headline)
                    if let title = service.state.trackTitle, !title.isEmpty { Text(title).font(.subheadline) }
                    Text(service.state.controlling == true ? "You control playback for the room." : "\(service.state.hostName ?? "The host") controls playback for the room.")
                        .font(.footnote)
                    if service.state.mime?.hasPrefix("video/") == true {
                        Toggle("Show picture", isOn: $service.showPicture)
                        if service.showPicture {
                            ClubLibraryPicture(player: service.player).aspectRatio(16 / 9, contentMode: .fit).accessibilityHidden(true)
                        }
                    }
                    if service.state.controlling == true {
                        Button(service.state.playing == true ? "Pause for everyone" : "Play for everyone") {
                            Task { await service.command(service.state.playing == true ? "pause" : "play") }
                        }.disabled(service.busy)
                        HStack {
                            Button("Back 30 seconds") { Task { await service.skip(-30) } }
                            Spacer()
                            Button("Ahead 30 seconds") { Task { await service.skip(30) } }
                        }.buttonStyle(.borderless).disabled(service.busy)
                        Button("Stop sharing", role: .destructive) { Task { await service.command("stop") } }.disabled(service.busy)
                    } else if service.state.canTakeControl == true {
                        Button("Take over playback") { Task { await service.command("take-control") } }.disabled(service.busy)
                    }
                    Button("Rejoin playback") { Task { await service.rejoin() } }
                    Slider(value: $service.volume, in: 0...1) { Text("My library media volume") }
                        .accessibilityValue("\(Int(service.volume * 100)) percent")
                    Text("Media volume changes only your ears. Hiding the picture keeps the sound playing.").font(.footnote)
                }
                Button("Choose from the library") { choosing = true }
                    .disabled(service.state.active && service.state.controlling != true)
                Text("Room recordings include the conversation and jukebox. This library player is not included.").font(.footnote)
            }
            .sheet(isPresented: $choosing) {
                NavigationStack {
                    List {
                        Section {
                            TextField("Search shared audio and video", text: $query).onSubmit { Task { await service.search(query) } }
                            Button(service.searching ? "Searching…" : "Search") { Task { await service.search(query) } }.disabled(service.searching)
                            Text(service.status).font(.callout)
                        }
                        if let chosen = service.tracks {
                            Section(chosen.title) {
                                ForEach(chosen.tracks) { track in
                                    Button("Choose \(track.title)") {
                                        Task {
                                            await service.command("load", extra: ["book": chosen.id, "track": track.index])
                                            if service.state.book == chosen.id && service.state.track == track.index { choosing = false }
                                        }
                                    }.disabled(service.busy)
                                }
                            }
                        }
                        Section("Recordings") {
                            ForEach(service.items) { item in
                                Button(item.title) { Task { await service.choose(item) } }
                            }
                            if service.more { Button("More results") { Task { await service.search(query, next: true) } }.disabled(service.searching) }
                        }
                    }
                    .navigationTitle("Play from Library")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { choosing = false } } }
                }
            }
        }
    }
}
