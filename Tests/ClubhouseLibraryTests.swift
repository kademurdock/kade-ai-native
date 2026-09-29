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
        // After her phone gives up on a recording it never claims "Playing"
        // (Sep 29 2026).
        room.title = "A movie"; room.playing = true
        precondition(room.playbackLine() == "Playing: A movie")
        precondition(room.playbackLine(failedHere: true) == "Playing for the room: A movie. It could not play on this phone. Try Rejoin playback.")
        room.title = nil; room.playing = false
        precondition(room.playbackLine() == "Paused: Library recording")
        precondition(room.playbackLine(failedHere: true) == "Paused for the room: Library recording. It could not play on this phone. Try Rejoin playback.")
        // A file that never plays: one fresh link, give up once, then stay
        // quiet through the half-hourly link; loading after all clears it.
        // (Results are taken outside precondition, which -Ounchecked skips.)
        let t0 = Date(timeIntervalSince1970: 0)
        var broken = ClubLoadFailures()
        var steps = [broken.failed(at: t0)]
        precondition(steps == [.retry] && !broken.gaveUp)
        steps.append(broken.failed(at: t0 + 3))
        precondition(steps == [.retry, .giveUp] && broken.gaveUp)
        steps.append(broken.failed(at: t0 + 1803))
        precondition(steps == [.retry, .giveUp, .quiet] && broken.gaveUp)
        let loadedAfterAll = broken.ready(at: t0 + 3605), readyAgain = broken.ready(at: t0 + 3606)
        precondition(loadedAfterAll && !readyAgain && !broken.gaveUp)
        // Ready, then failing again seconds later, still gives up.
        var loop = ClubLoadFailures()
        loop.ready(at: t0)
        let loopFirst = loop.failed(at: t0 + 60)
        loop.ready(at: t0 + 62)
        let loopSecond = loop.failed(at: t0 + 64)
        precondition(loopFirst == .retry && loopSecond == .giveUp)
        // Two network drops an hour apart in a long film each get a fresh
        // link without Rejoin.
        var film = ClubLoadFailures()
        film.ready(at: t0)
        let firstDrop = film.failed(at: t0 + 3600)
        film.ready(at: t0 + 3603)
        let secondDrop = film.failed(at: t0 + 7200)
        precondition(firstDrop == .retry && secondDrop == .retry && film.count == 1)
        // With no playback in between, time alone does not start over.
        var stuck = ClubLoadFailures()
        let stuckSteps = [stuck.failed(at: t0), stuck.failed(at: t0 + 600)]
        precondition(stuckSteps == [.retry, .giveUp])
        stuck.reset()
        precondition(stuck.count == 0 && !stuck.gaveUp)
        print("32 Clubhouse library model and timeline checks passed")
    }
}
