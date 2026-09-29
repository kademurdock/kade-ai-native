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
    /// The revision she last heard announced (Sep 29 2026). Compared instead
    /// of the previous poll's revision, so a change first seen while its
    /// link was still on the way, or while she was paused here, is still
    /// said once her phone follows it.
    private var announced: Int?
    /// Failed loads of the current recording; one fresh link, then stop.
    private var loads = ClubLoadFailures()
    /// A poll has failed since the last good one.
    private var troubled = false
    /// "Playback connection lost" was already said for this outage.
    private var lostAnnounced = false

    init(client: KadeAPIClient) {
        self.client = client
        player.volume = 0.5
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        // Sep 29 2026: the default .automatic policy pauses a player showing a
        // picture when the phone locks or she leaves the app, so a shared
        // video went silent for her while the room played on. Same fix as
        // DescribedVideoPlayer.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
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

    /// Status lines she has to hear, not only find (Sep 29 2026).
    private func announce(_ text: String) {
        status = text
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func pauseLocally(_ message: String) {
        // Nothing shared means nothing to pause, and nothing to Rejoin.
        guard connected, state.active else { return }
        locallyPaused = true
        player.pause()
        announce(message)
    }

    func rejoin() async {
        locallyPaused = false
        // Sep 29 2026: Rejoin says where the room is, and a recording that
        // gave up after failing to load gets a fresh link.
        announced = nil; loads.reset()
        if player.currentItem?.status == .failed { urlAt = .distantPast }
        await refresh(forceURL: true)
        synchronize()
    }

    /// Sep 29 2026: one fresh link after a failed load, then stop and say
    /// so. Before, a file that could never play was signed again and
    /// downloaded again every 2 seconds for as long as she stayed.
    private func loadFailed() {
        player.pause()
        switch loads.failed(at: Date()) {
        case .retry: urlAt = .distantPast
        case .giveUp: announce("This recording could not play. Try Rejoin playback.")
        case .quiet: break
        }
    }

    private func loadReady() {
        // Sep 29 2026: a recording that had given up but then loaded after
        // all (the half-hourly fresh link) says so, so the failure notice
        // does not linger while it plays.
        if loads.ready(at: Date()) && !locallyPaused && state.active {
            announced = state.revision
            announce(state.playbackLine())
        }
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
                // Waits in half-second steps and reads the delay again each
                // step, so a share that starts during a 10-second wait moves
                // to the 2-second pace straight away.
                var waited: UInt64 = 0
                repeat {
                    do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                    waited += 500_000_000
                } while self.generation == current && waited < self.pollDelay
            }
        }
    }

    /// Sep 29 2026: every app request queues at KadeAPIClient's 1.5 s pacing
    /// gate, so polling every 2 s with nothing shared made house voices and
    /// bot calls wait behind it. The poll keeps 2 s while a recording is
    /// shared or her load or seek is under way, and slows to 10 s otherwise.
    /// Her own commands, a library-changed message from the room and coming
    /// back to the app still refresh at once (refresh(forceURL: true)).
    private var pollDelay: UInt64 {
        (state.active || busy || seeking) ? 2_000_000_000 : 10_000_000_000
    }

    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        observer = nil; seeking = false
        proof = ""; mediaID = ""; connected = false
        locallyPaused = false
        announced = nil; loads.reset(); troubled = false; lostAnnounced = false
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
            announce(ClubLibrarySearch.statusLine(count: items.count))
        } catch { if generation == current { announce(error.localizedDescription) } }
    }

    func choose(_ item: ClubLibraryItem) async {
        let current = generation
        do {
            let result = try JSONDecoder().decode(ClubLibraryTracks.self, from: await request("tracks/" + item.id))
            guard generation == current else { return }
            tracks = result
            announce(result.readyLine)
        } catch { if generation == current { announce(error.localizedDescription) } }
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
            // Sep 29 2026: her own play, seek or load brings her own phone
            // along. After a local pause the room used to follow her command
            // while she stayed silent.
            if action == "load" || action == "play" || action == "seek" {
                locallyPaused = false
                // ...and a recording that failed to load gets a fresh link,
                // as Rejoin does, instead of staying silent under her command.
                if player.currentItem?.status == .failed { loads.reset(); urlAt = .distantPast }
            }
            if action == "load" || action == "play" { onStarted?() }
            onChanged?()
            await refresh(forceURL: true)
            if action == "load" { status = "Ready. Press Play for everyone when the room is ready." }
        } catch {
            guard generation == current else { return }
            await refresh()
            announce(error.localizedDescription)
        }
    }

    func skip(_ seconds: Double) async {
        // Sep 29 2026: from the room's timeline, not this phone's player. Its
        // clock stops at a local pause, a stall or a failed load, and Back 30
        // from a player stuck at 12:00 would pull a room at 20:00 back to 11:30.
        guard state.active else { return }
        let position = state.skipTarget(by: seconds, after: ProcessInfo.processInfo.systemUptime - receivedAt + halfTrip)
        guard position.isFinite else { return }
        await command("seek", extra: ["position": position])
    }

    func refresh(forceURL: Bool = false) async {
        guard connected else { return }
        if polling {
            // Sep 29 2026: a forced refresh (her own command, a
            // library-changed message, coming back to the app) was dropped
            // whenever the regular poll was in flight. Wait for that poll to
            // land, then fetch again.
            guard forceURL else { return }
            let asked = generation
            while polling && connected && generation == asked {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
            guard connected, generation == asked, !polling else { return }
        }
        polling = true; defer { polling = false }
        let current = generation
        // Sep 29 2026: start the clock after the app-wide pacing gate. Right
        // after one of her own commands that gate waits up to 1.5 s; counted
        // as network delay it put her up to 0.7 s ahead of the room, just
        // inside the 0.8 s the drift check lets pass, so it stayed.
        let started = ProcessInfo.processInfo.systemUptime + client.pacingWaitRemaining
        do {
            let needsURL = forceURL || mediaID.isEmpty || Date().timeIntervalSince(urlAt) > 1800
            let data = try await request("playback" + (needsURL ? "?url=1" : ""))
            let result = try JSONDecoder().decode(ClubLibraryState.self, from: data)
            guard generation == current else { return }
            lastGood = Date()
            let recovered = troubled
            troubled = false; lostAnnounced = false
            let previous = state
            state = result
            receivedAt = ProcessInfo.processInfo.systemUptime
            halfTrip = max(0, receivedAt - started) / 2
            guard result.active else {
                player.pause(); player.replaceCurrentItem(with: nil); observer = nil; mediaID = ""
                // Sep 29 2026: a share that ends is said aloud, and a local
                // pause ends with it, so the next share is not silent for her.
                locallyPaused = false; announced = nil; loads.reset()
                if result.unavailable == true {
                    let line = "This room’s recording is unavailable to your account. You can still join the conversation."
                    if previous.active { announce(line) } else { status = line }
                } else if previous.active {
                    announce("Shared playback stopped. Choose a recording from the shared library.")
                } else if recovered || previous.unavailable == true {
                    // only a stale notice is replaced; search results stay
                    status = "Choose a recording from the shared library."
                }
                return
            }
            if result.mediaID != mediaID || (needsURL && Date().timeIntervalSince(urlAt) > 1800) {
                guard let source = result.url, let url = URL(string: source), url.scheme == "https" else {
                    // Sep 29 2026: a poll that did not ask for a link saw a new
                    // recording. Stop the old file now instead of letting it
                    // play on under the new title, and fetch the link straight
                    // away rather than a poll later.
                    if result.mediaID != mediaID {
                        player.pause(); player.replaceCurrentItem(with: nil); observer = nil
                        if !needsURL { Task { [weak self] in await self?.refresh(forceURL: true) } }
                    }
                    mediaID = ""; return
                }
                if result.mediaID != mediaID { loads.reset() }
                player.pause()
                let item = AVPlayerItem(url: url)
                if let end = result.end { item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600) }
                observer = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    let status = item.status
                    Task { @MainActor in
                        guard let self, self.generation == current else { return }
                        if status == .readyToPlay { self.loadReady() }
                        if status == .failed { self.loadFailed() }
                    }
                }
                player.replaceCurrentItem(with: item)
                mediaID = result.mediaID; urlAt = Date(); seeking = false
            }
            synchronize()
            let line = result.playbackLine(failedHere: loads.gaveUp)
            if !locallyPaused && announced != result.revision {
                announced = result.revision
                announce(line)
            } else if recovered {
                // a poll or two failed and came back: clear the stale notice
                status = locallyPaused ? "Playback is paused on this phone. Tap Rejoin playback to continue." : line
            }
        } catch {
            guard generation == current else { return }
            troubled = true
            // With nothing shared there is no playback to lose.
            let message = (state.active ? "Playback connection lost. " : "Library connection lost. ") + error.localizedDescription
            if Date().timeIntervalSince(lastGood) > 10 {
                player.pause()
                // Sep 29 2026: said once, when her media actually stops (not
                // on every retry); the room's state is said again on return.
                // Only shown, not said, when nothing is shared.
                if !lostAnnounced && !locallyPaused && state.active { lostAnnounced = true; announced = nil; announce(message); return }
            }
            status = message
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
