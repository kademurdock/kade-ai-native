import AVFoundation
import SwiftUI
import UIKit

/// Oct 28 2026: THE PAINTED LOOPS (option four, the fallback under the live
/// video face). Short silent film loops made once from each character's own
/// painting (Kling 2.5 on fal, first and last frame pinned to the painting so
/// they loop without a seam): idle, listening, thinking, laugh, surprised,
/// concerned. A sighted person's stage shows them between replies when the
/// live face is not running; while the character speaks the mesh rig under
/// them takes over, since only it knows the mouth. The pick is
/// `CharacterLoopPolicy` (tested); a blind account never loads one.
///
/// Loops are fetched once into Caches and played from the file, muted and
/// silent by construction (encoded without an audio track).
struct CharacterLoopView: View {
    let agentID: String?
    let state: CharacterLoopState

    @State private var file: URL?
    @State private var shownState: CharacterLoopState?

    var body: some View {
        ZStack {
            if let file, let shownState {
                CharacterLoopPlayerView(file: file)
                    .id(shownState.rawValue + file.lastPathComponent)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: shownState)
        .accessibilityHidden(true)
        .task(id: "\(agentID ?? "")|\(state.rawValue)") {
            guard let url = CharacterLoopPolicy.url(agentID: agentID, state: state) else { file = nil; return }
            if let local = await CharacterLoopCache.shared.file(for: url), !Task.isCancelled {
                file = local
                shownState = state
            }
        }
    }
}

/// One looping, muted player layer.
struct CharacterLoopPlayerView: UIViewRepresentable {
    let file: URL

    func makeUIView(context: Context) -> CharacterLoopPlayerHost {
        let host = CharacterLoopPlayerHost()
        host.play(file)
        return host
    }

    func updateUIView(_ host: CharacterLoopPlayerHost, context: Context) {
        if host.file != file { host.play(file) }
    }

    static func dismantleUIView(_ host: CharacterLoopPlayerHost, coordinator: ()) {
        host.stop()
    }
}

final class CharacterLoopPlayerHost: UIView {
    private(set) var file: URL?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?

    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspectFill
        NotificationCenter.default.addObserver(self, selector: #selector(resume),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func play(_ file: URL) {
        self.file = file
        let item = AVPlayerItem(url: file)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        player.actionAtItemEnd = .advance
        looper = AVPlayerLooper(player: player, templateItem: item)
        self.player = player
        playerLayer.player = player
        player.play()
    }

    @objc private func resume() {
        player?.play()
    }

    func stop() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        playerLayer.player = nil
        player = nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

/// Loops fetched once, kept in Caches (the system may clear them; they come back).
actor CharacterLoopCache {
    static let shared = CharacterLoopCache()
    private var inFlight: [URL: Task<URL?, Never>] = [:]

    private var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("character-loops", isDirectory: true)
    }

    func file(for remote: URL) async -> URL? {
        let name = remote.path.split(separator: "/").suffix(3).joined(separator: "-")
        let local = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        if let task = inFlight[remote] { return await task.value }
        let task = Task<URL?, Never> { [folder] in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let (tmp, response) = try await URLSession.shared.download(from: remote)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
                try? FileManager.default.removeItem(at: local)
                try FileManager.default.moveItem(at: tmp, to: local)
                return local
            } catch {
                return nil
            }
        }
        inFlight[remote] = task
        let result = await task.value
        inFlight[remote] = nil
        return result
    }
}
