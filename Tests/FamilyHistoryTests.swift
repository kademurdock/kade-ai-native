import Foundation

// FAMILY HISTORY TESTS (Sep 29 2026). No Mac, no Xcode, no network:
//
//   ./run-family-tests.sh
//
// Builds FamilyModels, FamilyPayloads, FamilyGeometry, FamilyRules and the
// made-up demo family (FamilyDemoData, compiled with -D DEBUG) with swiftc,
// then checks that every demo answer decodes, that a bad field or element
// costs only itself, that the first version's answers still read, the
// drawing maths, that every "open" key the server may send reaches a screen,
// who may open the section and what the Library row says, and the phone's
// own rules for caches, signed-link batches and paging.
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
        let dnaV2 = try decode(FHDNA.self, #"""
        {"title":"Ada's DNA test counts for you too","for":"@X1@","forName":null,
         "test":{"applies":"fullSibling","title":"Ada's DNA test counts for you too","intro":"Made up.",
          "cards":[{"key":"c1","title":"The family of your grandparents","text":"12 of Ada's DNA cousins descend from this family.","people":[],"proof":"records","proofText":"Proven by records","storySlug":null,"spoken":"The family of your grandparents.","band":"about 90 to 400 cM","members":12,"matches":[{"name":"Invented Match One","cM":120,"segments":6},{"name":"Invented Match Two","cM":"95.5"}]}],
          "mysteries":null,
          "details":{"title":"Details for DNA fans","rows":["Invented method."],"caveats":["An invented caveat."],"clusters":[{"key":"c1","title":"The family of your grandparents","band":"about 90 to 400 cM","members":12,"matches":[{"name":"Invented Match One","cM":120,"segments":6}]}]},
          "footnote":"Full siblings share about half their DNA, but not the same half."},
         "paper":{"title":"Where your DNA comes from, on paper","startGen":2,"half":true,"note":"Averages.",
          "generations":[{"gen":1,"name":"parents","slots":1,"named":1,"text":"Your mother has a name.","spoken":"Generation 1, parents: 1 of 1 known",
           "wedges":[{"ahnen":3,"state":"known","side":"mother","living":true,"person":{"id":"@X2@","name":"Cora Example"},"share":"1 in 2"}]}]},
         "birthplaces":{"gen":3,"title":"Where your 8 great-grandparents were born","rows":[{"place":"Invented Land","kind":"country","count":1,"people":["@X4@"]}],"unknown":7,"text":"1 in Invented Land. 7 not known yet.","spoken":"Where your 8 great-grandparents were born: 1 in Invented Land. 7 not known yet.","note":"Not an ethnicity estimate.",
          "byGen":[{"gen":2,"title":"Where your 4 grandparents were born","rows":[],"unknown":4},{"gen":3,"title":"Where your 8 great-grandparents were born","rows":[{"place":"Invented Land","count":1}],"unknown":7}]},
         "abroad":{"text":"1 of your ancestors was born outside the United States.","spoken":"1 of your ancestors was born outside the United States.","rows":[]},
         "compare":{"title":"How much DNA you share with a relative","averages":[{"key":"firstCousin","class":"a first cousin","percent":"about 12.5%","text":"With a first cousin: about 12.5% on average.","details":null},{"class":"a parent or child","percent":"about 50%"}],"note":"On paper, on average."}}
        """#)
        check(dnaV2.forId == "@X1@" && dnaV2.test?.title == dnaV2.title && dnaV2.test?.footnote != nil, "the DNA answer names whose paper it is, and the test's own title")
        let clusterCard: FHDNACard? = dnaV2.test?.cards.first
        check(clusterCard?.members == 12 && clusterCard?.band == "about 90 to 400 cM" && clusterCard?.matches.count == 2, "a card carries its cluster's size, band and matches")
        check(clusterCard?.matches.last?.cM == 95.5 && clusterCard?.matches.first?.segments == 6, "a match's shared cM reads, also as text")
        check(clusterCard?.asFinding.title == clusterCard?.title && clusterCard?.asFinding.proof == "records", "a DNA card draws as a finding")
        check(dnaV2.test?.details?.caveats.count == 1 && dnaV2.test?.details?.clusters.first?.matches.count == 1, "the details carry caveats and clusters")
        check(dnaV2.paper?.half == true && dnaV2.paper?.title != nil, "a half fan says so")
        let onlyWedge: FHWedge? = dnaV2.paper?.generations.first?.wedges.first
        check(onlyWedge?.living == true && onlyWedge?.isNamed == true && onlyWedge?.isResearch == false, "a living relative's slot counts as named")
        check(dnaV2.birthplaces?.byGen.count == 2 && dnaV2.birthplaces?.byGen.last?.rows.first?.count == 1, "birthplaces come for every generation")
        check(dnaV2.birthplaces?.rows.first?.kind == "country" && dnaV2.birthplaces?.text != nil, "a birthplace row says whether it is a country")
        check(dnaV2.abroad?.spoken != nil && dnaV2.compare?.title != nil && dnaV2.compare?.note != nil, "abroad and compare carry their words")
        check(dnaV2.compare?.averages.first?.shownText == "With a first cousin: about 12.5% on average."
              && dnaV2.compare?.averages.last?.shownText == "a parent or child: about 50%", "an average's words, or its kind and share")
        let unknownSlot = try decode(FHWedge.self, #"{"ahnen":9,"state":"unknown","side":"father","person":null}"#)
        let researchSlot = try decode(FHWedge.self, #"{"ahnen":12,"state":"research","side":"mother","person":{"id":"@X7@"}}"#)
        check(!unknownSlot.isNamed && researchSlot.isNamed && researchSlot.isResearch, "unknown and research slots")

        let timeline = try decode(FHTimeline.self, FamilyDemoData.timeline)
        check(timeline.decades.map { $0.decade ?? 0 } == [1950, 1900, 1870], "decades run newest first")
        check(timeline.people.count == 4 && timeline.decades[0].bars.count == 3, "timeline people and bars read")
        let timelineV2 = try decode(FHTimeline.self, #"{"scope":"all","title":"All relatives","top":"You, today","hint":"Scroll down to go back in time.","lanes":2,"mapReady":false,"people":{},"decades":[{"decade":1940,"title":"1940s","context":[{"key":"ww2","title":"World War II","text":"1 of your ancestors was an adult during World War II.","spoken":"1 of your ancestors was an adult during World War II."}],"bars":[{"id":"@X1@","lane":1,"from":1900,"to":1970,"side":"father","research":false}],"events":[]}]}"#)
        check(timelineV2.title == "All relatives" && timelineV2.top == "You, today" && timelineV2.hint != nil && timelineV2.mapReady == false, "the timeline's own words read")
        check(timelineV2.decades.first?.context.first?.key == "ww2" && timelineV2.decades.first?.bars.first?.personId == "@X1@", "a context line and a lifeline read")

        let places = try decode(FHPlaces.self, FamilyDemoData.places)
        check(places.places.count == 2 && places.decades[0].counts["p1"] == 3, "places and their counts read")
        check(places.ocean.first?.from?.lat == 54.0 && places.journeys.count == 1, "the ocean crossing reads")
        check(places.startIndex == 0, "the map opens on the richest decade")
        let placesV2 = try decode(FHPlaces.self, #"{"scope":"ancestors","places":[{"id":"p1","short":"Invented County, IS","lat":10.123,"lon":-20.456,"precision":"county"}],"people":{},"start":1920,"decades":[{"decade":1900,"counts":{}},{"decade":1920,"counts":{"p1":1}}],"ocean":[{"personId":"@X4@","text":"Made up.","spoken":"Made up, said.","from":{"lat":61.9,"lon":25.7},"to":{"lat":10.123,"lon":-20.456}}],"journeys":[{"personId":"@X3@","text":"Born in Invented County.","spoken":"Born in Invented County, said."}],"note":"Places come from records."}"#)
        check(placesV2.startIndex == 1 && placesV2.note != nil && placesV2.scope == "ancestors", "the map opens on the server's start decade, with its note")
        check(placesV2.ocean.first?.spoken == "Made up, said." && placesV2.journeys.first?.spoken != nil, "crossings and journeys carry their spoken words")
        check(FHPlaces(start: 1990).startIndex == 0, "a start decade that is missing opens the first")
        let fit = FamilyGeometry.mapFit(latitudes: [10, 20], longitudes: [-40, -20])
        check(fit?.lat == 15 && fit?.lon == -30 && abs((fit?.latDelta ?? 0) - 14) < 1e-9 && abs((fit?.lonDelta ?? 0) - 28) < 1e-9, "the map fits every place, with room around")
        check(FamilyGeometry.mapFit(latitudes: [10.123], longitudes: [-20.456])?.latDelta == 3 && FamilyGeometry.mapFit(latitudes: [], longitudes: []) == nil, "one place gets a small area; none gets none")
        let crossing: Double = FamilyGeometry.bearing(fromLat: 61.9, fromLon: 25.7, toLat: 10.123, toLon: -20.456)
        check(abs(FamilyGeometry.bearing(fromLat: 0, fromLon: 0, toLat: 0, toLon: 10) - 90) < 1e-6
              && abs(FamilyGeometry.bearing(fromLat: 0, fromLon: 0, toLat: 10, toLon: 0)) < 1e-6
              && crossing > 180 && crossing < 270, "headings: east is 90, north is 0, the made-up crossing heads south-west")

        let stories = try decode(FHStories.self, FamilyDemoData.stories)
        check(stories.stories.first?.slug == "the-farm" && stories.clippings.count == 1, "the stories list reads")
        let story = try decode(FHStory.self, FamilyDemoData.story)
        check(story.blocks.count == 4 && story.short.count == 3 && story.whoswho.count == 3, "a story's blocks read")
        check(story.blocks[1].runs.last?.source == 1, "a source chip reads")
        check(story.chunks.count == 2 && story.listen == true, "a story's parts read")
        for chunk in story.chunks {
            check(FamilyGeometry.cuesInOrder(chunk.cues), "part \(chunk.i ?? -1)'s cues are in order and end at 1")
        }
        let storyV2 = try decode(FHStory.self, #"""
        {"slug":"the-farm","title":"The farm on Example Road","detail":"Under a minute","listen":true,
         "blocks":[{"type":"p","runs":[{"text":"We lived on an invented farm on Example Road"},{"text":"","source":1},{"text":". Grandpa Dan kept bees there. Every summer the family came back."}]},
          {"type":"h2","runs":[{"text":"Later"}]},
          {"type":"li","n":2,"runs":[{"text":"Then the family moved to an invented town."}]}],
         "sources":[{"n":1,"title":"Invented Census 1940","url":"https://example.com/records/c1-r1"}],
         "chunks":[{"i":0,"text":"We lived on an invented farm on Example Road. Grandpa Dan kept bees there.","audio":"/story/the-farm/audio/0",
                    "cues":[{"text":"We lived on an invented farm on Example Road.","start":0,"end":0.6},{"text":"Grandpa Dan kept bees there.","start":0.6,"end":1}]},
                   {"i":1,"text":"Every summer the family came back. Later. Then the family moved to an invented town.","audio":"/story/the-farm/audio/1",
                    "cues":[{"text":"Every summer the family came back.","start":0,"end":0.4},{"text":"Later.","start":0.4,"end":0.5},{"text":"Then the family moved to an invented town.","start":0.5,"end":1}]}]}
        """#)
        check(storyV2.blocks[0].plainText == "We lived on an invented farm on Example Road. Grandpa Dan kept bees there. Every summer the family came back.", "a block's words leave out its source chips")
        check(storyV2.blocks[2].n == 2 && storyV2.sources.first?.url != nil, "a list item's number and a source's link read")
        check(storyV2.chunks[1].audio == "/story/the-farm/audio/1", "a part names the route that voices it")
        check(FamilyGeometry.cueBlocks(chunks: storyV2.chunks, blocks: storyV2.blocks) == [[0, 0], [0, 1, 2]], "each sentence is found in its paragraph, in reading order")
        let twice = [FHBlock(type: "p", runs: [FHRun(text: "It rained.")]), FHBlock(type: "p", runs: [FHRun(text: "It rained.")])]
        let twiceParts = [FHChunk(i: 0, text: "", cues: [FHCue(text: "It rained.", start: 0, end: 0.5), FHCue(text: "It rained.", start: 0.5, end: 1)])]
        check(FamilyGeometry.cueBlocks(chunks: twiceParts, blocks: twice) == [[0, 1]], "a sentence said twice is found twice, in order")
        let lost = [FHChunk(i: 0, text: "", cues: [FHCue(text: "Not in the story.", start: 0, end: 1), FHCue(text: "...", start: 0, end: 1)])]
        check(FamilyGeometry.cueBlocks(chunks: lost, blocks: twice) == [[-1, -1]] && FamilyGeometry.cueBlocks(chunks: twiceParts, blocks: []) == [[-1, -1]], "a sentence that cannot be found is -1")
        let voiced = try decode(FHStoryAudio.self, #"{"slug":"the-farm","i":0,"count":2,"text":"Made up.","mime":"audio/wav","duration":"4.5","url":"https://example.com/a.wav","expires":"2026-09-29T13:00:00.000Z","cues":[{"text":"Made up.","start":0,"end":4.5}],"next":1}"#)
        check(voiced.duration == 4.5 && voiced.url != nil && voiced.next == 1 && voiced.cues.last?.end == 4.5, "a voiced part reads, with its cues in seconds")
        let lastPart = try decode(FHStoryAudio.self, #"{"i":1,"count":2,"url":null,"next":null}"#)
        check(lastPart.next == nil && lastPart.url == nil, "the last part has no next")
        let stretched = FamilyGeometry.cuesInSeconds([], fractions: [FHCue(text: "A.", start: 0, end: 0.25), FHCue(text: "B.", start: 0.25, end: 1)], duration: 8)
        check(stretched.map { $0.end } == [2, 8] && FamilyGeometry.cuesInSeconds(voiced.cues, fractions: stretched, duration: 99) == voiced.cues, "fraction cues stretch over the part; the server's seconds win")
        check(FamilyGeometry.sentenceKey("Later.") == "later" && FamilyGeometry.sentenceKey("Dan's 1954 farm!") == "dans1954farm", "a sentence's key is its letters and digits")

        let findings = try decode(FHFindings.self, FamilyDemoData.findings)
        check(findings.discoveries.count == 1 && findings.mysteries?.count == 1, "discoveries and the mysteries row read")
        let mysteries = try decode(FHFindings.self, FamilyDemoData.mysteries)
        check(mysteries.findings.first?.proof == "dna" && mysteries.headsUp != nil, "the mysteries read")
        let mysteriesV2 = try decode(FHFindings.self, #"{"title":"Family mysteries","headsUp":"This part may be news.","available":false,"findings":[]}"#)
        check(mysteriesV2.title == "Family mysteries" && mysteriesV2.available == false && mysteriesV2.findings.isEmpty, "switched-off mysteries say so")
        let proofWords = try decode(FHFinding.self, #"{"key":"f1","title":"Made up.","proof":"dna","proofText":"Strong DNA evidence","proofSpoken":"Research finding, strong DNA evidence, not proven by records","dna":true}"#)
        check(proofWords.proofSpoken?.hasPrefix("Research finding") == true && proofWords.dna == true, "a finding's spoken proof words read")

        let play = try decode(FHPlay.self, FamilyDemoData.play)
        check(play.rounds.count == 3 && play.rounds.allSatisfy { $0.playable }, "every game round is playable")
        let playV2 = try decode(FHPlay.self, #"{"seed":7,"rounds":[{"kind":"relation","prompt":"Who is Ned Example to you?","choices":[{"text":"your uncle"},{"text":"your grandfather"}],"answer":0,"explain":"He is your uncle.","right":"Right. He is your uncle.","wrong":"Not quite. He is your uncle."},{"kind":"year","prompt":"Guess this picture's decade.","choices":[{"text":"The 1950s"}],"answer":0},{"kind":"side","prompt":"Mom's side or Dad's side?","choices":[{"text":"Mom's side"},{"text":"Dad's side"}],"answer":5}],"score":"0 of 3"}"#)
        check(playV2.seed == 7 && playV2.rounds.filter { $0.playable }.count == 1, "a round with one choice or an answer out of range is not played")
        check(playV2.rounds[0].result(correct: true) == "Right. He is your uncle." && playV2.rounds[0].result(correct: false) == "Not quite. He is your uncle.", "the server says right and wrong")
        check(FHRound(explain: "She is your aunt.").result(correct: false) == "Not quite. She is your aunt." && FHRound().result(correct: true) == "Right.", "without the server's words, the explanation follows")
        check(FamilyPlayScore(right: 3, total: 5).words == "3 of 5" && FamilyPlayScore(stored: "3/5") == FamilyPlayScore(right: 3, total: 5), "a score reads and is kept")
        check(FamilyPlayScore(stored: "6/5") == nil && FamilyPlayScore(stored: "x") == nil && FamilyPlayScore(stored: nil) == nil, "a broken kept score is ignored")
        check(FamilyPlayScore(right: 4, total: 5).beats(FamilyPlayScore(right: 3, total: 5)) && !FamilyPlayScore(right: 3, total: 5).beats(FamilyPlayScore(right: 4, total: 5))
              && FamilyPlayScore(right: 1, total: 1).beats(nil) && FamilyPlayScore(right: 4, total: 4).beats(FamilyPlayScore(right: 2, total: 2))
              && !FamilyPlayScore(right: 0, total: 0).beats(nil), "the best score is the bigger share right")

        let people = try decode(FHPeople.self, FamilyDemoData.people)
        check(people.sections.count == 3 && people.total == 8, "everyone in the tree reads")
        let search = try decode(FHPeople.self, FamilyDemoData.search)
        check(search.people.count == 1 && search.spoken == "1 person found", "search results read")
        let searchV2 = try decode(FHPeople.self, #"{"query":"example","total":13,"text":"13 people found","spoken":"13 people found","people":[{"id":"@X1@","name":"Ada Example"}]}"#)
        check(searchV2.text == "13 people found" && searchV2.query == "example" && searchV2.total == 13, "a search says what was asked and how many were found")
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
        let hub = FHPoint(x: 100, y: 100)
        let up = FamilyGeometry.point(center: hub, radius: 50, degrees: 270)
        let left = FamilyGeometry.point(center: hub, radius: 50, degrees: 180)
        check(abs(up.x - 100) < 1e-9 && abs(up.y - 50) < 1e-9 && abs(left.x - 50) < 1e-9, "270 degrees is straight up, 180 is left")
        let outline = FamilyGeometry.wedgeOutline(center: hub, inner: 20, outer: 50, arc: FHArc(start: 180, end: 270), steps: 4)
        check(outline.count == 10 && outline.allSatisfy { $0.y <= 100 + 1e-9 }, "a wedge of the upper half stays above its centre")
        check(abs(outline[0].x - 50) < 1e-9 && abs(outline[4].y - 50) < 1e-9 && abs(outline[9].x - 80) < 1e-9, "a wedge runs out along the outer arc and back along the inner")
        check(FamilyGeometry.fanFaceSize(slots: 4) > FamilyGeometry.fanFaceSize(slots: 16)
              && FamilyGeometry.fanFaceSize(slots: 32) == 0, "faces shrink further out and stop past 16")
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
        check(FHOpen(to: "person", id: "@X1@", name: "Ada").route == .person(FamilyPersonRoute(id: "@X1@", name: "Ada")), "an open names its screen")
        check(FHOpen(to: "note", id: "@X1@").route == nil && FHOpen(to: "sky").route == nil, "the note sheet and unknown opens push nothing")
        check(!FamilyRoute.locked.needsAccess && routes.filter { $0 != .locked }.allSatisfy { $0.needsAccess }, "every family screen but the locked one needs access")
        check(FamilyRoute.person(FamilyPersonRoute(id: "@X1@", name: "Ada Example")).fallbackTitle == "Ada Example"
              && FamilyRoute.play.fallbackTitle == "Family history", "a pushed screen is titled at once")

        // MARK: Pictures name their sizes and their other copy.

        let sized = try decode(FHImage.self, #"{"id":"m1","category":"photo","sizes":["t","s","x",3],"restored":"m1r","showing":"original","text":"Made up."}"#)
        check(sized.sizes == ["t", "s", "x"] && sized.has(.s) && !sized.has(.l), "a picture lists its sizes, a bad one dropped")
        check(sized.best(.l) == .s && sized.best(.f) == .t && sized.best(.t) == .t, "a missing size falls back to the nearest one")
        check(!sized.isRestoredCopy && sized.otherCopy == "m1r" && sized.text == "Made up.", "an original names its restored copy")
        let restoredCopy = try decode(FHImage.self, #"{"id":"m1r","showing":"restored","original":"m1"}"#)
        check(restoredCopy.isRestoredCopy && restoredCopy.otherCopy == "m1", "a restored copy names its original")
        let faceRef = try decode(FHImage.self, #"{"id":"m2","face":"https://example.com/f.jpg","thumb":null,"alt":"Portrait: Ada Example","showing":"original"}"#)
        check(faceRef.sizes.isEmpty && faceRef.has(.f) && faceRef.face != nil && faceRef.label == "Portrait: Ada Example", "a person's face reads as a picture")
        check(faceRef.otherCopyImage() == nil, "a picture with no other copy has no switch")
        let labelled = try decode(FHImage.self, #"{"id":"m1","category":"photo","alt":"Photo: Ada Example.","restored":"m1r","sizes":["t"],"shareName":"Photo of Ada Example"}"#)
        let toRestored = labelled.otherCopyImage()
        check(toRestored?.id == "m1r" && toRestored?.isRestoredCopy == true && toRestored?.otherCopy == "m1", "the switch finds the restored copy")
        check(toRestored?.alt == "Photo: Ada Example. Restored with AI." && toRestored?.sizes.isEmpty == true && toRestored?.shareName == nil, "the restored copy says so, and is signed fresh")
        let backAgain = toRestored?.otherCopyImage()
        check(backAgain?.id == "m1" && backAgain?.isRestoredCopy == false && backAgain?.alt == "Photo: Ada Example.", "and back to the original")
        let demoRestored = try decode(FHImage.self, FamilyDemoData.photoDanRestored)
        check(demoRestored.otherCopyImage()?.id == "m-tree1" && demoRestored.otherCopyImage()?.isRestoredCopy == false, "a restored-kind copy switches to a plain original")
        let scanned = try decode(FHRecord.self, #"{"title":"An invented census","scan":{"id":"m9","category":"record"},"wrong":"another Ada","wrongText":"Attached to this person by mistake: another Ada"}"#)
        check(scanned.image?.id == "m9" && scanned.wrongWords == "Attached to this person by mistake: another Ada", "a record's scan and warning read under either name")
        let dup = try decode(FHDuplicate.self, #"{"mainId":"@X2@","text":"This is a second copy of Ada Example in the tree"}"#)
        check(dup.id == "@X2@", "a duplicate names its main entry")

        // MARK: Who may open it (GET /me), and what the Library row says.

        let meData = Data(FamilyDemoData.me.utf8)
        check(FamilyAccessRules.decide(status: 200, body: meData)?.isOpen == true, "the demo /me opens the family history")
        let v1open = Data(#"{"access":true,"viewer":{"personId":"@X1@"},"mode":"owner","isOwner":true,"version":"v1"}"#.utf8)
        check(FamilyAccessRules.decide(status: 200, body: v1open) == .unavailable, "a first-version /me does not open these screens")
        check(FamilyAccessRules.decide(status: 200, body: Data("<html>".utf8)) == .unavailable, "a page instead of an answer is not available yet")
        check(FamilyAccessRules.decide(status: 404, body: Data()) == .unavailable, "no route yet is not available yet")
        let trouble = [401, 429, 500, 502, 503].map { FamilyAccessRules.decide(status: $0, body: Data()) }
        check(trouble.allSatisfy { $0 == nil }, "trouble decides nothing, so the remembered row stays")

        let unmatchedBody = Data(#"{"access":false,"reason":"unmatched","error":"Private.","detail":"Not linked to the tree yet","hint":"Ask the tree's owner to match your account.","canAsk":true,"askedAt":null}"#.utf8)
        let unmatched = FamilyAccessRules.decide(status: 403, body: unmatchedBody)
        check(unmatched?.lock?.reasonKind == .unmatched, "a 403 locks with its reason")
        let unmatchedWords = FamilyAccessRules.rowWords(unmatched ?? .unknown)
        check(!unmatchedWords.enabled && unmatchedWords.detail == "Not linked to the tree yet" && unmatchedWords.ask == .ask, "an unmatched account sees the reason and Ask to be added")
        let askedBody = FamilyAccessRules.withAskedAt(unmatchedBody, askedAt: "2026-09-29T12:00:00.000Z")
        let askedWords = FamilyAccessRules.rowWords(FamilyAccessRules.decide(status: 403, body: askedBody) ?? .unknown)
        if case .asked(let when) = askedWords.ask {
            check(when.hasPrefix("Asked on ") && when.contains("2026"), "after asking, the row says when")
        } else {
            check(false, "after asking, the row says when")
        }
        let reviewBody = Data(#"{"access":false,"reason":"review","detail":"Private to one family","hint":"Photos, records and stories from one family's research.","canAsk":false}"#.utf8)
        let review = FamilyAccessRules.rowWords(FamilyAccessRules.decide(status: 403, body: reviewBody) ?? .unknown)
        check(review.detail == "Private to one family" && review.ask == .hidden && !review.hint.isEmpty && !review.enabled, "the review seat sees why, and no Ask")
        let v1refusal = FamilyAccessRules.rowWords(FamilyAccessRules.decide(status: 403, body: Data(#"{"access":false,"error":"The family history is private to the family."}"#.utf8)) ?? .unknown)
        check(v1refusal.detail == "Private to one family" && v1refusal.hint == "The family history is private to the family." && v1refusal.ask == .hidden, "a first-version refusal still says why")
        check(FamilyAccessRules.decide(status: 403, body: Data("oops".utf8))?.lock != nil, "an unreadable refusal is still a refusal")
        let familyWords = FamilyAccessRules.rowWords(FamilyAccessRules.decide(status: 200, body: meData) ?? .unknown)
        check(familyWords.enabled && familyWords.detail == "Ada's brother" && familyWords.ask == .hidden, "the family's row opens with the server's words")
        check(FamilyAccessRules.rowWords(.unknown) == FamilyRowWords(enabled: false, detail: "Checking", hint: "", ask: .hidden), "before an answer the row says Checking")
        check(FamilyAccessRules.rowWords(.unavailable).detail == "Not available yet", "no family history yet says so")
        check(!FamilyAccessRules.revokes(FHLocked(reason: "guest")) && FamilyAccessRules.revokes(FHLocked(reason: "unmatched"))
              && FamilyAccessRules.revokes(FHLocked()), "only a guest's closed game keeps access")

        let memo = FamilyAccessMemo(status: 403, body: unmatchedBody, at: 1)
        let memoBack = try JSONDecoder().decode(FamilyAccessMemo.self, from: JSONEncoder().encode(memo))
        check(memoBack == memo && FamilyAccessRules.decide(status: memoBack.status, body: memoBack.body) == unmatched, "a remembered answer decides the same way")

        let t0 = Date(timeIntervalSince1970: 1_000_000)
        check(FamilyRecheck.due(last: nil, now: t0, force: false), "the first check is due")
        check(!FamilyRecheck.due(last: t0, now: t0.addingTimeInterval(29), force: false)
              && FamilyRecheck.due(last: t0, now: t0.addingTimeInterval(30), force: false), "never twice in half a minute")
        check(FamilyRecheck.due(last: t0, now: t0.addingTimeInterval(1), force: true), "a pull asks anyway")
        check(FamilyDemoSwitch.isOn(arguments: ["app", "-KadeFamilyDemo"], environment: [:])
              && FamilyDemoSwitch.isOn(arguments: [], environment: ["KADE_FAMILY_DEMO": "1"]), "the demo switch")
        check(!FamilyDemoSwitch.isOn(arguments: ["app"], environment: ["KADE_FAMILY_DEMO": "0"]), "the demo is off unless asked for")

        // MARK: Failures keep the server's words.

        check(FamilyFailure.from(status: 204, body: Data()) == nil, "a 2xx is no failure")
        check(FamilyFailure.from(status: 404, body: Data(#"{"error":"Not built yet.","missing":"places"}"#.utf8)) == .missing("places"), "a part not built yet")
        check(FamilyFailure.from(status: 503, body: Data(#"{"error":"Updating."}"#.utf8))?.message == "Updating.", "the server's words come first")
        check(FamilyFailure.from(status: 500, body: Data("<html>".utf8)) == .server(500, nil) && !FamilyFailure.offline.message.isEmpty, "other trouble")
        if case .locked(let guestLock)? = FamilyFailure.from(status: 403, body: Data(#"{"reason":"guest","error":"For family members in the tree."}"#.utf8)) {
            check(!FamilyAccessRules.revokes(guestLock) && FamilyFailure.locked(guestLock).message == "For family members in the tree.", "a guest's closed game keeps access and says why")
        } else {
            check(false, "a 403 is a refusal")
        }
        check(FamilyDates.parse("2026-09-29T12:00:00.000Z") != nil && FamilyDates.parse("2026-09-29T12:00:00Z") != nil
              && FamilyDates.parse("soon") == nil && FamilyDates.askedOn(nil) == nil, "server dates read")

        // MARK: Caches, signed links and pages.

        check(!FamilyCacheNames.safe("../../etc").contains("/") && !FamilyCacheNames.safe("../../etc").contains(".")
              && FamilyCacheNames.safe("") == "_", "a cache name never leaves its folder")
        check(FamilyCacheNames.imageFile(mediaId: "a1b2", size: .s) == "a1b2.s.jpg"
              && FamilyCacheNames.memoryKey(userId: "u1", mediaId: "a1b2", size: .t, pixels: 132) == "u1/a1b2.t.132", "a picture is named by account, id and size")
        check(FamilyCacheNames.accessKey(userId: "u1") == "kade.family.access.u1", "access is remembered per account")
        let files = [
            FamilyCachedFile(name: "a.t.jpg", bytes: 100, used: t0),
            FamilyCachedFile(name: "b.t.jpg", bytes: 100, used: t0.addingTimeInterval(10)),
            FamilyCachedFile(name: "c.t.jpg", bytes: 100, used: t0.addingTimeInterval(5)),
        ]
        check(FamilyDiskTrim.victims(files, limit: 300).isEmpty, "a cache that fits keeps everything")
        check(FamilyDiskTrim.victims(files, limit: 150) == ["a.t.jpg", "c.t.jpg"], "the least recently used pictures go first")
        check(FamilyBatches.chunks(["a", "b", "a", "", "c"], size: 2) == [["a", "b"], ["c"]], "each picture is signed once, in batches")
        check(FamilyBatches.chunks(Array(repeating: "x", count: 5), size: 100) == [["x"]] && FamilyBatches.chunks([], size: 100).isEmpty, "batch edges")
        var lru = FamilyLRU<Int>(capacity: 2)
        lru.set("a", 1)
        lru.set("b", 2)
        _ = lru.get("a")
        lru.set("c", 3)
        let lruB = lru.get("b")
        let lruA = lru.get("a")
        let lruC = lru.get("c")
        check(lruB == nil && lruA == 1 && lruC == 3 && lru.count == 2, "the least recently used page goes first")
        check(FamilyPaging.window(total: 250, page: 1, size: 48) == 48..<96
              && FamilyPaging.spoken(48..<96, total: 250) == "Showing 49 to 96 of 250", "a page and its words")
        check(FamilyPaging.window(total: 250, page: 99, size: 48) == 240..<250 && FamilyPaging.pages(total: 250, size: 48) == 6, "the last page is clamped")
        check(FamilyPaging.window(total: 0, page: 0, size: 48).isEmpty && FamilyPaging.pages(total: 0, size: 48) == 1, "an empty list is one empty page")

        print("Family history: \(passed) checks passed. This checks decoding, routes, access rules and drawing maths, not SwiftUI or VoiceOver.")
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
