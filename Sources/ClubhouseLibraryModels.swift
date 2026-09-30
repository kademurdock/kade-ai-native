import Foundation

struct ClubLibraryItem: Decodable, Identifiable {
    let id: String
    let title: String
    let kind: String
}

struct ClubLibraryTrack: Decodable, Identifiable {
    let index: Int
    let title: String
    let mime: String
    var id: Int { index }
}

struct ClubLibrarySearch: Decodable {
    let items: [ClubLibraryItem]
    let more: Bool

    /// What the picker says when a search lands. Spoken as well as shown
    /// (Sep 29 2026): focus stays on the Search button, so without it a
    /// VoiceOver user was never told the results had arrived.
    static func statusLine(count: Int) -> String {
        switch count {
        case 0: return "No shared recordings matched your search."
        case 1: return "1 recording found. Choose it below."
        default: return "\(count) recordings found. Choose one below."
        }
    }
}

struct ClubLibraryTracks: Decodable {
    let id: String
    let title: String
    let tracks: [ClubLibraryTrack]

    /// Spoken after she picks a recording (Sep 29 2026). Its parts appear
    /// above the list with no focus move, so nothing seemed to happen.
    var readyLine: String {
        switch tracks.count {
        case 0: return "\(title) has nothing that can play here."
        case 1: return "\(title) is ready to choose, just above the recordings."
        default: return "\(title) has \(tracks.count) parts, listed just above the recordings."
        }
    }
}

struct ClubLibraryState: Decodable {
    var active = false
    var revision = 0
    var unavailable: Bool?
    var book: String?
    var track: Int?
    var title: String?
    var trackTitle: String?
    var mime: String?
    var position: Double?
    var playing: Bool?
    var begin: Double?
    var end: Double?
    var hostName: String?
    var controlling: Bool?
    var canTakeControl: Bool?
    var url: String?

    var mediaID: String { "\(book ?? ""):\(track ?? 0)" }
    func target(after elapsed: Double) -> Double {
        let time = (position ?? 0) + (playing == true ? max(0, elapsed) : 0)
        return max(begin ?? 0, min(end ?? .greatestFiniteMagnitude, time))
    }

    /// Where Back/Ahead sends the room: the shared timeline plus the jump,
    /// kept inside the recording. Sep 29 2026: taken from the room's clock,
    /// not the phone's player, which is stale after a local pause, a stall
    /// or a failed load.
    func skipTarget(by seconds: Double, after elapsed: Double) -> Double {
        max(begin ?? 0, min(end ?? 604800, target(after: elapsed) + seconds))
    }

    /// What she hears when the room's playback changes. Sep 29 2026: after
    /// her phone gave up on a recording that would not load, it no longer
    /// claims "Playing" while she hears nothing.
    func playbackLine(failedHere: Bool = false) -> String {
        let name = title ?? "Library recording"
        guard failedHere else { return (playing == true ? "Playing: " : "Paused: ") + name }
        return (playing == true ? "Playing for the room: " : "Paused for the room: ") + name + ". It could not play on this phone. Try Rejoin playback."
    }
}

/// Failed loads of the shared recording on this phone (Sep 29 2026). One
/// fresh link, then stop and say so once, instead of signing and
/// downloading a file that can never play every 2 seconds. A failure more
/// than 5 minutes after the last one, with playback in between, is a new
/// network drop in a long film, so it starts over rather than needing Rejoin.
struct ClubLoadFailures {
    enum Next: Equatable { case retry, giveUp, quiet }
    private(set) var count = 0
    private(set) var gaveUp = false
    private var failedAt = Date.distantPast
    private var readyAt = Date.distantPast

    mutating func failed(at now: Date) -> Next {
        if readyAt > failedAt && now.timeIntervalSince(failedAt) > 300 { count = 0 }
        count += 1; failedAt = now
        if count < 2 { return .retry }
        if gaveUp { return .quiet }
        gaveUp = true
        return .giveUp
    }

    /// An item became ready to play. True when it had given up before, so
    /// the failure notice can be replaced.
    @discardableResult mutating func ready(at now: Date) -> Bool {
        readyAt = now
        let wasGivenUp = gaveUp
        gaveUp = false
        return wasGivenUp
    }

    mutating func reset() { self = ClubLoadFailures() }
}
