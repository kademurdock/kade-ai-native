import Foundation

// FAMILY HISTORY TESTS (Sep 29 2026). No Mac, no Xcode, no network:
//
//   ./run-family-tests.sh
//
// Builds FamilyModels, FamilyPayloads, FamilyGeometry and the made-up demo
// family (FamilyDemoData, compiled with -D DEBUG) with swiftc, then checks
// that every demo answer decodes, that a bad field or element costs only
// itself, that the first version's answers still read, the drawing maths,
// and that every "open" key the server may send reaches a screen.
// Everything here is fictional ("Ada Example"); this repository is public.

@main enum FamilyHistoryTests {
    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static func main() throws {
        var passed = 0
        func check(_ condition: Bool, _ what: String) {
            precondition(condition, "FAILED: " + what)
            passed += 1
        }

        // MARK: Every demo answer decodes, with what the screens need.

        let me = try decode(FHMe.self, FamilyDemoData.me)
        check(me.isCurrent && me.access == true, "demo /me is the current version and open")
        check(me.viewer?.first == "Jack" && me.owner?.first == "Ada", "demo /me names the viewer and the owner")
        check(me.row?.detail == "Ada's brother", "demo /me carries the Library row's words")

        let home = try decode(FHHome.self, FamilyDemoData.home)
        check(home.tiles.count == 4, "home has exactly four tiles")
        check(home.more.count == 6, "home has six More rows")
        check(home.faces?.people.count == 5, "home has five faces")
        check(home.reel?.cards.count == 5 && home.reel?.cover?.id == "m-tree1", "home has the reel and its cover")
        check(home.featured.count == 2 && home.news?.images.count == 1, "home has featured cards and news")
        check(home.hero?.open?.target == .route(.tree(focus: nil, name: "")), "the hero opens the tree")
        check(home.reel?.cover?.restored == "m-tree1r" && home.reel?.cover?.restoredLabel != nil, "a picture names its restored copy")
        for tile in home.tiles + home.more {
            check(tile.open?.target != nil, "tile \(tile.key) opens somewhere")
        }

        let tree = try decode(FHTree.self, FamilyDemoData.tree)
        let boxes = tree.layout?.boxes ?? []
        check(boxes.count == 11, "the tree has eleven boxes")
        check(Set(boxes.map { $0.key }).count == boxes.count, "box keys are unique")
        let keys = Set(boxes.map { $0.key })
        check((tree.layout?.order ?? []).allSatisfy { keys.contains($0) }, "the order names only boxes that exist")
        check((tree.layout?.edges ?? []).allSatisfy { keys.contains($0.from) && keys.contains($0.to) }, "every line joins two boxes")
        check(tree.layout?.couples.count == 3 && tree.layout?.width == 4 && tree.layout?.rows == 4, "couples and the tree's size")
        check(boxes.first(where: { $0.you == true })?.personId == "@I101@", "the viewer's own box is marked")
        check(boxes.first(where: { $0.key == "@I700@#10" })?.person?.research?.level == "dna", "a research box carries its proof")
        check(tree.list.count == 4 && tree.list[1].rows.count == 4, "the tree's list has generation headings")
        check(tree.summary?.spoken?.isEmpty == false, "the tree has a spoken summary")

        let dan = try decode(FHPersonPage.self, FamilyDemoData.personDan)
        check(dan.person?.id == "@I300@" && dan.person?.otherNames == ["Daniel Example"], "a person page names its person")
        check(dan.pictures?.items.count == 4 && dan.pictures?.items.first?.isRestoredCopy == true, "restored copies come first")
        check(dan.records.first?.fields.count == 4, "a record's fields read")
        check(dan.records.first?.household.last == ["Dan Example", "Son", "20"], "numbers in a household row become text")
        check(dan.grave?.photos.count == 1 && dan.relation?.ladder.count == 3, "grave and ladder read")
        check(dan.family?.children.count == 2 && dan.life.count == 4, "family and life read")
        let hugo = try decode(FHPersonPage.self, FamilyDemoData.personHugo)
        check(hugo.withheld?.count == 1 && hugo.header == nil, "a withheld source and no header read")

        let gallery = try decode(FHGallery.self, FamilyDemoData.gallery)
        check(gallery.items.count == 2 && gallery.kinds.count == 4, "a gallery page reads")
        check(gallery.items[0].people.first?.id == "@I300@" && gallery.items[0].index == 1, "a gallery cell carries its people and number")
        let info = try decode(FHMediaInfo.self, FamilyDemoData.mediaInfo)
        check(info.image?.id == "m-tree1" && info.description?.isEmpty == false, "a picture's description reads")
        let signed = try decode(FHSigned.self, FamilyDemoData.signed)
        check(signed.urls.isEmpty, "the demo signs no links")

        let dna = try decode(FHDNA.self, FamilyDemoData.dna)
        check(dna.test?.applies == "fullSibling" && dna.test?.cards.count == 1, "the DNA test section reads")
        check(dna.test?.mysteries?.cards.count == 1 && dna.test?.mysteries?.headsUp != nil, "the mysteries sit behind a heads-up")
        check(dna.paper?.generations.map { $0.wedges.count } == [4, 8], "the paper fan's generations read")
        check(dna.compare?.averages.first?.relationClass == "first cousin", "\"class\" reads as relationClass")
        check(dna.birthplaces?.rows.first?.count == 3 && dna.abroad?.rows.count == 1, "birthplaces and abroad read")

        let timeline = try decode(FHTimeline.self, FamilyDemoData.timeline)
        check(timeline.decades.map { $0.decade ?? 0 } == [1950, 1900, 1870], "decades run newest first")
        check(timeline.people.count == 4 && timeline.decades[0].bars.count == 3, "timeline people and bars read")

        let places = try decode(FHPlaces.self, FamilyDemoData.places)
        check(places.places.count == 2 && places.decades[0].counts["p1"] == 3, "places and their counts read")
        check(places.ocean.first?.from?.lat == 54.0 && places.journeys.count == 1, "the ocean crossing reads")

        let stories = try decode(FHStories.self, FamilyDemoData.stories)
        check(stories.stories.first?.slug == "the-farm" && stories.clippings.count == 1, "the stories list reads")
        let story = try decode(FHStory.self, FamilyDemoData.story)
        check(story.blocks.count == 4 && story.short.count == 3 && story.whoswho.count == 3, "a story's blocks read")
        check(story.blocks[1].runs.last?.source == 1, "a source chip reads")
        check(story.chunks.count == 2 && story.listen == true, "a story's parts read")
        for chunk in story.chunks {
            check(FamilyGeometry.cuesInOrder(chunk.cues), "part \(chunk.i ?? -1)'s cues are in order and end at 1")
        }

        let findings = try decode(FHFindings.self, FamilyDemoData.findings)
        check(findings.discoveries.count == 1 && findings.mysteries?.count == 1, "discoveries and the mysteries row read")
        let mysteries = try decode(FHFindings.self, FamilyDemoData.mysteries)
        check(mysteries.findings.first?.proof == "dna" && mysteries.headsUp != nil, "the mysteries read")

        let play = try decode(FHPlay.self, FamilyDemoData.play)
        check(play.rounds.count == 3 && play.rounds.allSatisfy { $0.playable }, "every game round is playable")

        let people = try decode(FHPeople.self, FamilyDemoData.people)
        check(people.sections.count == 3 && people.total == 8, "everyone in the tree reads")
        let search = try decode(FHPeople.self, FamilyDemoData.search)
        check(search.people.count == 1 && search.spoken == "1 person found", "search results read")
        let note = try decode(FHNoteSent.self, FamilyDemoData.noteSent)
        check(note.ok == true && note.text?.isEmpty == false, "a sent note reads")

        check(FamilyDemoData.payload(path: "person/@I300@") != nil, "the demo has Dan's page")
        check(FamilyDemoData.payload(path: "person/@I999@") == nil, "an unknown person is a 404")
        check(FamilyDemoData.payload(path: "findings", query: ["group": "mysteries"]) == FamilyDemoData.mysteries, "group=mysteries answers the mysteries")
        check(FamilyDemoData.payload(path: "sky") == nil, "an unknown route is a 404")

        // Spoken words never carry symbols VoiceOver reads badly, or all-caps words.
        let answers: [(String, String)] = [
            ("me", FamilyDemoData.me), ("home", FamilyDemoData.home), ("tree", FamilyDemoData.tree),
            ("personDan", FamilyDemoData.personDan), ("personHugo", FamilyDemoData.personHugo),
            ("gallery", FamilyDemoData.gallery), ("mediaInfo", FamilyDemoData.mediaInfo), ("dna", FamilyDemoData.dna),
            ("timeline", FamilyDemoData.timeline), ("places", FamilyDemoData.places), ("stories", FamilyDemoData.stories),
            ("story", FamilyDemoData.story), ("findings", FamilyDemoData.findings), ("mysteries", FamilyDemoData.mysteries),
            ("play", FamilyDemoData.play), ("people", FamilyDemoData.people), ("search", FamilyDemoData.search),
        ]
        for (name, json) in answers {
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
            let problems = spokenProblems(object)
            check(problems.isEmpty, "\(name) spoken words are clean: \(problems)")
        }

        // MARK: A bad field or element costs only itself.

        let person = try decode(FHPerson.self, #"{"id":"@X1@","name":"Ada Example","gen":"four","living":"yes","face":7,"otherNames":["A",3,null,"B"],"years":1850}"#)
        check(person.name == "Ada Example" && person.gen == nil && person.living == true, "a wrong gen is nil, living reads as text")
        check(person.face == nil && person.otherNames == ["A", "B"] && person.years == "1850", "a wrong face is nil; bad names are dropped")
        let messy = try decode(FHHome.self, #"{"hero":7,"tiles":[{"key":"a"},5,null,{"key":"b","enabled":"no"}],"footnote":"Made up.","owner":{"notes":"2"}}"#)
        check(messy.hero == nil && messy.footnote == "Made up.", "a broken hero leaves the rest")
        check(messy.tiles.map { $0.key } == ["a", "b"] && messy.tiles[1].isEnabled == false, "bad tiles are dropped, the rest keep their order")
        check(messy.owner?.notes == 2, "a number as text reads")
        let box = try decode(FHTreeBox.self, #"{"key":"@X1@#0","id":"@X1@","x":"1.5","row":2.0,"repeat":1,"moreAbove":1e300}"#)
        check(box.x == 1.5 && box.row == 2 && box.repeated == true && box.moreAbove == nil, "box numbers are checked")
        let image = try decode(FHImage.self, #"{"id":"m1","category":"hologram","thumb":"","year":"1920","w":0,"h":10}"#)
        check(image.categoryKind == .other && image.thumb == nil && image.year == 1920 && image.aspect == nil, "unknown kinds fall back")
        check(FHSide(raw: "cousin") == .unknown && FHLockReason(raw: "later") == .unknown, "unknown sides and reasons fall back")
        let record = try decode(FHRecord.self, #"{"fields":[["Age",34],["Name",null],"oops",["Place","Invented Town"]]}"#)
        check(record.fields == [["Age", "34"], ["Name", ""], ["Place", "Invented Town"]], "record cells read, a broken row is dropped")
        let counts = try decode(FHPlaceDecade.self, #"{"decade":1880,"counts":{"p1":3,"p2":"4","p3":"many"}}"#)
        check(counts.counts == ["p1": 3, "p2": 4], "counts read, bad ones are dropped")

        // MARK: The first version's answers (live today) still decode.

        let v1me = try decode(FHMe.self, #"{"access":true,"viewer":{"personId":"@X1@","name":"Ada Example","label":"Ada Example (born 1990)","relationToOwner":{"term":"you","group":"self"}},"mode":"owner","isOwner":true,"version":"v1","counts":{"people":18}}"#)
        check(v1me.access == true && !v1me.isCurrent && v1me.viewer?.label != nil, "a first-version /me reads, and is known to be old")
        let v1locked = try decode(FHLocked.self, #"{"access":false,"error":"The family history is private to the family."}"#)
        check(v1locked.error != nil && v1locked.reasonKind == .unknown && !v1locked.mayAsk, "a first-version 403 reads")
        let unmatched = try decode(FHLocked.self, #"{"access":false,"reason":"unmatched","error":"Private.","detail":"Not linked to the tree yet","hint":"Ask the tree's owner to match your account.","canAsk":true,"askedAt":null}"#)
        check(unmatched.reasonKind == .unmatched && unmatched.mayAsk, "an unmatched account may ask")
        let asked = try decode(FHLocked.self, #"{"reason":"unmatched","canAsk":true,"askedAt":"2026-09-29T12:00:00.000Z"}"#)
        check(!asked.mayAsk, "an account that asked may not ask again")
        let v1stories = try decode(FHStories.self, #"[{"slug":"the-farm","title":"The farm on Example Road","words":14},{"title":"no slug"}]"#)
        check(v1stories.stories.count == 2 && v1stories.stories[0].words == 14, "a first-version stories list reads")
        let v1findings = try decode(FHFindings.self, #"[{"summary":"An invented finding.","people":[{"id":"@X1@","label":"Ada Example (born 1990)"}]}]"#)
        check(v1findings.findings.first?.summary != nil && v1findings.findings.first?.people.first?.shownName == "Ada Example (born 1990)", "first-version findings read")
        let v1search = try decode(FHPeople.self, #"[{"id":"@X1@","label":"Ada Example (born 1990)","lifespan":"born 1990"}]"#)
        check(v1search.people.first?.lifespan == "born 1990", "a first-version search reads")
        let v1tree = try decode(FHTree.self, #"{"focus":"@X1@","nodes":[{"id":"@X1@"}],"links":[],"couples":[]}"#)
        check(v1tree.focus == "@X1@" && v1tree.layout == nil, "a first-version tree reads with no layout")
        let v1story = try decode(FHStory.self, #"{"slug":"the-farm","title":"The farm","markdown":"# The farm"}"#)
        check(v1story.markdown == "# The farm" && v1story.blocks.isEmpty, "a first-version story reads")

        // MARK: Drawing maths.

        for count in [1, 2, 4, 8, 16, 32] {
            let whole = FamilyGeometry.fanWedges(count: count, half: false)
            let half = FamilyGeometry.fanWedges(count: count, half: true, rightSide: true)
            check(abs(whole.reduce(0) { $0 + $1.sweep } - 180) < 1e-9, "\(count) wedges fill exactly 180 degrees")
            check(abs(half.reduce(0) { $0 + $1.sweep } - 90) < 1e-9, "\(count) wedges fill exactly 90 degrees in a half fan")
            check(zip(whole, whole.dropFirst()).allSatisfy { abs($0.end - $1.start) < 1e-9 }, "\(count) wedges leave no gaps")
            check(whole.first?.start == 180 && half.first?.start == 270, "a fan starts at the left, a right half fan at the top")
        }
        let normal = FamilyTreeMetrics()
        for scale in FamilyTreeScale.allCases {
            let scaled = normal.scaled(scale)
            let a = scaled.origin(x: 2.5, row: 3)
            let b = normal.origin(x: 2.5, row: 3)
            check(abs(a.x - b.x * scale.factor) < 1e-9 && abs(a.y - b.y * scale.factor) < 1e-9, "the \(scale.rawValue) step scales linearly")
        }
        check(normal.origin(x: 0, row: 0) == FHPoint(x: 0, y: 0), "the first box sits at the corner")
        check(normal.canvas(width: 4, rows: 4).x == 4 * (normal.boxWidth + normal.gapX) - normal.gapX, "the chart is as wide as its boxes")
        for count in 1...7 {
            for (width, height, face) in [(320.0, 120.0, 56.0), (390.0, 140.0, 64.0), (700.0, 180.0, 72.0), (40.0, 40.0, 64.0)] {
                let points = FamilyGeometry.faceArc(count: count, width: width, height: height, face: face)
                let r: Double = min(face, width, height) / 2
                check(points.count == count, "\(count) faces get \(count) places")
                check(points.allSatisfy { inside($0, radius: r, width: width, height: height) }, "\(count) faces stay inside \(width) by \(height)")
            }
        }
        check(FamilyGeometry.faceArc(count: 0, width: 300, height: 100, face: 60).isEmpty, "no faces, no places")
        check(FamilyGeometry.laneX(lane: 0, lanes: 4, width: 400) == 50 && FamilyGeometry.laneX(lane: 9, lanes: 4, width: 400) == 350, "lanes are centred and clamped")
        check(FamilyGeometry.yearY(1890, decade: 1880, height: 100) == 0 && FamilyGeometry.yearY(1880, decade: 1880, height: 100) == 100, "a decade's end is at the top")
        check(FamilyGeometry.barSpan(from: 1850, to: 1921, decade: 1880, height: 100).map { $0.top == 0 && $0.bottom == 100 } == true, "a life across a decade fills its band")
        check(FamilyGeometry.barSpan(from: 1901, to: 1950, decade: 1880, height: 100) == nil, "a life after a decade is not in its band")
        check(FamilyGeometry.mapDot(count: 0, maxCount: 5).opacity == 0 && FamilyGeometry.mapDot(count: 5, maxCount: 5).size == 36, "empty places fade, the fullest is largest")
        let cues = [FHCue(text: "One.", start: 0, end: 0.4), FHCue(text: "Two.", start: 0.4, end: 1)]
        check(FamilyGeometry.cueIndex(cues, at: 0.1) == 0 && FamilyGeometry.cueIndex(cues, at: 0.5) == 1, "the cue playing is found")
        check(FamilyGeometry.cuesInOrder(cues) && !FamilyGeometry.cuesInOrder([FHCue(text: "x", start: 0.5, end: 0.2)]), "cue order is checked")
        check(FamilyGeometry.trimTrail(Array(1...9), keep: 4) == [1, 7, 8, 9] && FamilyGeometry.trimTrail([1, 2], keep: 4) == [1, 2], "the trail keeps you and the last steps")

        // MARK: Every "open" key reaches a screen.

        for key in FHOpen.knownKeys {
            check(FHOpen(to: key, id: "x").target != nil, "open \(key) goes somewhere")
        }
        check(FHOpen(to: "sky").target == nil, "an unknown open is ignored")
        check(FHOpen(to: "person").target == nil, "a person without an id is ignored")
        check(FHOpen(to: "note", id: "@X1@").target == .note(personId: "@X1@"), "a note opens the note sheet")
        check(FHOpen(to: "gallery", id: "@X1@", since: "v2", filter: "records").target
              == .route(.gallery(FamilyGalleryRoute(kind: "records", person: "@X1@", since: "v2"))), "a gallery open keeps its filter")
        let routes: [FamilyRoute] = [
            .home, .reel, .tree(focus: nil, name: ""), .tree(focus: "@X1@", name: "Ada"), .person(FamilyPersonRoute(id: "@X1@")),
            .gallery(FamilyGalleryRoute()), .whereWhen(map: false), .whereWhen(map: true), .dna(forId: nil), .stories,
            .story(slug: "the-farm", title: ""), .discoveries, .mysteries, .people, .play, .locked,
        ]
        check(Set(routes.map { $0.id }).count == routes.count, "every route has its own id")

        print("Family history: \(passed) checks passed. This checks decoding, routes and drawing maths, not SwiftUI or VoiceOver.")
    }

    /// A face of this radius centred here fits the frame.
    static func inside(_ p: FHPoint, radius r: Double, width: Double, height: Double) -> Bool {
        let slack: Double = 1e-9
        let left: Bool = p.x - r >= -slack
        let right: Bool = p.x + r <= width + slack
        let top: Bool = p.y - r >= -slack
        let bottom: Bool = p.y + r <= height + slack
        return left && right && top && bottom
    }

    /// Spoken fields with a symbol VoiceOver reads badly or an all-caps word.
    static func spokenProblems(_ object: Any) -> [String] {
        var found: [String] = []
        let forbidden: [Character] = ["\u{00B7}", "\u{2013}", "\u{2014}", "\u{25B2}", "\u{25C0}", "\u{25B6}"]
        let allowedCaps: Set<String> = ["DNA", "AI"]
        func visit(_ value: Any) {
            if let dict = value as? [String: Any] {
                for (key, inner) in dict {
                    if ["spoken", "spokenExplain", "pageSpoken", "yearsSpoken"].contains(key), let text = inner as? String {
                        if text.contains(where: { forbidden.contains($0) }) { found.append(text) }
                        let words = text.split(whereSeparator: { !$0.isLetter }).map(String.init)
                        for word in words where word.count >= 2 && word == word.uppercased() && !allowedCaps.contains(word) {
                            found.append(word)
                        }
                    }
                    visit(inner)
                }
            } else if let list = value as? [Any] {
                for inner in list { visit(inner) }
            }
        }
        visit(object)
        return found
    }
}
