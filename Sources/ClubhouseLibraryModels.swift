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
}

struct ClubLibraryTracks: Decodable {
    let id: String
    let title: String
    let tracks: [ClubLibraryTrack]
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
}
