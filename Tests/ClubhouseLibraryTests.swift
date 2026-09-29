import Foundation

@main enum ClubhouseLibraryTests {
    static func main() throws {
        let decoder = JSONDecoder()
        let empty = try decoder.decode(ClubLibraryState.self, from: Data(#"{"active":false,"revision":3,"serverTime":1000}"#.utf8))
        precondition(!empty.active && empty.revision == 3 && empty.url == nil)
        let denied = try decoder.decode(ClubLibraryState.self, from: Data(#"{"active":false,"unavailable":true,"revision":4}"#.utf8))
        precondition(denied.unavailable == true && denied.title == nil)
        var state = try decoder.decode(ClubLibraryState.self, from: Data(#"{"active":true,"revision":5,"book":"abc","track":2,"position":50,"playing":true,"begin":10,"end":100,"controlling":false}"#.utf8))
        precondition(state.mediaID == "abc:2")
        precondition(state.target(after: 5) == 55)
        precondition(state.target(after: -5) == 50)
        precondition(state.target(after: 100) == 100)
        state.playing = false
        precondition(state.target(after: 100) == 50)
        state.position = 0
        precondition(state.target(after: 0) == 10)
        state.end = nil; state.position = 500; state.playing = true
        precondition(state.target(after: 20) == 520)
        let search = try decoder.decode(ClubLibrarySearch.self, from: Data(#"{"items":[{"id":"a","title":"A movie","kind":"video"}],"more":true}"#.utf8))
        precondition(search.items.first?.title == "A movie" && search.more)
        // Back/Ahead come from the room's timeline (Sep 29 2026): a player
        // frozen at 12:00 while the room reached 20:00 must not matter.
        var room = try decoder.decode(ClubLibraryState.self, from: Data(#"{"active":true,"revision":6,"book":"abc","track":1,"position":720,"playing":true,"begin":10,"end":3600}"#.utf8))
        precondition(room.skipTarget(by: -30, after: 480) == 1170)
        precondition(room.skipTarget(by: 30, after: 480) == 1230)
        precondition(room.skipTarget(by: 30, after: 2860) == 3600)
        room.playing = false; room.position = 20
        precondition(room.skipTarget(by: -30, after: 480) == 10)
        room.end = nil; room.position = 604790
        precondition(room.skipTarget(by: 30, after: 0) == 604800)
        precondition(ClubLibrarySearch.statusLine(count: 0) == "No shared recordings matched your search.")
        precondition(ClubLibrarySearch.statusLine(count: 1) == "1 recording found. Choose it below.")
        precondition(ClubLibrarySearch.statusLine(count: 3) == "3 recordings found. Choose one below.")
        let parts = try decoder.decode(ClubLibraryTracks.self, from: Data(#"{"id":"b","title":"Home movies","tracks":[{"index":0,"title":"Side A","mime":"video/mp4"},{"index":1,"title":"Side B","mime":"video/mp4"}]}"#.utf8))
        precondition(parts.readyLine == "Home movies has 2 parts, listed just above the recordings.")
        let single = ClubLibraryTracks(id: "c", title: "A song", tracks: [parts.tracks[0]])
        precondition(single.readyLine == "A song is ready to choose, just above the recordings.")
        print("20 Clubhouse library model and timeline checks passed")
    }
}
