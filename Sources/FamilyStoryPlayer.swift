import AVFoundation
import SwiftUI
import UIKit

// MARK: - Family history: Listen, a story read aloud on the screen (Sep 29 2026)
//
// DESIGN 1.9 and 4.9 with her Sep 29 yes (ADDENDUM C). A story is read in
// the Library's voice, part by part (about 450 characters each, whole
// sentences). Each part comes from GET /story/:slug/audio/:i: the server
// voices it the first time anyone asks, keeps it, and answers a signed link
// with the part's sentences timed in seconds. The next part is fetched while
// this one plays.
// - Play pauses a Library book that is playing
//   (LibraryNowPlaying.pauseForOtherAudio), then takes the spoken-audio
//   session. Nothing is put on the lock screen and no headphone buttons are
//   taken in this version, so it can never fight the book's controls or a
//   call's.
// - It stops when she leaves the story, pauses when the app goes to the
//   background, and stops at sign-out (ContentView's signed-out block).
// - The sentence being read is published (`caption`, `cue`) for the caption
//   strip and the highlight in the text. Nothing here speaks over the story.

/// The sentence being read: which part, and which sentence in it.
struct FamilyStoryCue: Equatable {
    let part: Int
    let index: Int
}

@MainActor
final class FamilyStoryPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = FamilyStoryPlayer()

    /// The story that is loaded (nil when nothing is).
    @Published private(set) var slug: String?
    @Published private(set) var part = 0
    @Published private(set) var partCount = 0
    @Published private(set) var playing = false
    /// A part is being voiced or downloaded.
    @Published private(set) var loading = false
    /// The sentence being read, for the caption strip.
    @Published private(set) var caption = ""
    @Published private(set) var cue: FamilyStoryCue?
    /// What went wrong, in words (a Try again follows it).
    @Published private(set) var problem: String?
    /// 0.75 to 2 times.
    @Published private(set) var speed: Float = 1

    static let speeds: [Float] = [0.75, 1, 1.25, 1.5, 2]

    private var chunks: [FHChunk] = []
    private var player: AVAudioPlayer?
    /// The playing part's sentences, in seconds.
    private var cues: [FHCue] = []
    /// The next part, fetched while this one plays.
    private var ahead: FamilyStoryPart?
    private var loadTask: Task<Void, Never>?
    private var aheadTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    /// Moves on at every new part and at stop, so a late answer is dropped.
    private var generation = 0
    private var sessionTaken = false
    private let downloads = URLSession(configuration: .ephemeral)

    private override init() {
        super.init()
    }

    /// Whether this story is the one loaded.
    func isLoaded(_ storySlug: String) -> Bool { slug == storySlug }

    // MARK: Transport

    /// Plays a story from a part (the first by default); the story already
    /// loaded carries on from where it is.
    func play(slug storySlug: String, chunks storyChunks: [FHChunk], from start: Int = 0) {
        if slug == storySlug, player != nil {
            resume()
            return
        }
        if slug == storySlug, loading { return }
        stop()
        guard !storyChunks.isEmpty else { return }
        slug = storySlug
        chunks = storyChunks
        partCount = storyChunks.count
        load(min(max(0, start), storyChunks.count - 1), autoplay: true)
    }

    func togglePlay() {
        if playing {
            pause()
        } else if player != nil {
            resume()
        } else if slug != nil {
            load(part, autoplay: true)
        }
    }

    func pause() {
        player?.pause()
        playing = false
        tickTask?.cancel()
        tickTask = nil
    }

    private func resume() {
        guard let player else { return }
        takeSession()
        player.enableRate = true
        player.rate = speed
        if player.play() {
            playing = true
            startTicking()
        }
    }

    /// Back one part: to the start of this part when it has played a few
    /// seconds, else to the part before.
    func back() {
        guard slug != nil else { return }
        if let player, player.currentTime > 3 {
            player.currentTime = 0
            tick()
            return
        }
        guard part > 0 else {
            player?.currentTime = 0
            return
        }
        load(part - 1, autoplay: playing || player == nil)
    }

    func forward() {
        guard slug != nil, part + 1 < partCount else { return }
        load(part + 1, autoplay: playing || player == nil)
    }

    func setSpeed(_ value: Float) {
        speed = value
        player?.rate = value
    }

    /// Asks again after a part could not be fetched.
    func retry() {
        guard slug != nil else { return }
        load(part, autoplay: true)
    }

    /// Leaving the story, and sign-out: everything goes.
    func stop() {
        generation += 1
        loadTask?.cancel()
        aheadTask?.cancel()
        tickTask?.cancel()
        loadTask = nil
        aheadTask = nil
        tickTask = nil
        player?.stop()
        player = nil
        ahead = nil
        chunks = []
        cues = []
        slug = nil
        part = 0
        partCount = 0
        playing = false
        loading = false
        caption = ""
        cue = nil
        problem = nil
        giveSessionBack()
    }

    // MARK: Parts

    private func load(_ index: Int, autoplay: Bool) {
        generation += 1
        let asked: Int = generation
        loadTask?.cancel()
        tickTask?.cancel()
        tickTask = nil
        player?.stop()
        player = nil
        playing = false
        part = index
        cue = nil
        caption = ""
        problem = nil
        loading = true
        let storySlug: String = slug ?? ""
        let fractions: [FHCue] = chunks.indices.contains(index) ? chunks[index].cues : []
        let ready: FamilyStoryPart? = (ahead?.index == index) ? ahead : nil
        loadTask = Task { @MainActor in
            do {
                let fetched: FamilyStoryPart
                if let ready {
                    fetched = ready
                } else {
                    fetched = try await self.fetchPart(storySlug, index, fractions: fractions)
                }
                guard asked == self.generation else { return }
                self.start(fetched, autoplay: autoplay)
            } catch {
                guard asked == self.generation, !Task.isCancelled else { return }
                if LibraryLoad.cancelled(error) { return }
                self.loading = false
                let message: String = (error as? FamilyFailure)?.message
                    ?? "The story's voice could not be fetched. Try again in a moment."
                self.problem = message
                Earcons.shared.play(.error)
            }
        }
    }

    /// Asks the server for a part, then downloads its audio.
    private func fetchPart(_ storySlug: String, _ index: Int, fractions: [FHCue]) async throws -> FamilyStoryPart {
        let answer: FHStoryAudio = try await FamilyHistoryService.shared.storyAudio(slug: storySlug, part: index)
        guard let url = answer.url else { throw FamilyFailure.unreadable }
        let (data, response) = try await downloads.data(from: url)
        let status: Int = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status), !data.isEmpty else { throw FamilyFailure.server(status, nil) }
        return FamilyStoryPart(index: index, data: data, duration: answer.duration ?? 0,
                               timed: answer.cues, fractions: fractions)
    }

    private func start(_ fetched: FamilyStoryPart, autoplay: Bool) {
        loading = false
        guard let made = try? AVAudioPlayer(data: fetched.data) else {
            problem = "This part of the story could not be played. Try again in a moment."
            Earcons.shared.play(.error)
            return
        }
        made.delegate = self
        made.enableRate = true
        made.rate = speed
        made.prepareToPlay()
        player = made
        let length: Double = fetched.duration > 0 ? fetched.duration : made.duration
        cues = FamilyGeometry.cuesInSeconds(fetched.timed, fractions: fetched.fractions, duration: length)
        if autoplay {
            resume()
        }
        tick()
        fetchAhead(part + 1)
    }

    /// The next part, while this one plays (never more than one ahead).
    private func fetchAhead(_ index: Int) {
        aheadTask?.cancel()
        guard let storySlug = slug, chunks.indices.contains(index), ahead?.index != index else { return }
        let asked: Int = generation
        let fractions: [FHCue] = chunks[index].cues
        aheadTask = Task { @MainActor in
            guard let fetched = try? await self.fetchPart(storySlug, index, fractions: fractions) else { return }
            guard asked == self.generation else { return }
            self.ahead = fetched
        }
    }

    // MARK: The sentence being read

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor in
            while !Task.isCancelled {
                self.tick()
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func tick() {
        guard let player else { return }
        if playing, !player.isPlaying, player.currentTime > 0 {
            // A call or another app took the sound: it is paused now.
            playing = false
        }
        guard let index = FamilyGeometry.cueIndex(cues, at: player.currentTime) else { return }
        let now = FamilyStoryCue(part: part, index: index)
        if now != cue {
            cue = now
            caption = cues.indices.contains(index) ? cues[index].text : ""
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in
            self.partFinished(finished)
        }
    }

    private func partFinished(_ finished: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == finished else { return }
        if part + 1 < partCount {
            load(part + 1, autoplay: true)
            return
        }
        playing = false
        tickTask?.cancel()
        tickTask = nil
        caption = ""
        FamilyAnnounce.say("The end of the story.")
    }

    // MARK: The sound

    private func takeSession() {
        if !sessionTaken {
            LibraryNowPlaying.shared.pauseForOtherAudio("a family story")
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
        sessionTaken = true
    }

    /// Back to the app's usual session shape (as the Library reader does).
    private func giveSessionBack() {
        guard sessionTaken else { return }
        sessionTaken = false
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }
}

/// One part, ready to play: its audio and its sentences.
struct FamilyStoryPart {
    let index: Int
    let data: Data
    /// Seconds (0 when the server did not say).
    let duration: Double
    /// The server's cues in seconds.
    let timed: [FHCue]
    /// The story's cues for this part, as fractions (used when `timed` is empty).
    let fractions: [FHCue]
}
