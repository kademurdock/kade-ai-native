import Foundation
import CryptoKit

// The Arcade's pure models (Sources/ArcadeModels.swift and, since Oct 19 2026,
// Sources/ArcadeImport.swift), compiled by
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
        startWatched()
        savesKept()
        soundAndScreenText()
        updates()
        try addAGame()
        print("Arcade models: \(checks) checks passed. Covers catalog and shelf gating, manifests, signed links, pack indexes, the kadearcade:// routing, MIME types and byte ranges, the touch recognizer's menu and fight tables (both halves at once, taps across them, hold times, the stick's edges), the controller map, keyboard names, the page bridge script, the start watch (its countdown from the load and from 'started', away and back, one line per load, the RAM finder's own line ending a start, and the page errors and missing EmulatorJS files that mean a start failed), updates (a newer game player with the game's own version the same, its size with the game pack on the phone, the old player let go once nothing uses it, Play's question for a newer game too, kits nothing uses swept, and the start failure line naming it), kept saves, where the sound goes (every port type to the kit's six route words, a USB output by its name, USB-C earphones by any of theirs, several outputs at once, the setOutput and setSettings calls, the app's line when headphones go only where the game does not say the new route itself) and the kit's settings kept beside the save and given back under the app's own switches (headphones starting on Stereo, its per-route choices kept as given, each Sound picker naming the route its choice is kept for, an added game's plain player keeping none so its settings and its pack's never cross), the screen's text, its title and why the list is empty, game reports and the how-it-ran text, and Add a game (systems, No-Intro sha1 and crc32, N64 byte orders, the zip reader with stored and deflated entries, the import store, /match and each row's status, the server's exact unlocked and locked answers, the access manifest's plan, pack updates, answers heard under another account, the ROM served at its pack path, and the plain player's per-system controls from the kit's systems.json: named touch zones held as presses, Select, the d-pad); not WebKit, VoiceOver, haptics, GameController or a real download.")
    }

    // MARK: A start that never finishes

    static func startWatched() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

        var watch = ArcadeStartWatch()
        check(watch.deadline == nil && !watch.due(now: at(10_000)), "nothing is due before a page loads")
        watch.load(now: t0)
        check(watch.starting && !watch.due(now: at(89)) && watch.due(now: at(90)),
              "from the page load, in case 'started' never comes: 90 seconds")
        watch.started(now: at(30))
        check(!watch.due(now: at(119)) && watch.due(now: at(120)), "the kit's 'started' starts the countdown over")
        watch.away()
        check(watch.isAway && watch.deadline == nil && !watch.due(now: at(5_000)), "never while she is away")
        watch.started(now: at(510))
        check(watch.deadline == nil, "a 'started' while away starts nothing")
        watch.back(now: at(600))
        check(!watch.isAway && !watch.due(now: at(689)) && watch.due(now: at(690)), "her return starts the countdown over")
        check(watch.claim() && !watch.starting && watch.deadline == nil && !watch.due(now: at(1_000)),
              "the failure is said, and the countdown stops")
        check(!watch.claim(), "once per load, whatever else says it")
        watch.back(now: at(1_100))
        check(watch.deadline == nil, "a start already said gets no new countdown on her return")
        watch.load(now: at(2_000))
        check(watch.starting && watch.due(now: at(2_090)) && watch.claim(), "a reload starts over, with a line of its own")

        watch.load(now: at(3_000))
        watch.becameReady()
        check(!watch.starting && watch.deadline == nil && !watch.due(now: at(9_000)), "'ready' ends the watch")
        watch.started(now: at(3_100))
        watch.away()
        watch.back(now: at(3_200))
        check(watch.deadline == nil && !watch.due(now: at(9_000)), "after 'ready', no 'started' or return brings it back")
        check(watch.claim() && !watch.claim(), "the kit's own 'error' after 'ready' is still said, once")

        var awayAtLoad = ArcadeStartWatch()
        awayAtLoad.away()
        awayAtLoad.load(now: t0)
        check(awayAtLoad.deadline == nil && !awayAtLoad.due(now: at(500)), "a page loaded while she is away waits for her")
        awayAtLoad.back(now: at(600))
        check(awayAtLoad.due(now: at(690)) && !awayAtLoad.due(now: at(689)), "and counts from her return")

        // The RAM finder gave up: the kit said its own line and no 'ready' follows.
        var ramGaveUp = ArcadeStartWatch()
        ramGaveUp.load(now: t0)
        ramGaveUp.started(now: at(5))
        check(ArcadeStartWatch.kitEndedStart("ram") && ramGaveUp.claim(), "the kit's 'ram' error takes the load's one line")
        check(ramGaveUp.deadline == nil && !ramGaveUp.due(now: at(95)) && !ramGaveUp.due(now: at(10_000)),
              "and nothing is due after it: no second line a minute later")
        ramGaveUp.away()
        ramGaveUp.back(now: at(200))
        check(ramGaveUp.deadline == nil && !ramGaveUp.due(now: at(10_000)), "not after her return either")
        for what in ["emulator", "start", "system", "save", ""] {
            check(!ArcadeStartWatch.kitEndedStart(what), "only the RAM finder's error ends a start on the kit's own line, not '\(what)'")
        }

        check(ArcadeStartWatch.limit == 90, "the countdown is 90 seconds")
        check(ArcadeStartWatch.status == "The game did not start"
              && ArcadeStartWatch.line == "The game did not start. Open Settings and choose Report a problem with this game, or leave and try again.",
              "what the countdown says, and the status it leaves")
        check(ArcadeStartWatch.couldNotStartLine == "The game could not start. Open Settings and choose Report a problem with this game.",
              "a start failure seen at once says the kit error's line")

        for message in ["ReferenceError: Can't find variable: EJS_Runtime", "EJS_Runtime is not defined",
                        "Error loading EmulatorJS runtime", "Failed to download the core", "Network Error",
                        "Could not start the game", "TypeError: could not read the core", "ejs_runtime"] {
            check(ArcadeStartWatch.isStartError(message), "a start failure: " + message)
        }
        for message in ["", "error", "unhandled rejection", "TypeError: undefined is not an object (evaluating 'a.b')",
                        "NotAllowedError: The request is not allowed by the user agent", "Script error."] {
            check(!ArcadeStartWatch.isStartError(message), "not a start failure: " + message)
        }

        for path in ["emulatorjs/cores/mupen64plus_next-legacy-wasm.data", "emulatorjs/cores/fceumm-wasm.data",
                     "emulatorjs/loader.js", "emulatorjs/emulator.min.js", "emulatorjs/compression/extract7z.js",
                     "emulatorjs/src/emulator.js"] {
            check(ArcadeStartWatch.isMissingEmulatorFile(path, emulatorData: "emulatorjs/"), "EmulatorJS cannot start without " + path)
        }
        for path in ["emulatorjs/localization/en-GB.json", "emulatorjs/cores/reports/fceumm.json", "emulatorjs/emulator.min.css",
                     "emulatorjs/emulator.css", "emulatorjs/emulator.min.js.map", "emulatorjs/cores/", "emulatorjs/",
                     "games/demo/local/rom.z64", "games/_plain/local/demo.gb", "core/app.js", "(no address)",
                     "kadearcade://other/emulatorjs/loader.js", "emulator/loader.js"] {
            check(!ArcadeStartWatch.isMissingEmulatorFile(path, emulatorData: "emulatorjs/"), "the game can start without " + path)
        }
        check(ArcadeStartWatch.isMissingEmulatorFile("ejs/cores/demo-wasm.data", emulatorData: "ejs/")
              && ArcadeStartWatch.isMissingEmulatorFile("ejs/loader.js", emulatorData: "ejs")
              && ArcadeStartWatch.isMissingEmulatorFile("emulatorjs/loader.js", emulatorData: "ejs/")
              && !ArcadeStartWatch.isMissingEmulatorFile("ejs/localization/fr-FR.json", emulatorData: "ejs/"),
              "the kit's own emulatorData folder counts, with or without its slash, and so does emulatorjs/")
        check(!ArcadeStartWatch.isMissingEmulatorFile("loader.js", emulatorData: "")
              && ArcadeStartWatch.isMissingEmulatorFile("emulatorjs/loader.js", emulatorData: ""),
              "an empty folder never makes every missing file count")
    }

    // MARK: Updates (Oct 19 2026, build 340)
    //
    // The server moved every game to a new kit (the game player) while each
    // game's own version stayed the same; the app counted only the game's
    // version and launched the old kit forever.

    static func updates() {
        let kitOld = "20261018-27899e08"
        let kitNew = "20261019-dd55f62f"

        check(ArcadeUpdate.of(catalogVersion: "20261018-63fdca17", installedVersion: "20261018-63fdca17",
                              installedKit: kitOld, shelfKit: kitNew) == .player,
              "the same game version on an older game player is an update (build 340 launched the old one forever)")
        check(ArcadeUpdate.of(catalogVersion: "g1", installedVersion: "g1", installedKit: kitNew, shelfKit: kitNew) == .current,
              "the same game on the shelf's player: nothing to update")
        check(ArcadeUpdate.of(catalogVersion: "g2", installedVersion: "g1", installedKit: kitNew, shelfKit: kitNew) == .game,
              "a newer game is an update, as before")
        check(ArcadeUpdate.of(catalogVersion: "g2", installedVersion: "g1", installedKit: kitOld, shelfKit: kitNew) == .game,
              "a newer game brings the shelf's player with it: one update, said as the game's")
        check(ArcadeUpdate.of(catalogVersion: "g1", installedVersion: nil, installedKit: nil, shelfKit: kitNew) == .current,
              "not downloaded: nothing to update")
        check(ArcadeUpdate.of(catalogVersion: "g1", installedVersion: "g1", installedKit: kitOld, shelfKit: nil) == .current,
              "a shelf that names no player: nothing to compare")
        check(ArcadeUpdate.of(catalogVersion: "g1", installedVersion: "g1", installedKit: nil, shelfKit: kitNew) == .current,
              "an install with no player pack: nothing to compare")
        check(ArcadeUpdate.isNewerKit(shelf: kitOld, installed: kitNew), "a player the server rolled back to is the one to have")
        check(!ArcadeUpdate.isNewerKit(shelf: "", installed: kitOld) && !ArcadeUpdate.isNewerKit(shelf: kitNew, installed: ""),
              "an empty version is no version")
        check(!ArcadeUpdate.current.isUpdate && ArcadeUpdate.game.isUpdate && ArcadeUpdate.player.isUpdate,
              "a newer player shows Download the update like a newer game")
        check(ArcadeUpdate.current.captionTail == ", downloaded" && ArcadeUpdate.game.captionTail == ", update ready"
              && ArcadeUpdate.player.captionTail == ", update ready: a newer game player", "the row's caption says which update")
        check(ArcadeUpdate.current.playValue == "Downloaded" && ArcadeUpdate.game.playValue == "Downloaded. An update is ready."
              && ArcadeUpdate.player.playValue == "Downloaded. Update ready: a newer game player.", "and so does Play's value")
        check(ArcadeUpdate.buttonTitle == "Download the update", "the button the failure line names")

        // One game, the same version, first on the old player, then on the new one.
        let gameSha = String(repeating: "ab", count: 32)
        func manifest(kit version: String, size: Int64, sha: String) -> ArcadeManifest {
            ArcadeManifest(id: "demo", version: "g1", entry: "games/demo/play.html", base: "games/demo/", emulatorData: "emulatorjs/",
                           packs: [ArcadePackRef(kind: "kit", id: "kit", version: version, size: size, sha256: sha),
                                   ArcadePackRef(kind: "game", id: "demo", version: "g1", size: 45_200_000, sha256: gameSha)])
        }
        let oldManifest = manifest(kit: kitOld, size: 6_900_000, sha: String(repeating: "cd", count: 32))
        let newManifest = manifest(kit: kitNew, size: 7_000_000, sha: String(repeating: "ef", count: 32))
        let oldRecord = ArcadeInstallRecord(manifest: oldManifest, title: "Demo")
        let newRecord = ArcadeInstallRecord(manifest: newManifest, title: "Demo")
        let oldKitKey = "kit/" + kitOld
        let newKitKey = "kit/" + kitNew
        check(oldRecord.kitVersion == kitOld && newRecord.kitVersion == kitNew && newManifest.kitVersion == kitNew,
              "a record and a manifest name the player they run on")
        check(ArcadeUpdate.of(catalogVersion: "g1", installedVersion: oldRecord.version, installedKit: oldRecord.kitVersion,
                              shelfKit: kitNew) == .player, "the installed record on the old player waits for the new one")

        // The offer: the game pack is on the phone and only the player is new.
        let onPhone = oldRecord.packKeys
        check(onPhone == [oldKitKey, "demo/g1"], "the packs the old install reads")
        check(newManifest.bytesMissing(installed: onPhone) == 7_000_000,
              "with the game pack on the phone, the update is the player's size alone")
        check(ArcadeUpdate.playerQuestion(bytes: newManifest.bytesMissing(installed: onPhone))
              == "A newer game player is ready, 7.0 MB. Download it first?", "Play's one question, with the size")
        check(newManifest.bytesMissing(installed: onPhone.union([newKitKey])) == 0,
              "a player another game already brought: nothing to download, put to use at once")

        // Oct 19 2026 review: Play asks first on every update. A newer game
        // started on its old record would run the old player as well.
        check(ArcadeUpdate.question(.player, bytes: 7_000_000) == ArcadeUpdate.playerQuestion(bytes: 7_000_000),
              "a newer game player keeps its own question")
        check(ArcadeUpdate.question(.game, bytes: 52_200_000)
              == "A newer version of this game is ready, 52 MB. Download it first?",
              "a newer game asks too, in its own words, before Play starts the old one on its old player")
        check(ArcadeUpdate.question(.game, bytes: 7_000_000).hasPrefix("A newer version of this game is ready, 7.0 MB."),
              "with the size")
        check(ArcadeUpdate.player.checkingLine == "Checking the newer game player's size."
              && ArcadeUpdate.game.checkingLine == "Checking the update's size.",
              "Play says it is checking, since the button gives no other sign")
        check(ArcadeUpdate.stillChecking == "Still checking the size."
              && ArcadeUpdate.otherChecking == "Another game is being checked. Try again in a moment.",
              "a press while a size is checked is answered, never dropped")

        // Oct 19 2026 review: kits nothing uses go once the shelf answers, so
        // one left by a killed app or a deleted game does not stay for good.
        let kitMid = "20261019-7ae651dc"
        let kitsOnPhone: [String: Bool] = [kitOld: true, kitMid: true, kitNew: true, "20261017-00000000": false]
        check(ArcadeUpdate.sweptKits(id: "kit", onPhone: kitsOnPhone, used: [oldKitKey, "demo/g1"], keep: [newKitKey])
              == ["kit/" + kitMid],
              "only a whole kit no install uses and nothing keeps goes")
        check(ArcadeUpdate.sweptKits(id: "kit", onPhone: kitsOnPhone, used: [], keep: [newKitKey]) == [oldKitKey, "kit/" + kitMid],
              "an old kit left behind when nothing reads it any more goes")
        check(!ArcadeUpdate.sweptKits(id: "kit", onPhone: kitsOnPhone, used: [], keep: []).contains("kit/20261017-00000000"),
              "a stopped download stays, so it can resume")
        check(ArcadeUpdate.sweptKits(id: "kit", onPhone: [kitNew: true], used: [], keep: [newKitKey]).isEmpty,
              "the shelf's own kit stays, used or not")
        check(ArcadeUpdate.sweptKits(id: "kit", onPhone: [:], used: [], keep: []).isEmpty, "no kits, nothing to do")

        // One record per game version: the new one is written over the old,
        // and the old player is let go once nothing uses it.
        check(oldRecord.version == newRecord.version && oldRecord != newRecord,
              "the new record has the same game version, so it takes the old one's place")
        let retired = oldRecord.retired(by: newRecord)
        check(retired == [oldKitKey], "the new record lets go of the old player only, never the game pack")
        check(newRecord.retired(by: newRecord).isEmpty, "writing the same record again lets nothing go")
        let used = newRecord.packKeys.union(["demo/g1"])
        let free = ArcadeUpdate.letGo(retired, used: used, protecting: [])
        check(free.remove == [oldKitKey] && free.wait.isEmpty, "nothing else on the phone uses the old player: it goes")
        let playing = ArcadeUpdate.letGo(retired, used: used, protecting: oldRecord.packKeys.union(["demo/g1"]))
        check(playing.remove.isEmpty && playing.wait == [oldKitKey],
              "a game open on the old player (Play anyway while the update downloaded) keeps it until it closes")
        let shared = ArcadeUpdate.letGo(retired, used: used.union([oldKitKey]), protecting: [oldKitKey])
        check(shared.remove.isEmpty && shared.wait.isEmpty,
              "another game, or a game added from Files, still on the old player keeps it, open or not")

        // A start that fails on the old player names the newer one.
        check(ArcadeStartWatch.failureLine(couldNotStart: false, newerPlayer: nil) == ArcadeStartWatch.line
              && ArcadeStartWatch.failureLine(couldNotStart: true, newerPlayer: nil) == ArcadeStartWatch.couldNotStartLine,
              "on the shelf's player, the usual lines")
        check(ArcadeStartWatch.failureLine(couldNotStart: false, newerPlayer: .shelf)
              == "The game did not start. A newer game player is ready: leave the game and choose Download the update.",
              "the countdown on an old player names the update")
        check(ArcadeStartWatch.failureLine(couldNotStart: true, newerPlayer: .shelf)
              == "The game could not start. A newer game player is ready: leave the game and choose Download the update.",
              "and so does the kit's own start error")
        check(ArcadeStartWatch.failureLine(couldNotStart: true, newerPlayer: .added)
              == "The game could not start. A newer game player is ready: leave the game, press Play, and choose Download.",
              "an added game's Play offers the newer player first")

        var telemetry = ArcadeTelemetry()
        telemetry.title = "Demo"
        telemetry.gameId = "demo"
        telemetry.version = "g1"
        telemetry.player = kitOld
        telemetry.newerPlayerReady = true
        check(telemetry.report(now: telemetry.openedAt).contains("Game player: " + kitOld + ", and a newer one is ready."),
              "how the game ran names the player, and a newer one")
        telemetry.newerPlayerReady = false
        check(telemetry.report(now: telemetry.openedAt).contains("Game player: " + kitOld + ".\n"), "the shelf's own player")
        check(!ArcadeTelemetry().report(now: Date()).contains("Game player"), "no player known, no line")
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

    // MARK: Where the sound goes, the kit's settings and the screen's text (Oct 19 2026)

    static func soundAndScreenText() {
        // Every AVAudioSession output port type (its raw value) to the kit's six words.
        check(ArcadeAudioRoute.allCases.map { $0.rawValue } == ["speaker", "headphones", "bluetooth", "airplay", "hdmi", "other"],
              "the app sends only the kit's six route words")
        func route(_ type: String, _ name: String = "") -> ArcadeAudioRoute {
            ArcadeAudioRoute.of(ArcadeAudioPort(type: type, name: name))
        }
        check(route("Speaker") == .speaker && route("Receiver") == .speaker, "the built-in speaker and the earpiece are the speaker")
        check(route("Headphones", "Headphones") == .headphones, "wired headphones")
        check(route("BluetoothA2DPOutput") == .bluetooth && route("BluetoothLE") == .bluetooth && route("BluetoothHFP") == .bluetooth,
              "A2DP, LE and hands-free Bluetooth")
        check(route("AirPlay", "Living Room") == .airplay, "AirPlay")
        check(route("HDMIOutput") == .hdmi && route("DisplayPort") == .hdmi, "HDMI and DisplayPort are a TV")
        check(route("USBAudio", "USB-C Digital AV Multiport Adapter") == .hdmi && route("USBAudio", "HDMI") == .hdmi
              && route("USBAudio", "LG TV") == .hdmi, "a USB output named as a display is a TV")
        check(route("USBAudio", "USB-C to 3.5 mm Headphone Jack Adapter") == .headphones, "a USB headphone adapter is headphones")
        let earphones = ["Samsung Type-C Earphones", "USB-C Earphone", "Type-C Earbud", "USB-C earbuds", "Wired Buds"]
        check(earphones.allSatisfy { route("USBAudio", $0) == ArcadeAudioRoute.headphones },
              "USB-C earphones, earbuds and buds by any of their names are headphones")
        check(route("USBAudio", "USB Audio CODEC") == .other && route("USBAudio") == .other, "any other USB output is other")
        check(route("CarAudio", "My car") == .other && route("LineOut") == .other && route("Virtual") == .other && route("") == .other,
              "a car, a line out and anything unknown are other (Stereo plus calls)")
        check(route("speaker") == .speaker && route("HEADPHONES") == .headphones && route("airplay") == .airplay, "port types in any case")
        check(ArcadeAudioRoute.of([]) == nil, "no output at all (between two routes): nothing to tell the kit")
        check(ArcadeAudioRoute.of([ArcadeAudioPort(type: "Speaker"), ArcadeAudioPort(type: "HDMIOutput")]) == .hdmi,
              "a TV wins over the speaker")
        check(ArcadeAudioRoute.of([ArcadeAudioPort(type: "Speaker"), ArcadeAudioPort(type: "Headphones")]) == .headphones,
              "the speaker comes last")
        check(ArcadeAudioRoute.of([ArcadeAudioPort(type: "BluetoothA2DPOutput", name: "Earbuds")]) == .bluetooth, "one Bluetooth output")
        check(ArcadeAudioRoute.speaker.spoken == "Phone speaker" && ArcadeAudioRoute.headphones.spoken == "Headphones"
              && ArcadeAudioRoute.hdmi.spoken == "TV or display", "routes in words for Settings")
        check(ArcadeAudioRoute.speaker.inSentence == "the phone speaker" && ArcadeAudioRoute.headphones.inSentence == "headphones"
              && ArcadeAudioRoute.hdmi.inSentence == "a TV or display" && ArcadeAudioRoute.allCases.allSatisfy { !$0.inSentence.isEmpty },
              "and inside a sentence")

        // Headphones (or AirPlay, or a TV) going away.
        check(ArcadeAudioRoute.lostLine(fighting: true, gameSaysRoute: false) == "Headphones disconnected, so the game is paused."
              && ArcadeAudioRoute.lostLine(fighting: false, gameSaysRoute: false) == "Headphones disconnected.",
              "the plain player and an older game player hear the app's own line")
        check(ArcadeAudioRoute.lostLine(fighting: true, gameSaysRoute: true) == nil
              && ArcadeAudioRoute.lostLine(fighting: false, gameSaysRoute: true) == nil,
              "a game that says the new route itself gets no app line on top of it (and its pause screen)")
        check(ArcadeAudioRoute.gameSaysRoutes(page: ["outputLines": ["_doc": "said once", "speaker": "Phone speaker: positions are called out."]]),
              "a game with its own words for a route change says it")
        check(!ArcadeAudioRoute.gameSaysRoutes(page: ["outputLines": ["_doc": "said once", "speaker": "  "]])
              && !ArcadeAudioRoute.gameSaysRoutes(page: ["defaults": ["sight": "none"]]) && !ArcadeAudioRoute.gameSaysRoutes(page: nil),
              "only notes, blank lines or no words at all: the app says it")

        // The calls the page gets.
        let output = ArcadeJS.setOutput(.headphones)
        check(output.contains("k.setOutput({ route: \"headphones\" })") && output.contains("if (!k || !k.setOutput) { return null; }"),
              "setOutput with the route word, nothing on an older game player")
        check(output.contains("soundWorld: String(s.soundWorld || '')") && output.contains("output: String(s.output || '')")
              && !output.contains("\n"), "and its answer is the kit's choice, as one line of script")
        check(ArcadeJS.setSettings(["soundWorld": "3d"])
              == #"window.revivalKit&&window.revivalKit.setSettings&&window.revivalKit.setSettings({"soundWorld":"3d"});void 0"#,
              "a sound world choice")
        check(ArcadeJS.setSettings(["calls": "urgent"]).contains(#"setSettings({"calls":"urgent"})"#), "a calls choice")
        check(ArcadeJS.setSettings(ArcadeKitSettings.picture(full: true)).contains(#"setSettings({"picture":"full"})"#)
              && ArcadeJS.setSettings(ArcadeKitSettings.picture(full: false)).contains(#"setSettings({"picture":null})"#),
              "Show the game picture: the full picture, or none")

        // The kit's spellings.
        check(ArcadeKitSettings.soundWorld("3D") == "3d" && ArcadeKitSettings.soundWorld("Stereo") == "stereo"
              && ArcadeKitSettings.soundWorld("off") == "off", "sound worlds in the kit's own spelling")
        check(ArcadeKitSettings.soundWorld("loud") == nil && ArcadeKitSettings.soundWorld(3) == nil && ArcadeKitSettings.soundWorld(nil) == nil,
              "anything else is no sound world")
        check(ArcadeKitSettings.calls("Urgent") == "urgent" && ArcadeKitSettings.calls("all") == "all" && ArcadeKitSettings.calls("some") == nil,
              "calls in the kit's own spelling")
        check(ArcadeKitSettings.soundWorlds == ["stereo", "3d", "off"] && ArcadeKitSettings.callChoices == ["all", "urgent", "off"],
              "the Settings sheet's order, Stereo first")

        // The settings given back at the next start.
        let first = ArcadeKitSettings.hostSettings(saved: nil, readsAll: false, showPicture: false, hasSoundWorld: true)
        check(ArcadeKitSettings.json(first) == #"{"calls":"all","headphonesWorld":"stereo","soundWorld":"stereo"}"#,
              "the first start: headphones on Stereo (3D is her choice), calls on")
        let switches = ArcadeKitSettings.hostSettings(saved: nil, readsAll: true, showPicture: true, hasSoundWorld: true)
        check(ArcadeKitSettings.json(switches)
              == #"{"calls":"all","headphonesWorld":"stereo","picture":"full","soundWorld":"stereo","speechMode":"native"}"#,
              "VoiceOver reads every line, and the full picture")
        check(ArcadeKitSettings.json(ArcadeKitSettings.hostSettings(saved: nil, readsAll: false, showPicture: false, hasSoundWorld: false)) == "{}"
              && ArcadeKitSettings.json(ArcadeKitSettings.hostSettings(saved: nil, readsAll: true, showPicture: false, hasSoundWorld: false))
              == #"{"speechMode":"native"}"#,
              "the plain player gets what it got before: speechMode only while VoiceOver reads every line")
        let keptJSON = #"""
        {"calls":"urgent","gameVolume":0.6,"headphonesWorld":"3d","madeSounds":false,"opponents":true,"output":"speaker","picture":"full",
         "routes":{"headphones":{"calls":"all","soundWorld":"3d"},"speaker":{"calls":"urgent","soundWorld":"off"}},
         "sight":"none","soundWorld":"off","speechMode":"native"}
        """#
        let kept = ArcadeKitSettings.parse(Data(keptJSON.utf8)) ?? [:]
        check(kept.count == 11, "the kit's settings read")
        let back = ArcadeKitSettings.hostSettings(saved: kept, readsAll: false, showPicture: false, hasSoundWorld: true)
        check(back["speechMode"] == nil && back["picture"] == nil,
              "the app's switches win: no VoiceOver reading every line, no full picture")
        check(ArcadeKitSettings.json((back["routes"] as? [String: Any]) ?? [:])
              == #"{"headphones":{"calls":"all","soundWorld":"3d"},"speaker":{"calls":"urgent","soundWorld":"off"}}"#,
              "the kit's per-route choices go back as given")
        check((back["headphonesWorld"] as? String) == "3d" && (back["soundWorld"] as? String) == "off"
              && (back["calls"] as? String) == "urgent" && (back["output"] as? String) == "speaker",
              "a choice she made is never replaced by the app's defaults")
        check((back["madeSounds"] as? Bool) == false && (back["opponents"] as? Bool) == true
              && abs(((back["gameVolume"] as? Double) ?? 0) - 0.6) < 0.000_001
              && (back["sight"] as? String) == "none", "every other setting goes back as the kit sent it")
        let backJSON = ArcadeKitSettings.json(back)
        check(backJSON.contains(#""madeSounds":false"#) && backJSON.contains(#""opponents":true"#), "true and false stay true and false, not 1 and 0")
        let readsAll = ArcadeKitSettings.hostSettings(saved: kept, readsAll: true, showPicture: true, hasSoundWorld: true)
        check((readsAll["speechMode"] as? String) == "native" && (readsAll["picture"] as? String) == "full", "and the switches on")
        let odd = ArcadeKitSettings.hostSettings(saved: ["soundWorld": "loud", "calls": 3, "headphonesWorld": ""], readsAll: false,
                                                 showPicture: false, hasSoundWorld: true)
        check(ArcadeKitSettings.json(odd) == #"{"calls":"all","headphonesWorld":"stereo","soundWorld":"stereo"}"#,
              "a sound world or calls the kit would not know starts as the defaults")
        check(ArcadeKitSettings.json(["when": Date()]) == "{}", "anything that is not JSON is an empty object")
        let script = ArcadeJS.hostScript(base: "b", emulatorData: "d", settings: back)
        check(script.contains(#""routes":{"headphones":{"calls":"all","soundWorld":"3d"},"speaker":{"calls":"urgent","soundWorld":"off"}}"#)
              && script.contains(#"settings: {"calls":"urgent","#), "the host script carries the kit's own settings, routes and all")

        // Kept beside the save.
        let root = temporaryFolder("settings")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ArcadeSaveStore(root: root.appendingPathComponent("ArcadeSaves", isDirectory: true))
        check(store.settings(gameId: "fighter") == nil, "no settings yet")
        check(store.keepSettings(kept, gameId: "fighter"), "the kit's 'settings' are kept")
        check(store.settings(gameId: "fighter").map(ArcadeKitSettings.json) == ArcadeKitSettings.json(kept), "and given back exactly")
        check(!store.keepSettings(kept, gameId: "../x") && !store.keepSettings(["when": Date()], gameId: "fighter"),
              "a game id that is not a plain name, or settings that are not JSON, are refused")
        check(store.settings(gameId: "fighter").map(ArcadeKitSettings.json) == ArcadeKitSettings.json(kept), "and the kept settings are untouched")
        check(!store.keepSettings(["text": String(repeating: "a", count: ArcadeSaveStore.maxSettingsBytes)], gameId: "big"),
              "far too big is not the kit's settings")
        check(store.base64(gameId: "fighter") == nil, "the settings are not a save")
        if let broken = store.settingsFile(gameId: "broken") {
            try? Data("not json".utf8).write(to: broken)
            check(store.settings(gameId: "broken") == nil, "a file that is not a JSON object reads as none")
        } else {
            check(false, "a plain game id has a settings file")
        }

        // An added game: its plain player and its accessibility pack share the
        // save's id (the same cartridge save), never their settings.
        let shared = "import-0123abcd"
        check(ArcadeKitSettings.storeKey(saveId: shared, isPlain: false) == shared
              && ArcadeKitSettings.storeKey(saveId: shared, isPlain: true) == nil,
              "a game's page keeps its settings under the save's id; the plain player keeps none")
        func startSettings(plain: Bool, readsAll: Bool = false) -> [String: Any] {
            let saved = ArcadeKitSettings.storeKey(saveId: shared, isPlain: plain).flatMap { store.settings(gameId: $0) }
            return ArcadeKitSettings.hostSettings(saved: saved, readsAll: readsAll, showPicture: false, hasSoundWorld: !plain)
        }
        func keepAs(plain: Bool, _ settings: [String: Any]) {
            if let key = ArcadeKitSettings.storeKey(saveId: shared, isPlain: plain) { store.keepSettings(settings, gameId: key) }
        }
        // The plain player's 'settings' as its kit sends them at 'ready'
        // (its own defaults, game volume 0.8, then setMode and setOutput).
        keepAs(plain: true, ["sight": "none", "speechMode": "native", "gameVolume": 0.8, "soundWorld": "off", "calls": "all",
                             "output": "speaker"])
        check(store.settings(gameId: shared) == nil, "the plain player's settings are never kept")
        let packFirst = startSettings(plain: false)
        check(packFirst["gameVolume"] == nil && packFirst["output"] == nil
              && ArcadeKitSettings.json(packFirst) == #"{"calls":"all","headphonesWorld":"stereo","soundWorld":"stereo"}"#,
              "so its game volume never reaches the pack's page, which starts on its own defaults")
        keepAs(plain: false, ["gameVolume": 0.6, "soundWorld": "3d", "calls": "urgent", "output": "headphones", "headphonesWorld": "3d"])
        let packAgain = startSettings(plain: false)
        check(abs(((packAgain["gameVolume"] as? Double) ?? 0) - 0.6) < 0.000_001 && (packAgain["soundWorld"] as? String) == "3d",
              "the pack's page gets its own settings back")
        check(ArcadeKitSettings.json(startSettings(plain: true)) == "{}"
              && ArcadeKitSettings.json(startSettings(plain: true, readsAll: true)) == #"{"speechMode":"native"}"#,
              "and the plain player never gets the pack's: exactly what it got before")

        // What the Settings sheet shows.
        let sound = ArcadeKitSound(["soundWorld": "3D", "calls": "Urgent", "output": "speaker"])
        check(sound?.soundWorld == "3d" && sound?.calls == "urgent" && sound?.output == .speaker, "the kit's sound, read")
        check(ArcadeKitSound(["calls": "all"]) == nil && ArcadeKitSound(nil) == nil, "no sound world named (an older player): no choices")
        let quiet = ArcadeKitSound(["soundWorld": "off", "calls": "", "output": ""])
        check(quiet?.calls == "all" && quiet?.output == nil, "calls default to all; no route yet")
        check(ArcadeKitSound(kept) == ArcadeKitSound(["soundWorld": "off", "calls": "urgent", "output": "speaker"]), "from the whole settings too")
        check(sound?.label("Sound world") == "Sound world on the phone speaker"
              && ArcadeKitSound(["soundWorld": "3d", "output": "headphones"])?.label("Position calls") == "Position calls on headphones"
              && ArcadeKitSound(["soundWorld": "stereo", "output": "hdmi"])?.label("Sound world") == "Sound world on a TV or display",
              "each picker names the way of listening its choice is kept for")
        check(quiet?.label("Sound world") == "Sound world", "no route yet: the plain name")
        check(ArcadeKitSound.footer.hasPrefix("Each way of listening keeps its own choice.")
              && ArcadeKitSound.footer.contains("On the phone speaker the game starts with its own sound plus position calls."),
              "the footer says why a choice is not there on another output")

        // The screen's text.
        let text = ArcadeScreenText(detail: ["screen": "main menu", "lines": ["Quest", "  ", 7, "Practice "] as [Any]])
        check(text?.screen == "main menu" && text?.lines == ["Quest", "Practice"], "the lines, without blanks or anything not text")
        check(text?.title(names: ["main menu": "Main menu"]) == "Main menu", "titled with the game's own name for the screen")
        check(ArcadeScreenText(screen: "game options", lines: []).title(names: [:]) == "Game options", "else the screen with a capital")
        let none = ArcadeScreenText(detail: ["screen": "", "lines": [String]()])
        check(none?.lines.isEmpty == true && none?.title(names: [:]) == "Screen text", "a screen with no text and no name")
        check(ArcadeScreenText(detail: ["screen": "roster"])?.lines.isEmpty == true, "no lines given, none listed")
        check(ArcadeScreenText(detail: nil) == nil, "no detail, nothing")
        check(ArcadeScreenText(detail: ["screen": "credits", "lines": Array(repeating: "Name", count: 1_000)])?.lines.count
              == ArcadeScreenText.maxLines, "a runaway list is cut")
        check(ArcadeScreenText.emptyLine == "No screen text.", "the empty state, as the kit says it")
        check(ArcadeScreenText.sheetLine(text, pageReady: true) == nil && ArcadeScreenText.sheetLine(text, pageReady: false) == nil,
              "lines to list: the sheet lists them")
        check(ArcadeScreenText.sheetLine(none, pageReady: true) == ArcadeScreenText.emptyLine, "an empty 'lines' event: no screen text")
        check(ArcadeScreenText.sheetLine(nil, pageReady: true) == ArcadeScreenText.olderPlayerLine
              && ArcadeScreenText.olderPlayerLine.hasPrefix("This version of the game player cannot list the screen's text."),
              "ready with no 'lines' event: a game player older than the list, not an empty screen")
        check(ArcadeScreenText.sheetLine(nil, pageReady: false) == ArcadeScreenText.notStartedLine, "not started yet")

        // The kit's telemetry (Oct 19 2026: its frame time and the emulator's dropouts).
        var telemetry = ArcadeTelemetry()
        telemetry.note(event: "telemetry", detail: ["js": 0.25, "jsMax": 1.5, "underruns": 3, "audioQ": 0, "fps": 59])
        let report = telemetry.report(now: telemetry.openedAt)
        check(report.contains("js=0.25") && report.contains("jsMax=1.5") && report.contains("underruns=3") && report.contains("audioQ=0"),
              "the kit's frame time and the emulator's dropouts reach the how-it-ran text")
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

        // Oct 19 2026: nothing about a locked game downloads or launches.
        check(ArcadeShelf.playable("tilt", in: open)?.id == "tilt" && ArcadeShelf.playable("fighter", in: open) != nil,
              "a playable row opens its game")
        check(ArcadeShelf.playable("fighter", in: closed) == nil && ArcadeShelf.playable("odd", in: closed) == nil,
              "a folded family game is never playable")
        let ageLocked = ArcadeShelf.rows([lockedFamily, publicLocked, unready], familyOpen: true, familyNote: note)
        check(ArcadeShelf.playable("fighter", in: ageLocked) == nil && ArcadeShelf.playable("tilt", in: ageLocked) == nil,
              "a game the server locks (an age rule) or that is not ready is never playable")
        check(ArcadeShelf.playable("missing", in: open) == nil, "an id not on the shelf is not playable")
        check(ArcadeShelf.lockedLabel(title: "Fighter", reason: "Grown-ups only.") == "Grown-ups only. Fighter",
              "the reason is spoken first, then the name")
        check(ArcadeShelf.lockedLabel(title: ArcadeShelf.shelfTitle, reason: note) == "Part of the Family feature pack. Family shelf",
              "the family shelf says its reason first")
        check(ArcadeShelf.lockedLabel(title: "Tilt", reason: "  ") == "Tilt" && ArcadeShelf.lockedLabel(title: "", reason: "Locked") == "Locked",
              "an empty reason or name leaves the other alone")
        check(ArcadeShelf.hasPublicGame(open) && ArcadeShelf.hasPublicGame([.locked(publicLocked, reason: "x")]),
              "a public game, playable or greyed, counts as public")
        check(!ArcadeShelf.hasPublicGame(reviewSeat) && !ArcadeShelf.hasPublicGame(ArcadeShelf.rows([fighter], familyOpen: true, familyNote: note)),
              "a shelf of family games has no public game")
        for word in ["play by ear", "Family shelf", "private", "public games are free", "no game is built into the app"] {
            check(ArcadeShelf.about.contains(word), "the screen's description says: " + word)
        }
        check(!ArcadeShelf.noPublicGames.contains("as they are added") && !ArcadeShelf.noPublicGames.contains("yet"),
              "an empty public shelf is said as a plain fact, with no promise")

        // Oct 19 2026 (App Store 4.7.5): a grown-ups-only game says so.
        let grown = try decoder.decode(ArcadeConfig.self, from: Data(#"""
        {"catalog":[{"id":"late","title":"Late Show","console":"NES","access":"public","size":2100000,"version":"1","grownUpsOnly":true},
                    {"id":"early","title":"Early Show","access":"public","version":"1","grownUpsOnly":"no"},
                    {"id":"plain","title":"Plain","access":"public","version":"1"}]}
        """#.utf8))
        check(grown.catalog.map { $0.grownUpsOnly } == [true, false, false], "grownUpsOnly is read, and absent means false")
        check(ArcadeShelf.caption(grown.catalog[0]) == "Grown-ups only, NES, 2.1 MB", "a grown-ups-only game says so first in its caption")
        check(ArcadeShelf.caption(grown.catalog[2]) == "A classic game" && ArcadeShelf.caption(tilt) == "NES, 2.1 MB",
              "other captions are the console and size, or a plain line")

        // Oct 19 2026: Report a problem with this game (App Store 4.7.1).
        let target = ArcadeReportTarget(gameId: "tilt", title: "Tilt Demo", version: "3")
        check(!ArcadeReport.canSend("") && !ArcadeReport.canSend(" ab ") && ArcadeReport.canSend("No sound"),
              "a report needs a few typed words")
        check(ArcadeReport.subject(target) == "Arcade game report: Tilt Demo" && ArcadeReport.subject(.arcade) == "Arcade report",
              "the report's title names the game")
        let long = ArcadeReportTarget(gameId: "x", title: String(repeating: "t", count: 400), version: "1")
        check(ArcadeReport.subject(long).count == 200, "the title fits the server's 200 characters")
        let detail = ArcadeReport.detail(note: "  The sound stops after the menu.  ", target: target, from: "Game settings")
        check(detail == "The sound stops after the menu.\n\nGame: Tilt Demo\nGame id: tilt\nGame version: 3\nSent from: Game settings",
              "the report carries her words, the game id and version, and where it came from")
        check(ArcadeReport.detail(note: "Hard to find", target: .arcade, from: "Arcade screen").contains("About: the Arcade itself"),
              "a report about the whole Arcade says so")
        check(ArcadeReport.detail(note: "abc", target: ArcadeReportTarget(gameId: "y", title: "Y", version: ""), from: "Arcade list")
              .contains("Game version: not known"), "a missing version is said plainly")
        check(ArcadeReport.detail(note: String(repeating: "n", count: 5000), target: target, from: "x").count < 2200,
              "a very long note is cut to size")
        let withRun = ArcadeReport.detail(note: "It froze.", target: target, from: "Game settings", ran: "Kade AI Arcade: how the game ran\nPage loads: 1.")
        check(withRun == "It froze.\n\nGame: Tilt Demo\nGame id: tilt\nGame version: 3\nSent from: Game settings\n\nHow the game ran:\nKade AI Arcade: how the game ran\nPage loads: 1.",
              "from a running game, how it ran goes with the report")
        check(ArcadeReport.detail(note: "abc", target: target, from: "x", ran: "  ") == ArcadeReport.detail(note: "abc", target: target, from: "x"),
              "an empty run text adds nothing")
        let huge = ArcadeReport.detail(note: String(repeating: "n", count: 5000), target: target, from: "Game settings",
                                       ran: String(repeating: "r", count: 9000))
        check(huge.count < 6300, "a very long run text is cut too, well inside the server's 8,000 characters")

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
        check(manifest.kitVersion == "4.2.3-1" && custom.kitVersion == nil, "a manifest names its game player, when it has one")
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
        check(ArcadeJS.hostScript(base: "kadearcade://game/games/demo/", emulatorData: "d", settings: [:],
                                  romPath: "kadearcade://game/games/demo/local/rom.z64")
              .contains("romPath: \"kadearcade://game/games/demo/local/rom.z64\","),
              "an added game with its pack: the page is told where her ROM is")
        check(!full.contains("romPath"), "no romPath unless one is given (the plain player's is in its URL)")
        check(ArcadeJS.cannotStart("emulator") && ArcadeJS.cannotStart("start") && ArcadeJS.cannotStart("system")
              && !ArcadeJS.cannotStart("ram") && !ArcadeJS.cannotStart("save"),
              "a game that never started is said aloud, a system the player lacks included; the kit says its own RAM line")
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

// MARK: - Add a game (Oct 19 2026): Sources/ArcadeImport.swift
//
// Every ROM here is a few made-up bytes built in the test; no game is in the repo.

extension ArcadeModelsTests {
    static func addAGame() throws {
        identities()
        detection()
        try zipReading()
        try importStore()
        try matchAnswers()
        try overlayServing()
        plainControls()
    }

    // MARK: The plain player's controls (games/_plain/systems.json in the kit)

    /// The kit's systems.json shape (Revival kit 20261019-7ae651dc), cut to two systems.
    static let systemsJSON = """
    {"retropad":{"B":0,"Y":1,"SELECT":2,"START":3,"DUP":4,"DDOWN":5,"DLEFT":6,"DRIGHT":7,"A":8,"X":9,"L":10,"R":11},
     "page":{"defaults":{"sight":"none","speechMode":"reader"}},
     "systems":{
      "nes":{"name":"NES","core":"fceumm","extensions":[".nes"],"rom":"rom.nes","pad":"retropad","stick":"dpad",
        "gamepad":{"fight":[[1,"A"],[3,"A"],[0,"B"],[2,"B"],[8,"SELECT"],[12,"DUP"],[13,"DDOWN"],[14,"DLEFT"],[15,"DRIGHT"]],"always":[[9,"START"]]},
        "touch":{"fight":{
          "zones":[{"name":"a","x":[0.5,1],"y":[0,0.5]},{"name":"b","x":[0.5,1],"y":[0.5,1]}],
          "anywhere":{"tap3":{"pulse":{"buttons":["START"]}}},
          "left":{"stick1":{"radiusPx":50},"tap2":{"pulse":{"buttons":["SELECT"]}},"hold2":{"info":"help","ms":1500}},
          "a":{"press1":{"buttons":["A"]}},
          "b":{"press1":{"buttons":["B"]}}}},
        "help":{"touch":["The left half of the screen is the control pad.","The upper right is A and the lower right is B."]}},
      "gb":{"name":"Game Boy","core":"gambatte","extensions":[".gb"],"rom":"rom.gb","pad":"retropad","stick":"dpad","like":"nes"},
      "gba":{"name":"Game Boy Advance","core":"mgba","extensions":[".gba"],"rom":"rom.gba","pad":"retropad","stick":"dpad",
        "gamepad":{"fight":[[1,"A"],[0,"B"],[4,"L"],[5,"R"],[8,"SELECT"],[12,"DUP"]],"always":[[9,"START"]]},
        "touch":{"fight":{
          "zones":[{"name":"l","x":[0,0.5],"y":[0,0.15]},{"name":"r","x":[0.5,1],"y":[0,0.15]},
                   {"name":"a","x":[0.5,1],"y":[0.15,0.575]},{"name":"b","x":[0.5,1],"y":[0.575,1]}],
          "anywhere":{"tap3":{"pulse":{"buttons":["START"]}}},
          "left":{"stick1":{"radiusPx":50},"tap2":{"pulse":{"buttons":["SELECT"]}}},
          "l":{"press1":{"buttons":["L"]}},"r":{"press1":{"buttons":["R"]}},
          "a":{"press1":{"buttons":["A"]}},"b":{"press1":{"buttons":["B"]}}}}}}}
    """

    static func plainControls() {
        let data = Data(systemsJSON.utf8)
        check(ArcadePlainControls.systemsPath == "games/_plain/systems.json", "the kit's systems file")
        check(ArcadePlainControls.entry(data, system: "gb")?["core"] as? String == "gambatte"
              && ArcadePlainControls.entry(data, system: "gb")?["touch"] != nil, "Game Boy keeps its own core and takes the NES controls")
        check(ArcadePlainControls.entry(data, system: "snes") == nil, "no entry, no tables")
        let gb = ArcadePlainControls.tables(data, system: "gb")
        guard let touch = gb.touch, let gamepad = gb.gamepad else {
            check(false, "a Game Boy game gets touch and controller tables")
            return
        }
        check(gb.touchHelp == "The left half of the screen is the control pad. The upper right is A and the lower right is B.",
              "the pad says the kit's own touch help")
        check(touch.zones.map { $0.name } == ["a", "b"] && touch.named["a"]?.presses[1] == ArcadePadState(buttons: ["A"]),
              "the right half is two named zones, each a held button")

        // Touch, in play ('fight', the plain world's mode the whole time): 400 x 800 points.
        var select = ArcadeTouchRecognizer(table: touch)
        select.mode = "fight"
        _ = select.start(id: 1, x: 60, y: 400, width: 400, height: 800, now: 0)
        _ = select.start(id: 2, x: 120, y: 400, width: 400, height: 800, now: 10)
        _ = select.end(id: 1, now: 60)
        check(select.end(id: 2, now: 70) == [.pad(source: "touch-p1", state: ArcadePadState(buttons: ["SELECT"]))],
              "a two-finger tap on the left is Select")
        var a = ArcadeTouchRecognizer(table: touch)
        a.mode = "fight"
        check(a.start(id: 1, x: 300, y: 100, width: 400, height: 800, now: 0)
              == [.pad(source: "touch-press-a", state: ArcadePadState(buttons: ["A"]))], "the upper right presses A as the finger lands")
        check(a.advance(to: 2000).isEmpty && a.move(id: 1, x: 330, y: 160, now: 2100).isEmpty, "and holds it, still or moving")
        check(a.end(id: 1, now: 2200) == [.pad(source: "touch-press-a", state: nil)], "lifting lets A go")
        var b = ArcadeTouchRecognizer(table: touch)
        b.mode = "fight"
        check(b.start(id: 1, x: 300, y: 700, width: 400, height: 800, now: 0)
              == [.pad(source: "touch-press-b", state: ArcadePadState(buttons: ["B"]))], "the lower right presses B")
        // Walking on the left while holding B on the right.
        check(b.start(id: 2, x: 60, y: 400, width: 400, height: 800, now: 100).isEmpty, "a left thumb landing does nothing yet")
        check(b.move(id: 2, x: 60, y: 375, now: 120) == [.pad(source: "touch-stick-left", state: ArcadePadState(sy: -0.5)), .haptic(.direction)],
              "the left thumb is the control pad while B is held")
        check(b.end(id: 2, now: 300) == [.pad(source: "touch-stick-left", state: nil)], "lifting it lets only the pad go")
        check(b.end(id: 1, now: 400) == [.pad(source: "touch-press-b", state: nil)] && b.isIdle, "then B")
        // Three fingers across the zones: Start, the buttons pressed on the way only while they were down.
        var start = ArcadeTouchRecognizer(table: touch)
        start.mode = "fight"
        _ = start.start(id: 1, x: 60, y: 400, width: 400, height: 800, now: 0)
        _ = start.start(id: 2, x: 300, y: 100, width: 400, height: 800, now: 5)
        _ = start.start(id: 3, x: 300, y: 700, width: 400, height: 800, now: 10)
        _ = start.end(id: 1, now: 60)
        check(start.end(id: 2, now: 65) == [.pad(source: "touch-press-a", state: nil)], "A goes as its finger lifts")
        check(start.end(id: 3, now: 70) == [.pad(source: "touch-press-b", state: nil), .pad(source: "touch-p1", state: ArcadePadState(buttons: ["START"]))],
              "and a quick three-finger tap across the zones is Start")
        var menu = ArcadeTouchRecognizer(table: touch)
        check(menu.start(id: 1, x: 300, y: 100, width: 400, height: 800, now: 0).isEmpty, "outside play (paused) nothing is pressed")
        check(menu.releaseAll().isEmpty, "and nothing is held")
        var released = ArcadeTouchRecognizer(table: touch)
        released.mode = "fight"
        _ = released.start(id: 1, x: 300, y: 100, width: 400, height: 800, now: 0)
        check(released.releaseAll() == [.pad(source: "touch-press-a", state: nil)], "release all lets a held button go")
        check(touch.zone(x: 300, y: 100, width: 400, height: 0) == .right && touch.zone(x: 100, y: 100, width: 400, height: 800) == .left,
              "with no height, or outside every zone, the halves")

        // The Game Boy Advance's shoulders along the top.
        let gba = ArcadePlainControls.tables(data, system: "gba")
        if let gbaTouch = gba.touch {
            var shoulder = ArcadeTouchRecognizer(table: gbaTouch)
            shoulder.mode = "fight"
            check(shoulder.start(id: 1, x: 100, y: 40, width: 400, height: 800, now: 0)
                  == [.pad(source: "touch-press-l", state: ArcadePadState(buttons: ["L"]))], "the top left is the left shoulder")
            check(shoulder.start(id: 2, x: 300, y: 300, width: 400, height: 800, now: 10)
                  == [.pad(source: "touch-press-a", state: ArcadePadState(buttons: ["A"]))], "below the top on the right, A")
        } else {
            check(false, "a Game Boy Advance game gets its touch table")
        }

        // A controller: the d-pad moves, Back/View is Select, A and B where the help says.
        var mapper = ArcadeGamepadMapper(map: gamepad)
        var pad = ArcadeGamepadSnapshot()
        pad.pressed[12] = true
        let up = mapper.apply(pad, mode: "fight")
        check(up.state.buttons == ["DUP"] && up.info.isEmpty, "the d-pad moves (no information keys)")
        var buttons = ArcadeGamepadSnapshot()
        buttons.pressed[1] = true
        buttons.pressed[0] = true
        buttons.pressed[8] = true
        check(mapper.apply(buttons, mode: "fight").state.buttons == ["A", "B", "SELECT"], "the right button is A, the bottom B, Back is Select")
        var menuStart = ArcadeGamepadSnapshot()
        menuStart.pressed[9] = true
        check(mapper.apply(menuStart, mode: "pause").state.buttons == ["START"], "Start works while paused")
    }

    static func sha1Hex(_ bytes: [UInt8]) -> String {
        ArcadeROMHasher.hex(Insecure.SHA1.hash(data: Data(bytes)))
    }

    static func temporaryFolder(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("arcade-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: sha1, crc32 and the No-Intro form

    static func identities() {
        let gba = ArcadeROMKind(system: .gba, n64Order: nil, headerBytes: 0)
        let abc = ArcadeROMHasher.identify(Data("abc".utf8), kind: gba)
        check(abc.identity.sha1 == "a9993e364706816aba3e25717850c26c9cd0d89d" && abc.identity.localId == abc.identity.sha1,
              "sha1 of a whole file is the standard sha1, and the local id is the same when nothing is left out")
        check(abc.identity.crc32 == "352441c2" && abc.identity.size == 3 && abc.kept == Data("abc".utf8), "crc32 and size, and the bytes kept as they came")
        var crc = ArcadeCRC32()
        crc.update(Array("123456789".utf8))
        check(crc.value == 0xCBF4_3926, "crc32's check value")

        // NES: the 16-byte iNES header is left out of the No-Intro hash, not out of the file kept.
        let header: [UInt8] = [0x4E, 0x45, 0x53, 0x1A, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let body: [UInt8] = Array("abc".utf8)
        let nes = ArcadeROMKind(system: .nes, n64Order: nil, headerBytes: 16)
        let headed = ArcadeROMHasher.identify(Data(header + body), kind: nes)
        check(headed.identity.sha1 == "a9993e364706816aba3e25717850c26c9cd0d89d" && headed.identity.crc32 == "352441c2",
              "an NES file is hashed without its iNES header")
        check(headed.identity.localId == sha1Hex(header + body) && headed.kept == Data(header + body) && headed.identity.size == 19,
              "but its local id is the whole file, and the whole file is kept (the emulator needs the header)")
        var pieces = ArcadeROMHasher(kind: nes)
        var kept = Data()
        for start in stride(from: 0, to: 19, by: 5) {
            kept.append(pieces.update(Data((header + body)[start..<min(start + 5, 19)])))
        }
        let piecesEnd = pieces.finish()
        check(piecesEnd.identity == headed.identity && kept == Data(header + body), "the header is left out across pieces too")

        // N64: all three byte orders hash as the big-endian .z64 file, and are kept that way.
        let z64: [UInt8] = [0x80, 0x37, 0x12, 0x40, 1, 2, 3, 4, 5, 6, 7, 8]
        let v64: [UInt8] = [0x37, 0x80, 0x40, 0x12, 2, 1, 4, 3, 6, 5, 8, 7]
        let n64: [UInt8] = [0x40, 0x12, 0x37, 0x80, 4, 3, 2, 1, 8, 7, 6, 5]
        let want = sha1Hex(z64)
        var localIds = Set<String>()
        let orders: [([UInt8], ArcadeN64Order)] = [(z64, .bigEndian), (v64, .byteSwapped), (n64, .wordSwapped)]
        for (bytes, order) in orders {
            let kind = ArcadeROMKind(system: .n64, n64Order: order, headerBytes: 0)
            let whole = ArcadeROMHasher.identify(Data(bytes), kind: kind)
            check(whole.identity.sha1 == want && whole.kept == Data(z64), "N64 \(order.rawValue) is hashed and kept in .z64 order")
            check(whole.identity.localId == sha1Hex(bytes), "N64 \(order.rawValue)'s local id is the file as added")
            localIds.insert(whole.identity.localId)
            // Pieces that cut words in half.
            var hasher = ArcadeROMHasher(kind: kind)
            var out = Data()
            for start in stride(from: 0, to: bytes.count, by: 3) {
                out.append(hasher.update(Data(bytes[start..<min(start + 3, bytes.count)])))
            }
            let end = hasher.finish()
            out.append(end.tail)
            check(end.identity == whole.identity && out == Data(z64), "N64 \(order.rawValue) in pieces of three bytes")
        }
        check(localIds.count == 3, "the three files are three local ids")
        var odd: [UInt8] = [0x37, 0x80, 0x40, 0x12, 9]
        ArcadeN64Order.toBigEndian(&odd, from: .byteSwapped)
        check(odd == [0x80, 0x37, 0x12, 0x40, 9], "a tail shorter than a word is left as it is")
    }

    static func detection() {
        func head(_ size: Int, _ set: [Int: UInt8] = [:]) -> Data {
            var bytes = [UInt8](repeating: 0, count: size)
            for (index, value) in set { bytes[index] = value }
            return Data(bytes)
        }
        check(ArcadeSystem.from(extension: "GBA") == .gba && ArcadeSystem.from(extension: "v64") == .n64
              && ArcadeSystem.from(extension: "zip") == nil && ArcadeSystem.from(extension: "smc") == nil,
              "the v1 extensions, any case; SNES and zips are not systems")
        check(ArcadeSystem.nes.core == "fceumm" && ArcadeSystem.gbc.core == "gambatte" && ArcadeSystem.gba.core == "mgba"
              && ArcadeSystem.n64.core == "mupen64plus_next", "the license-clean cores")
        check(ArcadeSystem.n64.keptExtension == "z64" && ArcadeSystem.gbc.keptExtension == "gbc", "the extension kept on the phone")
        check(ArcadeROMDetect.kind(fileName: "demo.gb", head: head(0x150, [0x143: 0xC0]))?.system == .gbc,
              "a handheld file that runs in colour only is Game Boy Color")
        check(ArcadeROMDetect.kind(fileName: "demo.gb", head: head(0x150, [0x143: 0x80]))?.system == .gb,
              "one that also runs in black and white stays as named")
        check(ArcadeROMDetect.kind(fileName: "demo.gbc", head: head(4))?.system == .gbc, "a short file keeps its extension's system")
        check(ArcadeROMDetect.kind(fileName: "notes.txt", head: head(16)) == nil, "anything else is not a game")
        let headed = Data([0x4E, 0x45, 0x53, 0x1A] + [UInt8](repeating: 0, count: 12))
        check(ArcadeROMDetect.kind(fileName: "demo.nes", head: headed)?.headerBytes == 16
              && ArcadeROMDetect.kind(fileName: "demo.nes", head: head(32))?.headerBytes == 0, "an iNES header is found; a headerless file has none")
        check(ArcadeROMDetect.kind(fileName: "demo.v64", head: Data([0x80, 0x37, 0x12, 0x40]))?.n64Order == .bigEndian,
              "the first bytes say an N64 file's order, whatever its extension")
        check(ArcadeROMDetect.kind(fileName: "demo.z64", head: Data([0x37, 0x80, 0x40, 0x12]))?.n64Order == .byteSwapped
              && ArcadeROMDetect.kind(fileName: "demo.z64", head: Data([0x40, 0x12, 0x37, 0x80]))?.n64Order == .wordSwapped,
              "byte-swapped and word-swapped by their first bytes")
        check(ArcadeROMDetect.kind(fileName: "demo.n64", head: head(8))?.n64Order == .wordSwapped,
              "unknown first bytes: the extension says the order")
    }

    // MARK: Zips built here

    static func le16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }

    static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    struct ZipPart {
        let name: String
        let plain: [UInt8]
        /// The bytes as stored in the zip (the same as plain when stored).
        let body: [UInt8]
        let method: Int
        var flags: Int = 0
        var crc: UInt32? = nil
    }

    static func stored(_ name: String, _ plain: [UInt8]) -> ZipPart {
        ZipPart(name: name, plain: plain, body: plain, method: 0)
    }

    /// Raw DEFLATE made by hand: one final stored block (BFINAL 1, BTYPE 00).
    static func handDeflated(_ name: String, _ plain: [UInt8]) -> ZipPart {
        return ZipPart(name: name, plain: plain, body: storedBlock(plain, keep: plain.count), method: 8)
    }

    /// One final stored DEFLATE block saying `plain.count` bytes, holding the first `keep` of them.
    static func storedBlock(_ plain: [UInt8], keep: Int) -> [UInt8] {
        let n = plain.count
        var block: [UInt8] = [0x01]
        put(&block, [le16(n), le16(n ^ 0xFFFF), Array(plain.prefix(keep))])
        return block
    }

    /// Appends pieces one by one (one long `+` chain is slow to type-check).
    static func put(_ out: inout [UInt8], _ pieces: [[UInt8]]) {
        for piece in pieces { out.append(contentsOf: piece) }
    }

    static func makeZip(_ parts: [ZipPart], comment: String = "") -> Data {
        var out: [UInt8] = []
        var central: [UInt8] = []
        for part in parts {
            var crc = ArcadeCRC32()
            crc.update(part.plain)
            let sum: UInt32 = part.crc ?? crc.value
            let name: [UInt8] = Array(part.name.utf8)
            let offset = UInt32(out.count)
            let sizes: [[UInt8]] = [le32(sum), le32(UInt32(part.body.count)), le32(UInt32(part.plain.count))]
            put(&out, [[0x50, 0x4B, 0x03, 0x04], le16(20), le16(part.flags), le16(part.method), le16(0), le16(0)])
            put(&out, sizes)
            put(&out, [le16(name.count), le16(0), name, part.body])
            put(&central, [[0x50, 0x4B, 0x01, 0x02], le16(20), le16(20), le16(part.flags), le16(part.method), le16(0), le16(0)])
            put(&central, sizes)
            put(&central, [le16(name.count), le16(0), le16(0), le16(0), le16(0), le32(0), le32(offset), name])
        }
        let directoryOffset = UInt32(out.count)
        out.append(contentsOf: central)
        let note: [UInt8] = Array(comment.utf8)
        put(&out, [[0x50, 0x4B, 0x05, 0x06], le16(0), le16(0), le16(parts.count), le16(parts.count)])
        put(&out, [le32(UInt32(central.count)), le32(directoryOffset), le16(note.count), note])
        return Data(out)
    }

    static func zipFile(_ folder: URL, _ name: String, _ parts: [ZipPart], comment: String = "") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try makeZip(parts, comment: comment).write(to: url)
        return url
    }

    static func unpack(_ url: URL) throws -> (entry: ArcadeZipEntry, data: Data) {
        let entry = try ArcadeZip.gameEntry(in: ArcadeZip.entries(of: url))
        var data = Data()
        try ArcadeZip.extract(entry, from: url) { data.append($0) }
        return (entry, data)
    }

    static func problem(_ expected: ArcadeImportProblem, _ what: String, _ body: () throws -> Void) {
        do {
            try body()
            check(false, what + " (no problem was raised)")
        } catch let raised as ArcadeImportProblem {
            check(raised == expected, what + " (got \(raised))")
        } catch {
            check(false, what + " (another error: \(error))")
        }
    }

    static func zipReading() throws {
        let folder = temporaryFolder("zips")
        defer { try? FileManager.default.removeItem(at: folder) }
        let rom: [UInt8] = (0..<700).map { UInt8(($0 * 7 + 3) & 0xFF) }

        // Stored, with a readme, a folder and a Mac's extras beside the game.
        let plain = try zipFile(folder, "stored.zip", [
            stored("readme.txt", Array("homebrew test".utf8)),
            stored("demo/", []),
            stored("__MACOSX/demo/._demo.gb", [0, 1, 2]),
            stored("demo/demo.gb", rom),
        ], comment: "a comment after the directory")
        let entries = try ArcadeZip.entries(of: plain)
        check(entries.count == 4 && entries[3].name == "demo/demo.gb" && entries[3].fileName == "demo.gb", "the central directory is read past a comment")
        let first = try unpack(plain)
        check(first.entry.fileName == "demo.gb" && first.data == Data(rom), "the one game is found and unpacked, stored")

        // Deflate: a stored block made by hand, then real compressed data.
        let byHand = try zipFile(folder, "hand.zip", [handDeflated("demo.nes", rom)])
        let handOut = try unpack(byHand)
        check(handOut.data == Data(rom) && handOut.entry.method == 8, "raw DEFLATE (a stored block) is unpacked")
        let big: [UInt8] = (0..<300_000).map { UInt8(($0 / 3 + $0 % 251) & 0xFF) }
        let squeezed = try (Data(big) as NSData).compressed(using: .zlib) as Data
        let deflated = try zipFile(folder, "deflated.zip", [ZipPart(name: "demo.gba", plain: big, body: [UInt8](squeezed), method: 8)])
        let second = try unpack(deflated)
        check(squeezed.count < big.count && second.data == Data(big), "real raw DEFLATE is unpacked, past many output buffers")

        // What is refused, each with its own reason.
        let two = try zipFile(folder, "two.zip", [stored("a.gb", rom), stored("b.gba", rom)])
        problem(.zipSeveralGames, "two games in one zip") { _ = try unpack(two) }
        let none = try zipFile(folder, "none.zip", [stored("readme.txt", rom), stored("._hidden.gb", rom)])
        problem(.zipNoGame, "a zip with no game (a Mac's ._ file is not one)") { _ = try unpack(none) }
        var locked = stored("demo.gb", rom)
        locked.flags = 1
        let lockedZip = try zipFile(folder, "locked.zip", [locked])
        problem(.zipLocked, "a zip with a password") { _ = try unpack(lockedZip) }
        let odd = try zipFile(folder, "method.zip", [ZipPart(name: "demo.gb", plain: rom, body: rom, method: 12)])
        problem(.zipMethod, "a zip packed another way") { _ = try unpack(odd) }
        var wrong = stored("demo.gb", rom)
        wrong.crc = 0x1234_5678
        let damaged = try zipFile(folder, "damaged.zip", [wrong])
        problem(.zipDamaged, "a game whose crc32 does not match") { _ = try unpack(damaged) }
        let cut = ZipPart(name: "demo.gb", plain: rom, body: storedBlock(rom, keep: 100), method: 8)
        let cutZip = try zipFile(folder, "cut.zip", [cut])
        problem(.zipDamaged, "a deflated game cut short") { _ = try unpack(cutZip) }
        let notZip = folder.appendingPathComponent("not.zip")
        try Data(rom).write(to: notZip)
        problem(.notAZip, "a file that is not a zip") { _ = try ArcadeZip.entries(of: notZip) }
    }

    // MARK: The import store

    static func importStore() throws {
        let folder = temporaryFolder("imports")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ArcadeImportStore(root: folder.appendingPathComponent("imports", isDirectory: true))
        let when = Date(timeIntervalSince1970: 1_000)
        var rom = [UInt8](repeating: 0, count: 0x150)
        rom[0x143] = 0x80
        rom.append(contentsOf: Array("homebrew bytes".utf8))

        let file = folder.appendingPathComponent("Demo Quest (Homebrew).gb")
        try Data(rom).write(to: file)
        let added = try ArcadeImporter.add(file, store: store, now: when)
        check(!added.already && added.record.system == .gb && added.record.title == "Demo Quest (Homebrew)"
              && added.record.romFile == "rom.gb" && added.record.localId == sha1Hex(rom) && added.record.sha1 == sha1Hex(rom),
              "a game file is added under its local id, titled by its file name")
        check(store.record(added.record.localId) == added.record && store.records().map { $0.localId } == [added.record.localId],
              "its record reads back and it is listed")
        let kept = store.romURL(added.record).flatMap { try? Data(contentsOf: $0) }
        check(kept == Data(rom), "the ROM is kept as it came")
        let again = try ArcadeImporter.add(file, store: store, now: when)
        check(again.already, "the same file again is the same game")
        let zipped = try zipFile(folder, "demo.zip", [handDeflated("inside.gb", rom)])
        let fromZip = try ArcadeImporter.add(zipped, store: store, now: when)
        check(fromZip.already && fromZip.record.localId == added.record.localId, "the same ROM from a zip is the same game too")

        // N64 is kept in .z64 order.
        let v64: [UInt8] = [0x37, 0x80, 0x40, 0x12, 2, 1, 4, 3]
        let n64File = folder.appendingPathComponent("demo.v64")
        try Data(v64).write(to: n64File)
        let n64 = try ArcadeImporter.add(n64File, store: store, now: when)
        let n64Kept = store.romURL(n64.record).flatMap { try? Data(contentsOf: $0) }
        check(n64.record.system == .n64 && n64.record.romFile == "rom.z64" && n64Kept == Data([0x80, 0x37, 0x12, 0x40, 1, 2, 3, 4])
              && n64.record.sha1 == sha1Hex([0x80, 0x37, 0x12, 0x40, 1, 2, 3, 4]) && n64.record.localId == sha1Hex(v64),
              "an N64 file is kept and hashed in .z64 order, its local id the file as added")
        check(store.records().count == 2, "two games in My games")

        // Refused files, each with its reason.
        let text = folder.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        problem(.notAGame, "a text file") { _ = try ArcadeImporter.add(text, store: store) }
        let empty = folder.appendingPathComponent("empty.gba")
        try Data().write(to: empty)
        problem(.empty, "an empty file") { _ = try ArcadeImporter.add(empty, store: store) }
        problem(.unreadable, "a file that is not there") {
            _ = try ArcadeImporter.add(folder.appendingPathComponent("gone.gb"), store: store)
        }
        check(ArcadeImportProblem.zipSeveralGames.spoken.contains("more than one game") && ArcadeImportProblem.tooBig.spoken.contains("128 MB"),
              "every problem has its own words")

        // Titles, statuses and the words VoiceOver says.
        check(ArcadeImportText.cleanTitle("  Two\nlines ") == "Two lines" && ArcadeImportText.cleanTitle(" \n ") == nil
              && ArcadeImportText.title(fromFileName: "Demo.gba") == "Demo", "titles are one trimmed line, never empty")
        var record = added.record
        check(ArcadeImportStatus.of(record, packOnPhone: false, familyOpen: true) == .unchecked, "not asked yet")
        record.match = ArcadeMatchSummary.noMatch
        check(ArcadeImportStatus.of(record, packOnPhone: false, familyOpen: true) == .plain, "no pack: plays as the original game")
        record.match = ArcadeMatchSummary(found: true, gameId: "demo", title: "Demo", version: "20261019-abcdef12-access",
                                          size: 4_000_000, access: "family", locked: false, note: nil)
        check(ArcadeImportStatus.of(record, packOnPhone: false, familyOpen: true) == .packReady(size: 4_000_000), "a family pack inside the pack")
        check(ArcadeImportStatus.of(record, packOnPhone: false, familyOpen: false) == .locked(ArcadeImportText.familyPack),
              "a family pack outside the pack is locked with the family reason")
        check(ArcadeImportStatus.of(record, packOnPhone: false, familyOpen: nil) == .locked(ArcadeImportText.checkOnline), "offline")
        record.match?.locked = true
        check(ArcadeImportStatus.of(record, packOnPhone: false, familyOpen: true) == .locked(ArcadeImportText.familyPack),
              "the server's own lock is kept")
        record.accessPack = ArcadeImportPack(kind: "game", id: "demo", version: "20261019-abcdef12-access",
                                             sha256: String(repeating: "a", count: 64), access: "public")
        check(ArcadeImportStatus.of(record, packOnPhone: true, familyOpen: false) == .pack, "a public pack on the phone")
        // A newer pack, found by a later check: offered as an update.
        record.match = ArcadeMatchSummary(found: true, gameId: "demo", title: "Demo", version: "20261020-00000000-access",
                                          size: 5_000_000, access: "public", locked: false, note: nil)
        check(ArcadeImportStatus.of(record, packOnPhone: true, familyOpen: false) == .packUpdate(size: 5_000_000)
              && ArcadeImportStatus.packUpdate(size: nil).offersPackDownload && ArcadeImportStatus.packUpdate(size: nil).isPackUpdate,
              "a newer pack on the server is an update to download")
        record.match?.access = "family"
        check(ArcadeImportStatus.of(record, packOnPhone: true, familyOpen: false) == .pack,
              "a newer family pack is not offered outside the pack")
        record.match = ArcadeMatchSummary(found: true, gameId: "demo", title: "Demo", version: "20261019-abcdef12-access",
                                          size: 4_000_000, access: "public", locked: false, note: nil)
        check(ArcadeImportStatus.of(record, packOnPhone: true, familyOpen: false) == .pack, "the same version is no update")
        check(ArcadeImportText.rowLabel(title: "Demo", status: .pack) == "Accessibility pack. Play Demo"
              && ArcadeImportText.rowLabel(title: "Demo", status: .locked(ArcadeImportText.familyPack))
              == "The accessibility pack for this game is on the family shelf. Play Demo",
              "the status is said before Play and the title")
        check(ArcadeImportStatus.cannotRun(ArcadeImportText.cannotRun(.gb)).words == "The player can't run Game Boy games yet"
              && !ArcadeImportStatus.cannotRun("x").offersPackDownload, "a player without the core says so first")
        check(ArcadeImportText.about.contains("fingerprint") && ArcadeImportText.about.contains("never uploaded")
              && ArcadeShelf.about.contains("My games"), "the screen says only a fingerprint is checked, and where to add games")
        check(ArcadeImportProblem.unreadable.spoken.contains("Download Now"), "an iCloud file: how to download it in Files")

        // Where it plays, and its saves and reports.
        check(ArcadeImportPlay.plainQuery(record) == "system=gb&rom=local/\(record.localId).gb"
              && ArcadeImportPlay.plainROMPath(record) == "games/_plain/local/\(record.localId).gb", "the plain player's address and ROM path")
        check(ArcadeImportPlay.packROMPath(nil, gameId: "demo", system: .n64) == "games/demo/local/rom.z64"
              && ArcadeImportPlay.packROMPath("/games/demo/local/rom.z64", gameId: "x", system: .gb) == "games/demo/local/rom.z64",
              "a pack's ROM path: its romPath, else the kit's layout")
        // The kit's core files, exactly as kit 20261019-7ae651dc ships them.
        let kitCores = ["emulatorjs/cores/fceumm-legacy-wasm.data", "emulatorjs/cores/gambatte-legacy-wasm.data",
                        "emulatorjs/cores/mgba-legacy-wasm.data", "emulatorjs/cores/mupen64plus_next-wasm.data",
                        "emulatorjs/cores/reports/fceumm.json", "emulatorjs/cores/reports/mupen64plus_next.json"]
        check(ArcadeSystem.allCases.allSatisfy { ArcadeImportPlay.hasCore(kitCores, system: $0) },
              "the kit's cores run every system")
        check(!ArcadeImportPlay.hasCore(["emulatorjs/cores/fceumm-wasm.data", "emulatorjs/cores/fceumm-thread-legacy-wasm.data",
                                         "emulatorjs/cores/reports/fceumm.json"], system: .nes)
              && !ArcadeImportPlay.hasCore(["emulatorjs/cores/mupen64plus_next-legacy-wasm.data",
                                            "emulatorjs/cores/mupen64plus_next-thread-wasm.data"], system: .n64)
              && !ArcadeImportPlay.hasCore(["emulatorjs/cores/reports/gambatte.json"], system: .gb),
              "only the build EmulatorJS loads in the app counts, not another build or the report")
        check(ArcadeImportPlay.saveKey(record) == "import-" + record.localId && ArcadePaths.isSafeName(ArcadeImportPlay.saveKey(record)),
              "saves are keyed by the local id")
        check(ArcadeImportPlay.reportTarget(record).gameId == "import-gb-" + record.sha1, "a report names the game by its No-Intro sha1")

        store.delete(added.record.localId)
        check(store.records().map { $0.localId } == [n64.record.localId], "Delete removes it")
        var withPacks = n64.record
        withPacks.kit = ArcadeImportPack(kind: "kit", id: "kit", version: "20261018-27899e08", sha256: String(repeating: "b", count: 64))
        withPacks.accessPack = record.accessPack
        try store.save(withPacks)
        check(store.packKeys() == ["kit/20261018-27899e08", "demo/20261019-abcdef12-access"], "the packs an added game uses are known")
    }

    // MARK: /match

    static func matchAnswers() throws {
        let decoder = JSONDecoder()
        let none = try decoder.decode(ArcadeMatchAnswer.self, from: Data(#"{"match":null}"#.utf8))
        check(none.answered && none.match == nil, "no pack for this game")
        let silent = try decoder.decode(ArcadeMatchAnswer.self, from: Data(#"{"error":"not here"}"#.utf8))
        check(!silent.answered, "an answer without match is not an answer")
        let sha = String(repeating: "c", count: 64)
        let open = try decoder.decode(ArcadeMatchAnswer.self, from: Data("""
        {"match":{"id":"demo","title":"Demo","console":"N64","version":"20261019-abcdef12-access","size":4000000,"sha256":"\(sha)","access":"public"}}
        """.utf8))
        let pack = open.match?.pack
        check(pack?.kind == "game" && pack?.id == "demo" && pack?.version == "20261019-abcdef12-access" && pack?.size == 4_000_000
              && pack?.sha256 == sha && pack?.index == nil, "an open match is a pack to download")
        check(open.match?.summary == ArcadeMatchSummary(found: true, gameId: "demo", title: "Demo", version: "20261019-abcdef12-access",
                                                        size: 4_000_000, access: "public", locked: false, note: nil), "and its summary")
        let family = try decoder.decode(ArcadeMatchAnswer.self, from: Data("""
        {"match":{"id":"demo","title":"Demo","version":"v1-access","size":10,"sha256":"\(sha)","access":"family","locked":true,"note":"Part of the Family feature pack"}}
        """.utf8))
        check(family.match?.locked == true && family.match?.access == .family && family.match?.pack == nil,
              "a locked family match has no pack to download")
        let aliased = try decoder.decode(ArcadeMatchAnswer.self, from: Data("""
        {"match":{"id":"demo","version":"20261019-full","accessVersion":"20261019-abcdef12-access","accessSize":"77","accessSha256":"\(sha.uppercased())",
         "access":"members","signPath":"/api/kade/arcade/games/demo/20261019-abcdef12-access/pack","romPath":"games/demo/local/rom.z64",
         "files":[{"path":"games/demo/play.html","offset":0,"length":7,"type":"text/html; charset=utf-8"},{"path":"../x","offset":0,"length":1}]}}
        """.utf8))
        let alias = aliased.match
        check(alias?.version == "20261019-abcdef12-access" && alias?.size == 77 && alias?.sha256 == sha && alias?.access == .family,
              "the access fields win, and an unknown shelf is family")
        check(alias?.files?.map { $0.path } == ["games/demo/play.html"] && alias?.romPath == "games/demo/local/rom.z64"
              && alias?.pack?.signPath == "/api/kade/arcade/games/demo/20261019-abcdef12-access/pack",
              "an inline file table (unsafe rows dropped), the romPath and the sign path are kept")
        let bad = try decoder.decode(ArcadeMatchAnswer.self, from: Data(#"{"match":{"id":"../x","version":"1"}}"#.utf8))
        check(bad.answered && bad.match == nil && bad.unreadable, "a match with an unsafe id is not read, and is not 'no pack' either")
        check(!none.unreadable, "null is an answer: no pack")

        // The fork's exact unlocked answer (router.ts GET /match): no file table, a manifestPath.
        let server = try decoder.decode(ArcadeMatchAnswer.self, from: Data("""
        {"match":{"id":"demo","title":"Demo","console":"N64","access":"family","version":"20261019-abcdef12-access","size":4000000,"sha256":"\(sha)","locked":false,"manifestPath":"/api/kade/arcade/games/demo/manifest?version=20261019-abcdef12-access","signPath":"/api/kade/arcade/games/demo/20261019-abcdef12-access/pack"}}
        """.utf8))
        let served = server.match
        check(served?.manifestPath == "/api/kade/arcade/games/demo/manifest?version=20261019-abcdef12-access"
              && served?.files == nil && served?.pack?.index == nil && served?.access == .family,
              "the server's match names its manifest and carries no files")
        let asked = served?.manifestPath.flatMap { ArcadeAccessPlan.manifestRequest($0, gameId: "demo") }
        check(asked?.path == "api/kade/arcade/games/demo/manifest" && asked?.version == "20261019-abcdef12-access",
              "the manifest is asked for at its own path with its version")
        check(ArcadeAccessPlan.manifestRequest("/api/kade/arcade/games/other/manifest?version=v1", gameId: "demo") == nil
              && ArcadeAccessPlan.manifestRequest("https://elsewhere.example/api/kade/arcade/games/demo/manifest?version=v1", gameId: "demo") == nil
              && ArcadeAccessPlan.manifestRequest("/api/kade/arcade/games/demo/manifest", gameId: "demo") == nil
              && ArcadeAccessPlan.manifestRequest("/api/kade/arcade/games/demo/../../x/manifest?version=v1", gameId: "demo") == nil,
              "no other game, host or path, and never without its version")
        // The access manifest it names (router.ts /games/:id/manifest?version=<accessVersion>).
        let kitSha = String(repeating: "d", count: 64)
        let accessManifest = try decoder.decode(ArcadeManifest.self, from: Data("""
        {"id":"demo","title":"Demo","console":"N64","access":"family","version":"20261019-abcdef12-access","ready":true,
         "packs":[{"kind":"kit","id":"kit","version":"20261019-7ae651dc","size":5482214,"sha256":"\(kitSha)","signPath":"/api/kade/arcade/kit/20261019-7ae651dc/pack",
                   "files":[{"path":"core/app.js","offset":0,"size":16160,"mime":"text/javascript; charset=utf-8","sha256":"\(kitSha)"},
                            {"path":"emulatorjs/cores/mupen64plus_next-wasm.data","offset":16160,"size":100,"mime":"application/octet-stream"}]},
                  {"kind":"game","id":"demo","version":"20261019-abcdef12-access","size":4000000,"sha256":"\(sha)","signPath":"/api/kade/arcade/games/demo/20261019-abcdef12-access/pack",
                   "files":[{"path":"games/demo/play.html","offset":0,"size":3194,"mime":"text/html; charset=utf-8"}]}],
         "entry":"games/demo/play.html","emulatorData":"emulatorjs/","romPath":"games/demo/local/rom.z64"}
        """.utf8))
        check(accessManifest.romPath == "games/demo/local/rom.z64" && accessManifest.problem == nil, "the access manifest carries the romPath")
        if let match = served, let plan = ArcadeAccessPlan.make(manifest: accessManifest, match: match) {
            check(plan.accessPack.key == "demo/20261019-abcdef12-access" && plan.accessPack.index?.map { $0.path } == ["games/demo/play.html"]
                  && plan.accessPack.sha256 == sha && plan.kit.key == "kit/20261019-7ae651dc" && plan.kit.index?.count == 2,
                  "the plan takes the pack with its files, and the kit, from the one manifest")
            check(plan.romPath == "games/demo/local/rom.z64" && plan.entry == "games/demo/play.html" && plan.emulatorData == "emulatorjs/",
                  "and the page, the emulator folder and where the ROM goes")
            check(ArcadeImportPlay.hasCore(plan.kit.index?.map { $0.path } ?? [], system: .n64)
                  && !ArcadeImportPlay.hasCore(plan.kit.index?.map { $0.path } ?? [], system: .gb), "the kit's cores are known by name")
        } else {
            check(false, "the server's match and its access manifest make a plan")
        }
        let older = try decoder.decode(ArcadeMatchAnswer.self, from: Data("""
        {"match":{"id":"demo","title":"Demo","access":"family","version":"20261020-00000000-access","size":4000000,"sha256":"\(sha)","locked":false,"manifestPath":"/api/kade/arcade/games/demo/manifest?version=20261020-00000000-access"}}
        """.utf8))
        check(older.match.flatMap { ArcadeAccessPlan.make(manifest: accessManifest, match: $0) } == nil,
              "a manifest without the matched version is no plan")

        // The fork's exact locked answer, outside the Family feature pack.
        let lockedAnswer = try decoder.decode(ArcadeMatchAnswer.self, from: Data("""
        {"match":{"id":"family-shelf","title":"Family shelf","console":"N64","access":"family","version":"","size":0,"locked":true,"note":"Part of the Family feature pack"}}
        """.utf8))
        check(lockedAnswer.answered && !lockedAnswer.unreadable && lockedAnswer.match?.locked == true
              && lockedAnswer.match?.id == "family-shelf" && lockedAnswer.match?.version == "" && lockedAnswer.match?.pack == nil,
              "the server's locked answer is read, with nothing to download")
        if let locked = lockedAnswer.match {
            var record = ArcadeImportRecord(localId: String(repeating: "e", count: 40), title: "Demo", system: .n64, fileName: "Demo.z64",
                                            romFile: "rom.z64", sha1: String(repeating: "f", count: 40), crc32: "00000000", size: 8,
                                            added: Date(timeIntervalSince1970: 0))
            var summary = locked.summary
            summary.familyOpen = false
            record.match = summary
            check(ArcadeImportStatus.of(record, packOnPhone: false, familyOpen: false) == .locked(ArcadeImportText.familyPack),
                  "an outsider hears that the pack is on the family shelf")
            check(ArcadeImportStatus.of(record, packOnPhone: false, familyOpen: true) == .unchecked,
                  "a family account on the same iPhone is not told another account's lock")
            record.match = ArcadeMatchSummary(found: false, locked: false, familyOpen: false)
            check(ArcadeImportStatus.of(record, packOnPhone: false, familyOpen: true) == .unchecked
                  && ArcadeImportStatus.of(record, packOnPhone: false, familyOpen: false) == .plain
                  && ArcadeImportStatus.of(record, packOnPhone: false, familyOpen: nil) == .plain,
                  "nor another account's 'no pack' (the daily cap), and offline keeps what was heard")
        }

        let config = try decoder.decode(ArcadeConfig.self, from: Data(#"{"catalog":[],"kit":{"version":"20261018-27899e08","size":2382551}}"#.utf8))
        check(config.kitVersion == "20261018-27899e08", "the config names the kit for added games")
        let noKit = try decoder.decode(ArcadeConfig.self, from: Data(#"{"catalog":[],"kit":null}"#.utf8))
        check(noKit.kitVersion == nil, "no kit yet")
    }

    // MARK: The ROM served where the page expects it

    static func overlayServing() throws {
        let folder = temporaryFolder("overlay")
        defer { try? FileManager.default.removeItem(at: folder) }
        let romFile = folder.appendingPathComponent("rom.gb")
        try Data([UInt8](0..<10)).write(to: romFile)
        let overlay = ArcadeOverlay(path: "games/_plain/local/demo.gb", file: romFile, length: 10)
        let ranged = ArcadeServePlan.make(url: URL(string: "kadearcade://kit/games/_plain/local/demo.gb")!, rangeHeader: "bytes=2-5",
                                          game: [], kit: [], overlays: [overlay])
        if case .serve(let blob, let offset, let length, let status, let headers) = ranged {
            check(blob == romFile && offset == 2 && length == 4 && status == 206 && headers["Content-Range"] == "bytes 2-5/10"
                  && headers["Content-Type"] == "application/octet-stream", "the added ROM is served in ranges from its own file")
        } else {
            check(false, "the added ROM is served")
        }
        let whole = ArcadeServePlan.make(url: URL(string: "kadearcade://game/games/_plain/local/demo.gb")!, rangeHeader: nil,
                                         game: [], kit: [], overlays: [overlay])
        if case .serve(_, let offset, let length, let status, let headers) = whole {
            check(offset == 0 && length == 10 && status == 200 && headers["Content-Length"] == "10", "on either host, whole")
        } else {
            check(false, "the added ROM is served on the game host too")
        }
        check(ArcadeServePlan.make(url: URL(string: "kadearcade://kit/games/_plain/local/other.gb")!, rangeHeader: nil,
                                   game: [], kit: [], overlays: [overlay]) == .notFound("games/_plain/local/other.gb"),
              "only the overlay's own path")
        check(ArcadeServePlan.make(url: URL(string: "kadearcade://kit/games/_plain/local/demo.gb")!, rangeHeader: "bytes=20-",
                                   game: [], kit: [], overlays: [overlay]) == .unsatisfiable(total: 10), "past its end")
    }
}
