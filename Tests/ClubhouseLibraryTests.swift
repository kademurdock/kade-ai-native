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
        print("10 Clubhouse library model and timeline checks passed")
    }
}
