import Foundation

// The Arcade's pure models (Sources/ArcadeModels.swift), compiled by
// run-arcade-tests.sh. No simulator, no WebKit, no network.

@main enum ArcadeModelsTests {
    static var checks = 0

    static func check(_ condition: Bool, _ what: String) {
        checks += 1
        precondition(condition, "Arcade check failed: " + what)
    }

    static func main() throws {
        try catalogAndShelf()
        try manifestAndLinks()
        try packIndexAndScheme()
        try touchMenus()
        try touchFights()
        controllersAndKeys()
        javascriptAndWords()
        savesKept()
        print("Arcade models: \(checks) checks passed. Covers catalog and shelf gating, manifests, signed links, pack indexes, the kadearcade:// routing, MIME types and byte ranges, the touch recognizer's menu and fight tables (both halves at once, taps across them, hold times, the stick's edges), the controller map, keyboard names, the page bridge script, kept saves and the test report; not WebKit, VoiceOver, haptics, GameController or a real download.")
    }

    // MARK: Saves

    static func savesKept() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arcade-saves-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArcadeSaveStore(root: root)
        check(store.base64(gameId: "fighter") == nil, "no save yet")
        let save = Data([0, 1, 2, 255])
        check(store.keep(base64: save.base64EncodedString(), gameId: "fighter"), "a save from the page is kept")
        check(store.base64(gameId: "fighter") == save.base64EncodedString(), "and given back as the page's saveData")
        check(!store.keep(base64: "not base64!", gameId: "fighter") && !store.keep(base64: save.base64EncodedString(), gameId: "../x"),
              "text that is not a save, or a game id that is not a plain name, is refused")
        check(store.base64(gameId: "fighter") == save.base64EncodedString(), "and the kept save is untouched")
    }

    // MARK: Catalog and shelf

    static func catalogAndShelf() throws {
        let decoder = JSONDecoder()
        let json = #"""
        {"catalog":[
          {"id":"fighter","title":"Fighter Demo","console":"Nintendo 64","access":"family","size":"45200000","version":"2026.10.19"},
          {"id":"tilt","title":"Tilt Demo","console":"NES","access":"public","size":2100000,"version":3},
          {"id":"fighter","title":"Duplicate"},
          {"title":"No id"},
          {"id":"../escape","title":"Bad id"},
          {"id":"odd","title":"Odd shelf","access":"members","version":"1"}
        ],"features":{"arcadeFamily":true}}
        """#
        let config = try decoder.decode(ArcadeConfig.self, from: Data(json.utf8))
        check(config.catalog.map { $0.id } == ["fighter", "tilt", "odd"], "catalog drops duplicates, missing and unsafe ids")
        check(config.catalog[0].size == 45_200_000 && config.catalog[1].size == 2_100_000, "sizes read from strings and numbers")
        check(config.catalog[1].version == "3" && config.catalog[1].access == .open, "a numeric version and the public shelf")
        check(config.catalog[2].access == .family, "an unknown access is treated as family")
        let games = try decoder.decode(ArcadeConfig.self, from: Data(#"{"games":[{"id":"a","version":"1"}]}"#.utf8))
        check(games.catalog.count == 1 && games.catalog[0].title == "a", "the catalog may be called games, and the title falls back to the id")
        let empty = try decoder.decode(ArcadeConfig.self, from: Data(#"{"catalog":"nope"}"#.utf8))
        check(empty.catalog.isEmpty, "an unreadable catalog is empty, not an error")

        let note = "Part of the Family feature pack"
        let fighter = config.catalog[0], tilt = config.catalog[1], odd = config.catalog[2]
        let open = ArcadeShelf.rows([tilt, fighter, odd], familyOpen: true, familyNote: note)
        check(open == [.playable(tilt), .playable(fighter), .playable(odd)], "inside the pack every game is playable")
        let closed = ArcadeShelf.rows([tilt, fighter, odd], familyOpen: false, familyNote: note)
        check(closed == [.playable(tilt), .familyShelf(reason: note)], "outside the pack the family games fold into ONE row")
        check(!closed.map { $0.id }.contains { $0.contains("fighter") || $0.contains("odd") }, "the folded row names no game")
        let reviewSeat = ArcadeShelf.rows([], familyOpen: false, familyNote: note)
        check(reviewSeat == [.familyShelf(reason: note)], "with no family games the review seat still sees the greyed Family shelf")
        let lockedFamily = ArcadeCatalogEntry(id: "fighter", title: "Fighter", access: .family, version: "1", locked: true, note: "Grown-ups only")
        check(ArcadeShelf.rows([lockedFamily], familyOpen: true, familyNote: note) == [.locked(lockedFamily, reason: "Grown-ups only")],
              "the server's own lock is greyed with its note")
        let leaky = ArcadeCatalogEntry(id: "fighter", title: "Fighter", access: .family, version: "1", locked: true, note: "Fighter is locked")
        check(ArcadeShelf.rows([leaky], familyOpen: false, familyNote: note) == [.familyShelf(reason: note)],
              "outside the pack a server note that names a game is not shown")
        let unready = ArcadeCatalogEntry(id: "tilt", title: "Tilt", access: .open, version: "")
        check(ArcadeShelf.rows([unready], familyOpen: false, familyNote: note).first == .locked(unready, reason: ArcadeShelf.notReady),
              "a game with no usable version is greyed, not playable")
        let publicLocked = ArcadeCatalogEntry(id: "tilt", title: "Tilt", access: .open, version: "1", locked: true)
        check(ArcadeShelf.rows([publicLocked], familyOpen: true, familyNote: note).first == .locked(publicLocked, reason: ArcadeShelf.publicLocked),
              "a locked public game says so in plain words")

        check(ArcadePaths.isSafeName("demo") && ArcadePaths.isSafeName("2026.10.19-b"), "plain names are safe")
        check(!ArcadePaths.isSafeName("../x") && !ArcadePaths.isSafeName("a b") && !ArcadePaths.isSafeName(".hidden") && !ArcadePaths.isSafeName(""),
              "folder-escaping or odd names are refused")
        check(ArcadePaths.normalize("./a//b/") == "a/b" && ArcadePaths.normalize("a/../b") == nil && ArcadePaths.normalize("/") == nil,
              "paths are tidied and never climb out")
        check(ArcadePaths.normalizeFolder("") == "" && ArcadePaths.normalizeFolder("emulator") == "emulator/", "folders end in a slash")
        check(ArcadePaths.folder(of: "games/demo/play.html") == "games/demo/" && ArcadePaths.folder(of: "play.html") == "", "a file's folder")
    }

    // MARK: Manifest and links

    static func manifestAndLinks() throws {
        let decoder = JSONDecoder()
        let sha = String(repeating: "ab", count: 32)
        let kitSha = String(repeating: "cd", count: 32)
        let json = """
        {"id":"demo","version":"2026.10.19","packs":[
          {"kind":"kit","id":"kit","version":"4.2.3-1","size":4100000,"sha256":"\(kitSha)"},
          {"kind":"game","id":"demo","version":"2026.10.19","bytes":"45200000","sha256":"\(sha.uppercased())","signPath":"api/kade/arcade/games/demo/2026.10.19/pack"},
          {"kind":"game","id":"bad","version":"1","size":10,"sha256":"short"},
          {"kind":"kit","id":"kit","version":"4.2.3-1","size":4100000,"sha256":"\(kitSha)"}
        ]}
        """
        let manifest = try decoder.decode(ArcadeManifest.self, from: Data(json.utf8))
        check(manifest.entry == "games/demo/play.html" && manifest.base == "games/demo/" && manifest.emulatorData == "emulatorjs/",
              "the page, base and EmulatorJS folder default from the game id (the kit pack's own emulatorjs/ folder)")
        check(manifest.packs.map { $0.key } == ["kit/4.2.3-1", "demo/2026.10.19"], "packs keep order, drop bad and repeated ones")
        check(manifest.packs[1].sha256 == sha && manifest.packs[1].size == 45_200_000, "sha256 is lowercased and bytes counts as size")
        check(manifest.packs[1].signPath == "api/kade/arcade/games/demo/2026.10.19/pack", "the signing path is kept")
        check(manifest.totalBytes == 49_300_000 && manifest.bytesMissing(installed: ["kit/4.2.3-1"]) == 45_200_000,
              "the size to download leaves out packs already on the phone")
        check(manifest.ready && manifest.problem == nil, "a kit plus a game is installable, and a manifest without ready counts as ready")

        let notReady = try decoder.decode(ArcadeManifest.self, from: Data("""
        {"id":"demo","title":"Demo","console":"N64","access":"family","version":"20261018-63fdca17","ready":false,"packs":[]}
        """.utf8))
        check(!notReady.ready && notReady.problem == ArcadeShelf.notReady,
              "a game listed before its packs are uploaded is not ready yet, not an empty download list")
        let emptyList = try decoder.decode(ArcadeManifest.self, from: Data(#"{"id":"demo","version":"1","ready":true,"packs":[]}"#.utf8))
        check(emptyList.ready && emptyList.problem == "The game's download list is empty.", "a ready manifest with no packs is still refused")

        let custom = try decoder.decode(ArcadeManifest.self, from: Data("""
        {"id":"tilt","version":"3","entry":"/games/tilt/index.html","base":"games/tilt/files","emulatorData":"ejs/data","size":2100000,"sha256":"\(sha)"}
        """.utf8))
        check(custom.entry == "games/tilt/index.html" && custom.base == "games/tilt/files/" && custom.emulatorData == "ejs/data/",
              "explicit paths are tidied into relative folders")
        check(custom.packs.count == 1 && custom.packs[0].key == "tilt/3" && custom.packs[0].kind == "game",
              "a one-pack manifest carries its size and sha256 at the top")
        let kitOnly = try decoder.decode(ArcadeManifest.self, from: Data("""
        {"id":"x","version":"1","packs":[{"kind":"kit","id":"kit","version":"1","size":5,"sha256":"\(kitSha)"}]}
        """.utf8))
        check(kitOnly.problem != nil, "a manifest with no game pack is refused")
        let escaping = try? decoder.decode(ArcadeManifest.self, from: Data(#"{"id":"x","version":"1","entry":"../../etc/play.html"}"#.utf8))
        check(escaping == nil, "an entry that climbs out of the packs is refused")

        let link = try decoder.decode(ArcadeSignedLink.self, from: Data(#"{"url":"https://example.invalid/arcade/games/demo/2026.10.19/blob.bin?X-Amz-Signature=abc","indexUrl":"https://example.invalid/arcade/games/demo/2026.10.19/pack.json?sig=1"}"#.utf8))
        check(link.blobURL.host == "example.invalid" && link.indexURL?.lastPathComponent == "pack.json", "a signed link and its index")
        let insecure = try? decoder.decode(ArcadeSignedLink.self, from: Data(#"{"url":"http://example.invalid/blob.bin"}"#.utf8))
        check(insecure == nil, "only https links are taken")
        let bare = try decoder.decode(ArcadeSignedLink.self, from: Data(#"{"href":"https://example.invalid/b"}"#.utf8))
        check(bare.indexURL == nil, "the index link is optional")

        let inline = try decoder.decode(ArcadePackRef.self, from: Data("""
        {"id":"demo","version":"1","size":30,"sha256":"\(sha)","index":[{"path":"games/demo/play.html","offset":0,"length":10},{"path":"../x","offset":0,"length":1}]}
        """.utf8))
        check(inline.index == [ArcadePackFile(path: "games/demo/play.html", offset: 0, length: 10)], "an inline index drops unsafe paths")

        let record = ArcadeInstallRecord(manifest: manifest, title: "Demo")
        let encoded = try JSONEncoder().encode(record)
        check(try JSONDecoder().decode(ArcadeInstallRecord.self, from: encoded) == record, "the install record round-trips")
    }

    // MARK: Packs and the scheme

    static func packIndexAndScheme() throws {
        let list = try ArcadePackIndex(data: Data(#"{"files":[{"path":"core/app.js","offset":0,"length":10},{"path":"emulatorjs/loader.js","offset":10,"length":5,"mime":"text/javascript"}]}"#.utf8), blobSize: 15)
        check(list.files.count == 2 && list.file(at: "emulatorjs/loader.js")?.offset == 10, "pack.json as a list")
        let map = try ArcadePackIndex(data: Data(#"{"files":{"games/demo/play.html":{"offset":0,"length":4},"games/demo/local/rom.z64":[4,6]}}"#.utf8), blobSize: 10)
        check(map.file(at: "games/demo/local/rom.z64")?.length == 6 && map.file(at: "games/demo/play.html")?.offset == 0, "pack.json as a map")
        var outOfRange = false
        do { _ = try ArcadePackIndex(data: Data(#"{"files":[{"path":"a","offset":8,"length":5}]}"#.utf8), blobSize: 10) }
        catch ArcadePackIndex.Problem.outOfRange(let path) { outOfRange = path == "a" }
        check(outOfRange, "a file that runs past blob.bin is refused")
        check((try? ArcadePackIndex(data: Data("[]".utf8), blobSize: 10)) == nil, "an unreadable index is refused")
        check(try ArcadePackIndex(data: list.jsonData(), blobSize: 15) == list, "the kept pack.json reads back the same")

        let gameBlob = URL(fileURLWithPath: "/tmp/arcade-game.bin")
        let kitBlob = URL(fileURLWithPath: "/tmp/arcade-kit.bin")
        let game = ArcadeMount(id: "demo", version: "1", index: map, blob: gameBlob)
        let kit = ArcadeMount(id: "kit", version: "1", index: list, blob: kitBlob)

        let page = ArcadeRoute.resolve(URL(string: "kadearcade://game/games/demo/play.html")!)
        check(page?.host == .game && page?.path == "games/demo/play.html", "a page URL resolves")
        check(ArcadeRoute.resolve(URL(string: "kadearcade://elsewhere/a.js")!) == nil, "an unknown host is refused")
        check(ArcadeRoute.resolve(URL(string: "https://game/a.js")!) == nil, "another scheme is refused")
        check(ArcadeRoute.resolve(URL(string: "kadearcade://game/a/../../b.js")!) == nil, "a climbing path is refused")
        check(ArcadeRoute.root(.game) == "kadearcade://game/", "the game origin")

        check(ArcadeMime.type(for: "a/core.wasm") == "application/wasm", "wasm")
        check(ArcadeMime.type(for: "app.js").hasPrefix("text/javascript") && ArcadeMime.type(for: "x.MJS").hasPrefix("text/javascript"), "modules")
        check(ArcadeMime.type(for: "profile.json").hasPrefix("application/json"), "json")
        check(ArcadeMime.type(for: "c.mp3") == "audio/mpeg" && ArcadeMime.type(for: "c.flac") == "audio/flac", "mp3 and flac")
        check(ArcadeMime.type(for: "c.ogg") == "audio/ogg" && ArcadeMime.type(for: "c.wav") == "audio/wav", "ogg and wav")
        check(ArcadeMime.type(for: "play.html").hasPrefix("text/html"), "html")
        check(ArcadeMime.type(for: "mupen64plus_next-wasm.data") == "application/octet-stream", "EmulatorJS core data")

        check(ArcadeByteRange.parse(nil, total: 10) == .whole && ArcadeByteRange.parse("items=0-1", total: 10) == .whole, "no range")
        check(ArcadeByteRange.parse("bytes=2-4", total: 10) == .part(start: 2, end: 4), "a closed range")
        check(ArcadeByteRange.parse("bytes=5-", total: 10) == .part(start: 5, end: 9), "an open range")
        check(ArcadeByteRange.parse("bytes=-3", total: 10) == .part(start: 7, end: 9), "a suffix range")
        check(ArcadeByteRange.parse("bytes=2-400", total: 10) == .part(start: 2, end: 9), "an end past the file is clipped")
        check(ArcadeByteRange.parse("bytes=10-", total: 10) == .unsatisfiable, "a start past the end")
        check(ArcadeByteRange.parse("bytes=0-1,4-5", total: 10) == .whole, "several ranges get the whole file")
        check(ArcadeByteRange.parse("bytes=4-2", total: 10) == .whole, "a backwards range is ignored")

        let fromKit = ArcadeServePlan.make(url: URL(string: "kadearcade://game/core/app.js")!, rangeHeader: nil, game: [game], kit: [kit])
        if case .serve(let blob, let offset, let length, let status, let headers) = fromKit {
            check(blob == kitBlob && offset == 0 && length == 10 && status == 200, "the game origin falls back to the kit pack")
            check(headers["Content-Type"]?.hasPrefix("text/javascript") == true && headers["Content-Length"] == "10"
                  && headers["Accept-Ranges"] == "bytes", "headers for a whole file")
        } else { check(false, "core/app.js should be served") }
        let ranged = ArcadeServePlan.make(url: URL(string: "kadearcade://game/games/demo/local/rom.z64")!, rangeHeader: "bytes=1-2", game: [game], kit: [kit])
        if case .serve(let blob, let offset, let length, let status, let headers) = ranged {
            check(blob == gameBlob && offset == 5 && length == 2 && status == 206 && headers["Content-Range"] == "bytes 1-2/6",
                  "a range inside one file of the blob")
        } else { check(false, "the ROM range should be served") }
        check(ArcadeServePlan.make(url: URL(string: "kadearcade://kit/games/demo/play.html")!, rangeHeader: nil, game: [game], kit: [kit])
              == .notFound("games/demo/play.html"), "the kit origin never serves game files")
        check(ArcadeServePlan.make(url: URL(string: "kadearcade://game/games/demo/local/rom.z64")!, rangeHeader: "bytes=6-", game: [game], kit: [kit])
              == .unsatisfiable(total: 6), "an unsatisfiable range")
        let explicitMime = ArcadeServePlan.make(url: URL(string: "kadearcade://kit/emulatorjs/loader.js")!, rangeHeader: nil, game: [], kit: [kit])
        if case .serve(_, _, _, _, let headers) = explicitMime {
            check(headers["Content-Type"] == "text/javascript", "the index's own MIME type wins")
        } else { check(false, "loader.js should be served") }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("arcade-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let blob = folder.appendingPathComponent("blob.bin")
        try Data("0123456789".utf8).write(to: blob)
        check(try ArcadeBlobReader.read(blob, offset: 2, length: 3) == Data("234".utf8), "a slice of blob.bin")
        check(try ArcadeBlobReader.read(blob, offset: 4, length: 0).isEmpty, "an empty file")
        check((try? ArcadeBlobReader.read(blob, offset: 8, length: 5)) == nil, "a short read is an error, never half a file")
        check(ArcadeHash.sha256Hex(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 of abc")
        check(try ArcadeHash.sha256Hex(of: blob) == ArcadeHash.sha256Hex(of: Data("0123456789".utf8)), "the streamed file hash matches")
        check(ArcadeHash.isHex64(String(repeating: "0", count: 64)) && !ArcadeHash.isHex64(String(repeating: "G", count: 64)), "hex checks")
    }

    // MARK: Touch: menus

    static func touchMenus() throws {
        let table = ArcadeTouchTable.standard
        check(table.flickPx == 20 && table.doubleMs == 300 && table.stickRadiusPx == 60, "the standard numbers")
        check(table.menu.doubleTaps[1] == .pulse(ArcadePadState(buttons: ["A"])) && table.menu.flicks[1]?.repeats == true, "the standard menu table")
        check(table.gestures(mode: "fight", zone: .left).taps[3] == .pulse(ArcadePadState(buttons: ["START"])), "fight halves include 'anywhere'")
        let customMenu: [String: Any] = ["tap1": ["info": "repeat"]]
        let customJSON: [String: Any] = ["flickPx": 30, "menu": customMenu]
        let custom = ArcadeTouchTable(json: customJSON)
        check(custom.flickPx == 30 && custom.tapMs == 250 && custom.menu.taps[1] == .info("repeat"), "a game's own table overrides the defaults")
        check(table.menu.holds[1] == .info("repeat") && table.menu.holdTimes[1] == 1000, "the menu's repeat hold has its own second")
        let crouchState: [String: Any] = ["buttons": ["Z"]]
        let timedHold: [String: Any] = ["hold": crouchState, "ms": 400]
        let blockState: [String: Any] = ["buttons": ["block"]]
        let untimedHold: [String: Any] = ["hold": blockState]
        let timedAnywhere: [String: Any] = ["hold2": timedHold]
        let untimedRight: [String: Any] = ["hold2": untimedHold]
        let timedFight: [String: Any] = ["anywhere": timedAnywhere, "right": untimedRight]
        let timed = ArcadeTouchTable(json: ["fight": timedFight])
        check(timed.gestures(mode: "fight", zone: .left).holdTimes[2] == 400
              && timed.gestures(mode: "fight", zone: .right).holdTimes[2] == nil,
              "a half's own hold brings its own time, or none, over the 'anywhere' one")

        // Touch and hold one second in a menu repeats the screen; lifting lets nothing go.
        var still = ArcadeTouchRecognizer()
        _ = still.start(id: 1, x: 100, y: 100, width: 400, now: 0)
        check(still.advance(to: 999).isEmpty, "a menu hold waits its own second, not the 250 ms of a block")
        check(still.advance(to: 1000) == [.info("repeat"), .haptic(.hold)], "touch and hold for a second repeats")
        check(still.end(id: 1, now: 1500).isEmpty && still.isIdle, "lifting after it does nothing more")

        // A flick fires as soon as it travels flickPx, and the pulse lets go after pulseMs.
        var r = ArcadeTouchRecognizer()
        check(r.start(id: 1, x: 100, y: 100, width: 400, now: 0).isEmpty, "a finger landing does nothing yet")
        check(r.move(id: 1, x: 100, y: 85, now: 20).isEmpty, "15 points is not a flick")
        check(r.move(id: 1, x: 100, y: 79, now: 30) == [.pad(source: "touch-p1", state: ArcadePadState(sy: -1))], "flick up steps up")
        check(r.advance(to: 129).isEmpty && r.advance(to: 130) == [.pad(source: "touch-p1", state: nil)], "the step lets go after 100 ms")
        check(r.advance(to: 1030) == [.pad(source: "touch-p2", state: ArcadePadState(sy: -1))], "a finger kept down repeats after a second")
        check(r.advance(to: 1280).contains(.pad(source: "touch-p3", state: ArcadePadState(sy: -1))), "then every 250 ms")
        check(r.end(id: 1, now: 1300).isEmpty, "lifting after a flick is not a tap")
        _ = r.advance(to: 1500)
        check(r.advance(to: 5000).isEmpty && r.isIdle, "nothing repeats after the finger lifts")

        // Double-tap accepts; a single tap waits, then does nothing (menus have no tap1).
        var d = ArcadeTouchRecognizer()
        _ = d.start(id: 1, x: 50, y: 50, width: 400, now: 1000)
        check(d.end(id: 1, now: 1080).isEmpty, "the first tap waits for a second")
        _ = d.start(id: 2, x: 52, y: 50, width: 400, now: 1200)
        check(d.end(id: 2, now: 1260) == [.pad(source: "touch-p1", state: ArcadePadState(buttons: ["A"]))], "double-tap is A")
        check(d.advance(to: 2000) == [.pad(source: "touch-p1", state: nil)], "and only the release follows")
        _ = d.start(id: 3, x: 50, y: 50, width: 400, now: 3000)
        _ = d.end(id: 3, now: 3050)
        check(d.advance(to: 3400).isEmpty, "a lone tap does nothing in menus")

        // Two fingers: tap is B after the double-tap window; double is Start and never B.
        var b = ArcadeTouchRecognizer()
        _ = b.start(id: 1, x: 100, y: 100, width: 400, now: 0)
        _ = b.start(id: 2, x: 150, y: 100, width: 400, now: 10)
        check(b.end(id: 1, now: 60).isEmpty, "the gesture waits for every finger")
        check(b.end(id: 2, now: 70).isEmpty, "a two-finger tap waits for a second one")
        check(b.advance(to: 369).isEmpty, "not before 300 ms")
        check(b.advance(to: 370) == [.pad(source: "touch-p1", state: ArcadePadState(buttons: ["B"]))], "two-finger tap is B")
        var s = ArcadeTouchRecognizer()
        for (t, base) in [(0.0, 0), (200.0, 10)] {
            _ = s.start(id: base + 1, x: 100, y: 100, width: 400, now: t)
            _ = s.start(id: base + 2, x: 150, y: 100, width: 400, now: t + 5)
            _ = s.end(id: base + 1, now: t + 50)
            let out = s.end(id: base + 2, now: t + 60)
            if t > 0 { check(out == [.pad(source: "touch-p1", state: ArcadePadState(buttons: ["START"]))], "two-finger double-tap is Start") }
        }
        check(!s.advance(to: 1000).contains(.pad(source: "touch-p1", state: ArcadePadState(buttons: ["B"]))), "and B never fires with it")

        // Three-finger flick is a C button; three-finger tap is Start at once.
        var c = ArcadeTouchRecognizer()
        for id in 1...3 { _ = c.start(id: id, x: Double(100 + id * 30), y: 200, width: 400, now: 0) }
        check(c.move(id: 1, x: 130, y: 230, now: 20).isEmpty, "one finger of three moving 30 points is 10 on average")
        check(c.move(id: 2, x: 160, y: 230, now: 21) == [.pad(source: "touch-p1", state: ArcadePadState(buttons: ["CD"]))],
              "three-finger flick down is C-down once the average travels 20")
        check(c.move(id: 3, x: 190, y: 230, now: 22).isEmpty, "and fires once")
        var t = ArcadeTouchRecognizer()
        for id in 1...3 { _ = t.start(id: id, x: Double(100 + id * 30), y: 200, width: 400, now: 0) }
        _ = t.end(id: 1, now: 40)
        _ = t.end(id: 2, now: 45)
        check(t.end(id: 3, now: 50) == [.pad(source: "touch-p1", state: ArcadePadState(buttons: ["START"]))], "three-finger tap is Start")
        var slow = ArcadeTouchRecognizer()
        _ = slow.start(id: 1, x: 50, y: 50, width: 400, now: 0)
        check(slow.end(id: 1, now: 400).isEmpty && slow.advance(to: 1000).isEmpty, "a slow touch is not a tap")
    }

    // MARK: Touch: fights

    static func touchFights() throws {
        // Left half: the floating stick, with a tick per direction and a bump at full push.
        var stick = ArcadeTouchRecognizer()
        stick.mode = "fight"
        _ = stick.start(id: 1, x: 50, y: 300, width: 400, now: 0)
        check(stick.move(id: 1, x: 50, y: 320, now: 20) == [.pad(source: "touch-stick-left", state: ArcadePadState(sy: 0.34)), .haptic(.direction)],
              "sliding down a third of the radius backs away a third, with a tick")
        check(stick.move(id: 1, x: 50, y: 380, now: 40) == [.pad(source: "touch-stick-left", state: ArcadePadState(sy: 1)), .haptic(.fullPush)],
              "full push is capped at 1, with a bump and no second tick")
        check(stick.move(id: 1, x: 110, y: 380, now: 60).contains(.haptic(.direction)), "a new direction ticks again")
        check(stick.advance(to: 1000).isEmpty, "a moving stick is never a hold")
        check(stick.end(id: 1, now: 1100) == [.pad(source: "touch-stick-left", state: nil)], "lifting lets the stick go")
        var target = ArcadeTouchRecognizer()
        target.mode = "fight"
        _ = target.start(id: 1, x: 50, y: 300, width: 400, now: 0)
        check(target.end(id: 1, now: 100) == [.pad(source: "touch-p1", state: ArcadePadState(buttons: ["A"]))], "a quick left tap changes target")

        // Right half: attacks fire on travel, a tap jumps, a hold blocks.
        var attack = ArcadeTouchRecognizer()
        attack.mode = "fight"
        _ = attack.start(id: 1, x: 300, y: 300, width: 400, now: 0)
        check(attack.move(id: 1, x: 279, y: 300, now: 30) == [.pad(source: "touch-p1", state: ArcadePadState(buttons: ["CL"]))],
              "flick left is the weak punch, before the finger lifts")
        check(attack.move(id: 1, x: 250, y: 260, now: 40).isEmpty, "one flick, one attack")
        var jump = ArcadeTouchRecognizer()
        jump.mode = "fight"
        _ = jump.start(id: 1, x: 300, y: 300, width: 400, now: 0)
        check(jump.end(id: 1, now: 90) == [.pad(source: "touch-p1", state: ArcadePadState(buttons: ["R"]))], "a quick right tap jumps")
        var block = ArcadeTouchRecognizer()
        block.mode = "fight"
        _ = block.start(id: 1, x: 300, y: 300, width: 400, now: 0)
        check(block.advance(to: 249).isEmpty, "no block before 250 ms")
        check(block.advance(to: 250) == [.pad(source: "touch-hold-right", state: ArcadePadState(buttons: ["block"])), .haptic(.hold)], "holding still blocks")
        check(block.move(id: 1, x: 340, y: 300, now: 300).isEmpty, "moving while blocking does not attack")
        check(block.end(id: 1, now: 900) == [.pad(source: "touch-hold-right", state: nil)], "lifting stops the block")
        var crouch = ArcadeTouchRecognizer()
        crouch.mode = "fight"
        _ = crouch.start(id: 1, x: 300, y: 300, width: 400, now: 0)
        _ = crouch.start(id: 2, x: 340, y: 320, width: 400, now: 20)
        check(crouch.advance(to: 260).isEmpty, "the hold clock restarts when the second finger lands")
        check(crouch.advance(to: 270) == [.pad(source: "touch-hold-right", state: ArcadePadState(buttons: ["Z"])), .haptic(.hold)], "a two-finger hold crouches")
        var surprise = ArcadeTouchRecognizer()
        surprise.mode = "fight"
        _ = surprise.start(id: 1, x: 300, y: 300, width: 400, now: 0)
        _ = surprise.start(id: 2, x: 340, y: 300, width: 400, now: 10)
        _ = surprise.end(id: 1, now: 60)
        check(surprise.end(id: 2, now: 70) == [.pad(source: "touch-p1", state: ArcadePadState(buttons: ["B"]))], "a two-finger right tap is B at once")

        // Left half, two fingers: information.
        var info = ArcadeTouchRecognizer()
        info.mode = "fight"
        _ = info.start(id: 1, x: 50, y: 300, width: 400, now: 0)
        _ = info.start(id: 2, x: 90, y: 300, width: 400, now: 5)
        check(info.move(id: 1, x: 50, y: 270, now: 30).isEmpty, "half the fingers moving is not yet a flick")
        check(info.move(id: 2, x: 90, y: 270, now: 35) == [.info("health")], "two-finger flick up asks for health")
        var pause = ArcadeTouchRecognizer()
        pause.mode = "fight"
        for (id, x) in [(1, 50.0), (2, 100.0), (3, 350.0)] { _ = pause.start(id: id, x: x, y: 300, width: 400, now: 0) }
        _ = pause.end(id: 1, now: 30)
        _ = pause.end(id: 2, now: 35)
        check(pause.end(id: 3, now: 40) == [.pad(source: "touch-p1", state: ArcadePadState(buttons: ["START"]))], "three fingers anywhere pause")

        // The mode is read when a gesture starts, and everything can be let go at once.
        var change = ArcadeTouchRecognizer()
        _ = change.start(id: 1, x: 300, y: 300, width: 400, now: 0)
        change.mode = "fight"
        check(change.move(id: 1, x: 279, y: 300, now: 30) == [.pad(source: "touch-p1", state: ArcadePadState(sx: -1))], "a menu gesture stays a menu gesture")
        var held = ArcadeTouchRecognizer()
        held.mode = "fight"
        _ = held.start(id: 1, x: 300, y: 300, width: 400, now: 0)
        _ = held.advance(to: 300)
        check(held.releaseAll() == [.pad(source: "touch-hold-right", state: nil)] && held.isIdle, "release all lets go of a held block")
        check(ArcadeTouchRecognizer.sector(dx: 1, dy: 0) == 0 && ArcadeTouchRecognizer.sector(dx: 0, dy: -1) == 2
              && ArcadeTouchRecognizer.sector(dx: -1, dy: 0) == 4 && ArcadeTouchRecognizer.sector(dx: 0, dy: 1) == 6, "eight directions")
        check(ArcadeTouchRecognizer.quantize(0.333) == 0.34 && ArcadeTouchRecognizer.quantize(-0.004) == 0, "stick steps of 0.02")

        // The two halves side by side: the left thumb holds the stick while the right one attacks.
        var both = ArcadeTouchRecognizer()
        both.mode = "fight"
        _ = both.start(id: 1, x: 50, y: 300, width: 400, now: 0)
        check(both.move(id: 1, x: 50, y: 330, now: 20) == [.pad(source: "touch-stick-left", state: ArcadePadState(sy: 0.5)), .haptic(.direction)],
              "the left thumb takes the stick")
        check(both.start(id: 2, x: 300, y: 300, width: 400, now: 100).isEmpty, "a right thumb landing does nothing yet")
        check(both.fingersDown == 2, "two thumbs down")
        check(both.move(id: 2, x: 279, y: 300, now: 130) == [.pad(source: "touch-p1", state: ArcadePadState(buttons: ["CL"]))],
              "a right flick attacks while the left thumb holds the stick")
        check(both.move(id: 1, x: 50, y: 360, now: 140) == [.pad(source: "touch-stick-left", state: ArcadePadState(sy: 1)), .haptic(.fullPush)],
              "and the stick keeps following the left thumb afterwards")
        check(both.end(id: 2, now: 200).isEmpty, "lifting the right thumb leaves the stick alone")
        check(both.move(id: 1, x: 50, y: 330, now: 220) == [.pad(source: "touch-stick-left", state: ArcadePadState(sy: 0.5))],
              "the stick still moves after the attack")
        check(both.end(id: 1, now: 300) == [.pad(source: "touch-stick-left", state: nil)], "lifting the left thumb lets the stick go")

        // A block held on the right while the left thumb walks.
        var guarded = ArcadeTouchRecognizer()
        guarded.mode = "fight"
        _ = guarded.start(id: 1, x: 300, y: 300, width: 400, now: 0)
        check(guarded.advance(to: 250) == [.pad(source: "touch-hold-right", state: ArcadePadState(buttons: ["block"])), .haptic(.hold)],
              "the right thumb blocks")
        _ = guarded.start(id: 2, x: 50, y: 300, width: 400, now: 300)
        check(guarded.move(id: 2, x: 50, y: 270, now: 320) == [.pad(source: "touch-stick-left", state: ArcadePadState(sy: -0.5)), .haptic(.direction)],
              "and the left thumb still walks while blocking")
        check(guarded.end(id: 2, now: 400) == [.pad(source: "touch-stick-left", state: nil)], "lifting the left thumb lets only the stick go")
        check(guarded.end(id: 1, now: 500) == [.pad(source: "touch-hold-right", state: nil)] && guarded.isIdle,
              "lifting the right thumb stops the block")

        // Two thumbs tapping together are a left tap and a right tap, never a two-finger tap.
        var thumbs = ArcadeTouchRecognizer()
        thumbs.mode = "fight"
        _ = thumbs.start(id: 1, x: 50, y: 300, width: 400, now: 0)
        _ = thumbs.start(id: 2, x: 300, y: 300, width: 400, now: 10)
        check(thumbs.end(id: 1, now: 60).isEmpty, "a left tap waits while it might be part of a three-finger pause")
        check(thumbs.end(id: 2, now: 70) == [.pad(source: "touch-p1", state: ArcadePadState(buttons: ["A"])),
                                             .pad(source: "touch-p2", state: ArcadePadState(buttons: ["R"]))],
              "then both taps happen: change target and jump")

        // A held-back tap goes out once the three-finger tap is no longer possible.
        var waiting = ArcadeTouchRecognizer()
        waiting.mode = "fight"
        _ = waiting.start(id: 1, x: 50, y: 300, width: 400, now: 0)
        _ = waiting.start(id: 2, x: 300, y: 300, width: 400, now: 50)
        check(waiting.end(id: 2, now: 100).isEmpty, "a right tap beside a resting left thumb waits a moment")
        check(waiting.advance(to: 249).isEmpty, "at most until the tap time from the first finger")
        check(waiting.advance(to: 250) == [.pad(source: "touch-p1", state: ArcadePadState(buttons: ["R"]))], "then the jump goes out")
        var moved = ArcadeTouchRecognizer()
        moved.mode = "fight"
        _ = moved.start(id: 1, x: 50, y: 300, width: 400, now: 0)
        _ = moved.start(id: 2, x: 300, y: 300, width: 400, now: 50)
        _ = moved.end(id: 2, now: 100)
        check(moved.move(id: 1, x: 50, y: 330, now: 120) == [.pad(source: "touch-stick-left", state: ArcadePadState(sy: 0.5)), .haptic(.direction),
                                                             .pad(source: "touch-p1", state: ArcadePadState(buttons: ["R"]))],
              "or at once when the left thumb starts to move")

        // A still two-finger hold on the left repeats the last line (its own one-second time).
        var again = ArcadeTouchRecognizer()
        again.mode = "fight"
        _ = again.start(id: 1, x: 50, y: 300, width: 400, now: 0)
        _ = again.start(id: 2, x: 90, y: 300, width: 400, now: 5)
        check(again.advance(to: 1004).isEmpty, "not before its second")
        check(again.advance(to: 1005) == [.info("repeat"), .haptic(.hold)], "a two-finger hold on the left repeats the last line")
        check(again.end(id: 1, now: 1100).isEmpty && again.end(id: 2, now: 1110).isEmpty, "and lifting lets nothing go")

        // The stick's direction ticks have some give at each edge.
        var edge = ArcadeTouchRecognizer()
        edge.mode = "fight"
        _ = edge.start(id: 1, x: 50, y: 300, width: 400, now: 0)
        check(edge.move(id: 1, x: 89.47, y: 285.64, now: 10).contains(.haptic(.direction)), "20 degrees up from right: the right-hand direction")
        check(!edge.move(id: 1, x: 88.06, y: 282.25, now: 20).contains(.haptic(.direction)), "25 degrees, just past the edge: no tick yet")
        check(edge.move(id: 1, x: 84.40, y: 275.91, now: 30).contains(.haptic(.direction)), "35 degrees, well past it: up-right ticks")
        check(!edge.move(id: 1, x: 88.06, y: 282.25, now: 40).contains(.haptic(.direction)), "back to 25 degrees: up-right holds")
        check(!edge.move(id: 1, x: 63.27, y: 290.71, now: 50).contains(.haptic(.direction)), "pulled back to 0.27 of a push: still up-right")
        check(!edge.move(id: 1, x: 59.83, y: 293.12, now: 60).contains(.haptic(.direction)), "0.2: the direction is let go, quietly")
        check(!edge.move(id: 1, x: 63.27, y: 290.71, now: 70).contains(.haptic(.direction)), "0.27 again is not enough to enter")
        check(edge.move(id: 1, x: 67.20, y: 287.95, now: 80).contains(.haptic(.direction)), "0.35 enters again, with a tick")
        check(ArcadeTouchRecognizer.nextSector(current: 0, dx: 1, dy: -0.47) == 0
              && ArcadeTouchRecognizer.nextSector(current: 0, dx: 1, dy: -0.7) == 1
              && ArcadeTouchRecognizer.nextSector(current: 6, dx: 0.6, dy: 0.8) == 7, "the give is about 8 degrees past an edge")
    }

    // MARK: Controllers and keyboards

    static func controllersAndKeys() {
        var mapper = ArcadeGamepadMapper()
        var snap = ArcadeGamepadSnapshot()
        snap.pressed[2] = true   // X
        snap.pressed[7] = true   // RT
        snap.axes = [0.5, -1, 0, 0]
        let fight = mapper.apply(snap, mode: "fight")
        check(fight.state == ArcadePadState(sx: 0.5, sy: -1, buttons: ["CL", "block"]) && fight.info.isEmpty, "fight: X punches, RT blocks, the stick moves")
        var dpad = ArcadeGamepadSnapshot()
        dpad.pressed[12] = true
        check(mapper.apply(dpad, mode: "fight").info == ["where"], "d-pad up asks where everyone is")
        check(mapper.apply(dpad, mode: "fight").info.isEmpty, "an info button fires on press only")
        check(mapper.apply(ArcadeGamepadSnapshot(), mode: "fight").state.isEmpty, "a resting controller is empty")
        check(mapper.apply(dpad, mode: "fight").info == ["where"], "and fires again on the next press")
        var menu = ArcadeGamepadSnapshot()
        menu.pressed[0] = true
        menu.pressed[14] = true
        menu.pressed[10] = true
        menu.axes = [0.1, 0, 0.8, 0]
        let inMenu = mapper.apply(menu, mode: "menu")
        check(inMenu.state.buttons == ["A", "CR"] && inMenu.state.sx == -1 && inMenu.state.sy == 0, "menus: A accepts, the d-pad moves, the right stick is C, small tilts are ignored")
        check(inMenu.info == ["repeat"], "the left stick button repeats outside fights")
        var start = ArcadeGamepadSnapshot()
        start.pressed[9] = true
        check(mapper.apply(start, mode: "fight").state.buttons == ["START"], "Menu is Start everywhere")
        let pair: [Any] = [0, "A"]
        let customJSON: [String: Any] = ["fight": [pair], "info": ["3": "time"]]
        let custom = ArcadeGamepadMap(json: customJSON)
        check(custom.fight == [ArcadeButtonBinding(index: 0, name: "A")] && custom.info[3] == "time" && !custom.dpadMovesInMenus, "a game's own map")

        check(ArcadeKeys.browserKey(hidUsage: 0x04) == "a" && ArcadeKeys.browserKey(hidUsage: 0x1D) == "z", "letters")
        check(ArcadeKeys.browserKey(hidUsage: 0x1E) == "1" && ArcadeKeys.browserKey(hidUsage: 0x26) == "9" && ArcadeKeys.browserKey(hidUsage: 0x27) == "0", "digits")
        check(ArcadeKeys.browserKey(hidUsage: 0x28) == "Enter" && ArcadeKeys.browserKey(hidUsage: 0x2A) == "Backspace"
              && ArcadeKeys.browserKey(hidUsage: 0x2C) == " " && ArcadeKeys.browserKey(hidUsage: 0x3A) == "F1", "Enter, Backspace, Space and F1")
        check(ArcadeKeys.browserKey(hidUsage: 0x52) == "ArrowUp" && ArcadeKeys.browserKey(hidUsage: 0x50) == "ArrowLeft", "arrows")
        check(ArcadeKeys.browserKey(hidUsage: ArcadeKeys.escapeUsage) == nil && ArcadeKeys.browserKey(hidUsage: 0x2B) == nil, "Escape and Tab never reach the game")
        check(ArcadeKeys.isBlockingModifier(hidUsage: 0xE0) && !ArcadeKeys.isBlockingModifier(hidUsage: 0xE1), "Control blocks, Shift does not")
    }

    // MARK: The page bridge, words and the report

    static func javascriptAndWords() {
        check(ArcadeJS.literal("a\"b") == "\"a\\\"b\"" && ArcadeJS.literal("x/y") == "\"x/y\"", "string literals")
        check(ArcadeJS.number(0.5) == "0.5" && ArcadeJS.number(1) == "1" && ArcadeJS.number(-0.0001) == "0"
              && ArcadeJS.number(-0.333333) == "-0.333" && ArcadeJS.number(.nan) == "0", "numbers")
        check(ArcadeJS.pad(source: "touch-p1", state: ArcadePadState(buttons: ["A"]))
              == #"window.revivalKit&&window.revivalKit.pad({"sx":0,"sy":0,"buttons":["A"]},"touch-p1");void 0"#, "a pad call")
        check(ArcadeJS.pad(source: "touch-stick", state: nil) == #"window.revivalKit&&window.revivalKit.pad(null,"touch-stick");void 0"#, "letting a source go")
        check(ArcadeJS.padObject(ArcadePadState(sx: -0.5, buttons: [], info: ["health"])) == #"{"sx":-0.5,"sy":0,"buttons":[],"info":["health"]}"#, "info rides along")
        check(ArcadeJS.info("health") == #"window.revivalKit&&window.revivalKit.info("health");void 0"#, "an info call")
        check(ArcadeJS.press(key: "Enter", down: false) == #"window.revivalKit&&window.revivalKit.press("Enter",false);void 0"#, "a key call")
        let script = ArcadeJS.hostScript(base: "kadearcade://game/games/demo/", emulatorData: "kadearcade://game/emulatorjs/", settings: ["speechMode": "native"])
        for piece in ["base: \"kadearcade://game/games/demo/\"", "emulatorData: \"kadearcade://game/emulatorjs/\"", "autoStart: true",
                      "storage: false", "touch: false,", "layout: 'full',", "speechFallback: 'native'", "settings: {\"speechMode\":\"native\"}", "messageHandlers.arcade",
                      "speechRoutes", "onEvent"] {
            check(script.contains(piece), "the host script sets " + piece)
        }
        check(ArcadeJS.hostScript(base: "b", emulatorData: "d", settings: [:]).contains("settings: {}"), "no settings is an empty object")
        let full = ArcadeJS.hostScript(base: "b", emulatorData: "d", settings: [:], inputType: "touch", saveData: "AAEC")
        check(full.contains("inputType: \"touch\",") && full.contains("saveData: \"AAEC\",") && full.contains("touch: false,"),
              "the host script names the input, carries the kept save and leaves gestures to the app")
        check(!ArcadeJS.hostScript(base: "b", emulatorData: "d", settings: [:]).contains("saveData"), "no kept save, no saveData")
        check(ArcadeJS.setInputType("gamepad")
              == #"window.revivalKit&&window.revivalKit.setInputType&&window.revivalKit.setInputType("gamepad");void 0"#, "the button words call")
        check(ArcadeJS.saveNowForLeaving.contains("k.saveNow()") && ArcadeJS.saveNowForLeaving.contains("r.state === 'saved'"),
              "leaving asks the page for the save itself")

        check(ArcadeText.size(45_200_000) == "45 MB" && ArcadeText.size(4_500_000) == "4.5 MB"
              && ArcadeText.size(500_000) == "under 1 MB" && ArcadeText.size(0) == "size not known yet", "sizes in words")
        var speaker = ArcadeProgressSpeaker()
        check(speaker.next(fraction: 0.1) == nil && speaker.next(fraction: 0.26) == 25 && speaker.next(fraction: 0.3) == nil, "25 percent once")
        check(speaker.next(fraction: 0.55) == 50 && speaker.next(fraction: 1) == nil && speaker.next(fraction: 0.8) == 75, "50 and 75; the end has its own line")

        var telemetry = ArcadeTelemetry()
        telemetry.title = "Demo"
        telemetry.gameId = "demo"
        telemetry.version = "1"
        telemetry.openedAt = Date(timeIntervalSince1970: 0)
        telemetry.terminations = 1
        telemetry.note(event: "mode", detail: ["mode": "fight", "screen": "fight"])
        telemetry.note(event: "telemetry", detail: ["fps": 58, "heap": ["bytes": 268435456], "contexts": ["running", "running"]])
        telemetry.note(event: "error", detail: ["what": "ram"])
        for n in 0..<12 { telemetry.note(error: "page error \(n)") }
        let report = telemetry.report(now: Date(timeIntervalSince1970: 125))
        check(report.contains("Game: Demo (demo 1)") && report.contains("Open for 2 min 5 s"), "the report names the game and the time")
        check(report.contains("Web content stopped: 1") && report.contains("Mode: fight"), "the report has the counters and the mode")
        check(report.contains("fps=58") && report.contains("heap.bytes=268435456") && report.contains("contexts=2 items"), "kit telemetry is flattened")
        check(telemetry.errors.count == 8 && telemetry.errors.last == "page error 11", "only the last eight errors are kept")
        check(telemetry.eventCounts["mode"] == 1 && telemetry.eventCounts["error"] == 1, "events are counted")
    }
}
