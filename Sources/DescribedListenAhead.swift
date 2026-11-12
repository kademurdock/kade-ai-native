import AVFoundation
import UIKit

/// Phase 4 pick 2 (Nov 12 2026): listen to a described video while it is still
/// being made. Each finished section is already kept on the server as its own
/// sound file (the film's sound with the descriptions mixed in); this plays
/// the unbroken run of them in order, sound only, while the rest is made.
///
/// Her rules, as the web page keeps them: the main player is paused before
/// this starts, and this stops the moment the main player starts. At the edge
/// she hears once that she has caught up, and it carries on by itself when
/// the next section arrives. Before a section whose look failed she hears a
/// warning, then 2.5 s of quiet, then the film. A section that will not play
/// is skipped with one sentence. Focus is never moved.
///
/// Server switch: KADE_DESCRIPTION_LISTEN_AHEAD=0 (the config says false and
/// the offer is not shown). Phone switch: UserDefaults kade.switch.listenAhead.
@MainActor
final class ListenAheadPlayer: ObservableObject {
    /// The job being listened to, or nil.
    @Published private(set) var jobId: String?
    @Published private(set) var isPaused = false
    /// The last thing said, for the screen (not a live region).
    @Published private(set) var status = ""

    typealias Fetch = (_ jobId: String, _ from: Int) async -> DVReadySections?

    private let player = AVPlayer()
    private var fetch: Fetch?
    private var sections: [DVReadySections.Section] = []
    private var at = 0
    private var making = false
    private var count = 0
    private var waiting = false
    private var rate: Float = 1
    private var pollTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var endWatch: NSObjectProtocol?
    private var failWatch: NSObjectProtocol?
    private var statusWatch: NSKeyValueObservation?
    /// Goes up with every section and on stop, so late callbacks do nothing.
    private var playNumber = 0

    init() {
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    }

    deinit {
        if let endWatch { NotificationCenter.default.removeObserver(endWatch) }
        if let failWatch { NotificationCenter.default.removeObserver(failWatch) }
    }

    private func say(_ text: String) {
        status = text
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    /// Starts listening to `jobId` from its first section. The caller has
    /// already paused the main player.
    func start(jobId: String, rate: Double, fetch: @escaping Fetch) async {
        stop()
        self.fetch = fetch
        self.rate = Float(min(3, max(0.5, rate)))
        self.jobId = jobId
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
        LibraryNowPlaying.shared.pauseForOtherAudio("a described video")
        guard let first = await fetch(jobId, 0), self.jobId == jobId, !first.sections.isEmpty else {
            if self.jobId == jobId {
                stop()
                say("No section is finished yet. Try again in a few minutes.")
            }
            return
        }
        take(first)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled, self.jobId == jobId else { return }
                if !self.making && !self.waiting { continue }
                await self.poll()
            }
        }
        if let wait = first.waitSeconds, wait > 0 {
            say("Starting. The describing is about \(max(1, Int((wait / 60).rounded(.up)))) minutes short of keeping ahead of you, so it may pause to wait part way through.")
            startTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, !Task.isCancelled, self.jobId == jobId else { return }
                self.playNext()
            }
        } else {
            playNext()
        }
    }

    /// Stops and forgets everything. Safe to call when idle.
    func stop() {
        playNumber += 1
        pollTask?.cancel(); pollTask = nil
        startTask?.cancel(); startTask = nil
        unwatch()
        player.pause()
        player.replaceCurrentItem(with: nil)
        jobId = nil
        fetch = nil
        sections = []
        at = 0
        making = false
        count = 0
        waiting = false
        isPaused = false
        status = ""
    }

    func togglePause() {
        guard jobId != nil else { return }
        if isPaused {
            isPaused = false
            if player.currentItem != nil { player.playImmediately(atRate: rate) }
        } else {
            isPaused = true
            player.pause()
        }
    }

    /// Her playback speed, kept for every section.
    func setRate(_ value: Double) {
        rate = Float(min(3, max(0.5, value)))
        player.defaultRate = rate
        if player.rate != 0 { player.rate = rate }
    }

    private func take(_ result: DVReadySections) {
        let next = (sections.last?.index ?? -1) + 1
        for item in result.sections where item.index >= next && URL(string: item.url) != nil {
            sections.append(item)
        }
        making = result.making ?? false
        count = result.count ?? count
    }

    private func poll() async {
        guard let jobId, let fetch else { return }
        let from = (sections.last?.index ?? -1) + 1
        guard let result = await fetch(jobId, from), self.jobId == jobId else { return }
        take(result)
        if waiting && at < sections.count {
            playNext()
        } else if waiting && !making {
            waiting = false
            pollTask?.cancel(); pollTask = nil
            say(result.state == "done"
                ? "That was the last section. The whole described copy is ready in the main player."
                : "The run stopped here. Nothing more is ready.")
        }
    }

    private func playNext() {
        guard let jobId else { return }
        guard at < sections.count else {
            if !waiting {
                waiting = true
                player.replaceCurrentItem(with: nil)
                if making {
                    say("You have caught up. Section \(at + 1) of \(max(count, at + 1)) is still being made. It will start by itself.")
                } else {
                    Task { await poll() }
                }
            }
            return
        }
        waiting = false
        let item = sections[at]
        playNumber += 1
        let number = playNumber
        if item.undescribed == true {
            say("The next part has no description. You will hear the film sound only.")
            startTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let self, !Task.isCancelled, self.jobId == jobId, self.playNumber == number else { return }
                self.play(item, number: number)
            }
        } else {
            status = ""
            play(item, number: number)
        }
    }

    private func play(_ section: DVReadySections.Section, number: Int) {
        guard let url = URL(string: section.url) else { skip(number); return }
        unwatch()
        let item = AVPlayerItem(url: url)
        endWatch = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.playNumber == number else { return }
                self.at += 1
                self.playNext()
            }
        }
        failWatch = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.skip(number) }
        }
        statusWatch = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.skip(number) }
        }
        player.replaceCurrentItem(with: item)
        player.defaultRate = rate
        if !isPaused { player.playImmediately(atRate: rate) }
    }

    private func skip(_ number: Int) {
        guard jobId != nil, playNumber == number else { return }
        say("That section could not be played. Moving to the next one.")
        at += 1
        playNext()
    }

    private func unwatch() {
        if let endWatch { NotificationCenter.default.removeObserver(endWatch) }
        endWatch = nil
        if let failWatch { NotificationCenter.default.removeObserver(failWatch) }
        failWatch = nil
        statusWatch?.invalidate()
        statusWatch = nil
    }
}
