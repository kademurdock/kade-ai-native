import Foundation

/// The words the About screen, the Background tasks screen and the
/// conversation push speak. Pure Foundation: see run-soul-tests.sh.
@main struct SoulTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ label: String) {
            count += 1
            precondition(value, label)
        }
        func same(_ got: String?, _ want: String?, _ label: String) {
            count += 1
            precondition(got == want, "\(label): got \(got ?? "nil"), wanted \(want ?? "nil")")
        }

        // Mood: written about "them", spoken to "you".
        same(KadeSoulWords.moodSentence(name: "Kiana", words: "still a little heavy from last time with them"),
             "Kiana is still a little heavy from last time with you.", "Mood speaks to you")
        same(KadeSoulWords.moodSentence(name: "Harley", words: "in an easy, good place with them."),
             "Harley is in an easy, good place with you.", "Mood keeps one period")
        same(KadeSoulWords.moodSentence(name: "Della", words: "quieter than usual coming in"),
             "Della is quieter than usual coming in.", "Mood without them")
        same(KadeSoulWords.moodSentence(name: "Lilly", words: nil), "Lilly is coming in settled.", "No mood")
        same(KadeSoulWords.moodSentence(name: "Lilly", words: "   "), "Lilly is coming in settled.", "Blank mood")
        same(KadeSoulWords.moodSentence(name: " ", words: nil), "This character is coming in settled.", "No name")
        check(!KadeSoulWords.moodSentence(name: "Angel", words: "glad to be with themselves").contains("with you"),
              "Only the whole words 'with them' change")

        // Moments: one sentence each.
        same(KadeSoulWords.momentKindWords("nickname"), "A nickname", "nickname")
        same(KadeSoulWords.momentKindWords("joke"), "A running joke", "joke")
        same(KadeSoulWords.momentKindWords("first"), "A first", "first")
        same(KadeSoulWords.momentKindWords("milestone"), "A milestone", "milestone")
        same(KadeSoulWords.momentKindWords("line"), "A line that stuck", "line")
        same(KadeSoulWords.momentKindWords("other"), "A moment", "unknown kind")
        same(KadeSoulWords.momentSpeakerWords("them", name: "Kiana"), "You said", "them is you")
        same(KadeSoulWords.momentSpeakerWords("me", name: "Kiana"), "Kiana said", "me is the character")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        func at(_ iso: String) -> Date { KadeSoulWords.parseDate(iso)! }
        // Friday Oct 16 2026, 8 pm in Springfield (01:00 UTC the next day).
        let now = at("2026-10-17T01:00:00.000Z")

        let moment = KadeSoulMoment(id: "6710a0c2f1d2e3a4b5c6d7e8", quote: "goblin of chaos", speaker: "them",
                                    kind: "nickname", why: "what you call me", createdAt: "2026-10-03T17:00:00.000Z")
        same(KadeSoulWords.momentSpoken(moment, name: "Kiana", now: now, calendar: calendar),
             "You said: \"goblin of chaos\". A nickname: what you call me. October 3.", "Moment sentence")
        let older = KadeSoulMoment(id: "x", quote: "we made it", speaker: "me", kind: "milestone",
                                   createdAt: "2025-12-31T18:00:00Z")
        same(KadeSoulWords.momentSpoken(older, name: "Harley", now: now, calendar: calendar),
             "Harley said: \"we made it\". A milestone. December 31, 2025.", "Older moment, no reason")

        // Last time you talked.
        same(KadeSoulWords.lastTalkedWords(at("2026-10-17T00:59:30Z"), now: now, calendar: calendar), "Just now", "seconds")
        same(KadeSoulWords.lastTalkedWords(at("2026-10-17T00:59:00Z"), now: now, calendar: calendar), "A minute ago", "one minute")
        same(KadeSoulWords.lastTalkedWords(at("2026-10-17T00:40:00Z"), now: now, calendar: calendar), "20 minutes ago", "minutes")
        same(KadeSoulWords.lastTalkedWords(at("2026-10-16T22:00:00Z"), now: now, calendar: calendar), "3 hours ago", "hours")
        same(KadeSoulWords.lastTalkedWords(at("2026-10-16T14:00:00Z"), now: now, calendar: calendar), "This morning", "this morning")
        same(KadeSoulWords.lastTalkedWords(at("2026-10-15T23:30:00Z"), now: now, calendar: calendar), "Yesterday evening", "yesterday evening")
        same(KadeSoulWords.lastTalkedWords(at("2026-10-16T03:30:00Z"), now: now, calendar: calendar), "Last night", "last night")
        same(KadeSoulWords.lastTalkedWords(at("2026-10-13T19:00:00Z"), now: now, calendar: calendar), "Tuesday afternoon", "weekday")
        same(KadeSoulWords.lastTalkedWords(at("2026-10-07T19:00:00Z"), now: now, calendar: calendar), "9 days ago", "days")
        same(KadeSoulWords.lastTalkedWords(at("2026-08-01T19:00:00Z"), now: now, calendar: calendar), "On August 1", "long ago")
        same(KadeSoulWords.lastTalkedWords(at("2026-10-17T02:00:00Z"), now: now, calendar: calendar), "Just now", "clock skew")
        same(KadeSoulWords.lastTalkedSentence(nil, now: now, calendar: calendar), "You haven't talked yet.", "never")
        same(KadeSoulWords.lastTalkedSentence("2026-10-16T21:59:00.123Z", now: now, calendar: calendar), "3 hours ago.", "sentence")
        same(KadeSoulWords.lastTalkedSentence("not a date", now: now, calendar: calendar), "You haven't talked yet.", "bad date")

        // The character's days.
        same(KadeSoulWords.dayHeading("2026-10-16", now: now, calendar: calendar), "Friday, October 16", "day heading")
        same(KadeSoulWords.dayHeading("2025-10-16", now: now, calendar: calendar), "Thursday, October 16, 2025", "last year")
        same(KadeSoulWords.dayHeading("2026-02-30", now: now, calendar: calendar), nil, "not a real day")
        same(KadeSoulWords.dayHeading("yesterday", now: now, calendar: calendar), nil, "not a date")

        // Background tasks.
        same(KadeSoulWords.taskStatusWords("running"), "Working on it", "running")
        same(KadeSoulWords.taskStatusWords("done"), "Done", "done")
        same(KadeSoulWords.taskStatusWords("failed"), "Couldn't finish", "failed")
        same(KadeSoulWords.taskStatusWords("cancelled"), "Stopped", "cancelled")
        same(KadeSoulWords.taskStatusWords("cancelled-late"), "Stopped", "cancelled late")
        same(KadeSoulWords.taskStatusWords("cancel-requested"), "Stopping", "stopping")
        same(KadeSoulWords.taskStatusWords("interrupted"), "Interrupted by a restart", "interrupted")
        same(KadeSoulWords.taskStatusWords("new-thing"), "Status unknown", "unknown status")

        same(KadeSoulWords.costWords(chargedUSD: 0.03, quotedMostUSD: 0.12), "Cost about 3 cents", "charged wins")
        same(KadeSoulWords.costWords(chargedUSD: nil, quotedMostUSD: 0.12), "Up to about 12 cents", "quote")
        same(KadeSoulWords.costWords(chargedUSD: 0.004, quotedMostUSD: nil), "Cost under a cent", "under a cent")
        same(KadeSoulWords.costWords(chargedUSD: 0, quotedMostUSD: 0.5), "Cost nothing", "nothing")
        same(KadeSoulWords.costWords(chargedUSD: nil, quotedMostUSD: 0.002), "Under a cent at most", "tiny quote")
        same(KadeSoulWords.costWords(chargedUSD: 0.01, quotedMostUSD: nil), "Cost about 1 cent", "one cent")
        same(KadeSoulWords.costWords(chargedUSD: 1.25, quotedMostUSD: nil), "Cost about $1.25", "dollars")
        same(KadeSoulWords.costWords(chargedUSD: 2.0, quotedMostUSD: nil), "Cost about 2 dollars", "whole dollars")
        same(KadeSoulWords.costWords(chargedUSD: 1.05, quotedMostUSD: nil), "Cost about $1.05", "padded cents")
        same(KadeSoulWords.costWords(chargedUSD: nil, quotedMostUSD: nil), nil, "no cost known")

        let done = KadeBackgroundTask(taskId: "t1", agentName: "Kiana", title: "Find a pie recipe", status: "done",
                                      conversationId: "0f8fad5b-d9cb-469f-a165-70867728950e",
                                      preview: "Found three. The buttermilk one wins.", chargedUSD: 0.03)
        same(KadeSoulWords.taskSpoken(done),
             "Find a pie recipe. Kiana. Done. Found three. The buttermilk one wins. Cost about 3 cents.", "done task")
        let failed = KadeBackgroundTask(taskId: "t2", agentName: "Harley", title: "Check the weather", status: "failed",
                                        error: "the weather service was down", quotedMostUSD: 0.12)
        same(KadeSoulWords.taskSpoken(failed),
             "Check the weather. Harley. Couldn't finish. The weather service was down. Up to about 12 cents.", "failed task")
        check(done.openableConversationId == "0f8fad5b-d9cb-469f-a165-70867728950e", "A real conversation can be opened")
        check(failed.openableConversationId == nil, "No conversation, no Open")
        same(KadeSoulWords.taskListSummary([]), "No background tasks yet.", "empty list")
        same(KadeSoulWords.taskListSummary([done, failed]), "2 tasks shown, none running.", "none running")
        let running = KadeBackgroundTask(taskId: "t3", title: "Read the news", status: "running")
        same(KadeSoulWords.taskListSummary([running]), "1 task shown, 1 running.", "one running")
        same(KadeSoulWords.taskLinkLabel(running: nil), "Background tasks", "link before loading")
        same(KadeSoulWords.taskLinkLabel(running: 0), "Background tasks, none running", "link none")
        same(KadeSoulWords.taskLinkLabel(running: 2), "Background tasks, 2 running", "link two")
        same(KadeSoulWords.stopRefusedWords("it is already done"), "Couldn't stop it: it is already done.", "409 words")
        same(KadeSoulWords.stopRefusedWords(nil), "Couldn't stop it. Try Refresh to see where it is.", "409 without words")

        // The conversation push.
        let uuid = "0f8fad5b-d9cb-469f-a165-70867728950e"
        same(KadeConversationRoute.conversationId(from: uuid), uuid, "A real conversation id")
        same(KadeConversationRoute.conversationId(from: uuid.uppercased()), uuid.uppercased(), "Upper case hex")
        let refused: [Any?] = [nil, "", "new", 42, [uuid], " " + uuid, uuid + " ", uuid + "/messages",
                               "0f8fad5b-d9cb-469f-a165-70867728950", "0f8fad5bxd9cb-469f-a165-70867728950e",
                               "0f8fad5b-d9cb-469f-a165-70867728950g", "../../api/convos"]
        for value in refused {
            check(KadeConversationRoute.conversationId(from: value) == nil, "Refuses \(String(describing: value))")
        }
        same(KadeConversationRoute.routeName, "conversation", "Route name the bridge sends")
        check(KadeSoulWords.isCharacterId("agent_NkG_Fb8_xLz8HFJyx4gNv"), "A real character id")
        check(!KadeSoulWords.isCharacterId("agent_"), "Too short")
        check(!KadeSoulWords.isCharacterId("../agent_NkG_Fb8_xLz8HFJyx4gNv"), "Path tricks refused")

        // Wire shapes, leniently.
        let soulJSON = """
        {"mood":{"words":"still warm and glad from last time with them","lastMostly":["joy","pride"]},
         "lastTalkedAt":"2026-10-16T22:00:00.000Z",
         "moments":[{"id":"a1","quote":"goblin of chaos","speaker":"them","kind":"nickname","why":"what you call me","createdAt":"2026-10-03T17:00:00.000Z"},
                    {"id":"a2","quote":"","speaker":"me","kind":"line"},
                    {"quote":"no id"},
                    {"id":"a3","quote":"to the moon","speaker":"me","kind":"joke","why":null,"createdAt":null}],
         "days":[{"day":"2026-10-16","text":"Rain on the square today.","following":"the county fair","home":"Springfield, Missouri"},
                 {"day":"2026-10-15","text":""}, 7]}
        """
        let snapshot = try JSONDecoder().decode(KadeSoulSnapshot.self, from: Data(soulJSON.utf8))
        same(snapshot.mood?.words, "still warm and glad from last time with them", "mood words decode")
        check(snapshot.moments.map(\.id) == ["a1", "a3"], "Empty and id-less moments are dropped")
        same(snapshot.moments.last?.why, "", "null reason is empty")
        check(snapshot.days.count == 1 && snapshot.days[0].following == "the county fair", "Days decode, blanks dropped")
        let quiet = try JSONDecoder().decode(KadeSoulSnapshot.self, from: Data("{\"mood\":null,\"lastTalkedAt\":null}".utf8))
        check(quiet.mood == nil && quiet.lastTalkedAt == nil && quiet.moments.isEmpty && quiet.days.isEmpty,
              "A first visit decodes to empty")

        let tasksJSON = """
        {"tasks":[{"taskId":"k1","agentId":"agent_NkG_Fb8_xLz8HFJyx4gNv","agentName":"Kiana","title":"Find a pie recipe",
                   "status":"done","createdAt":"2026-10-16T20:00:00.000Z","finishedAt":"2026-10-16T20:04:00.000Z",
                   "conversationId":"0f8fad5b-d9cb-469f-a165-70867728950e","preview":"Found three.","error":"",
                   "quotedMostUSD":0.12,"chargedUSD":0.03},
                  {"taskId":"k2","agentName":"Harley","title":"Weather","status":"running","finishedAt":null,
                   "conversationId":null,"preview":"","error":"","quotedMostUSD":0.2,"chargedUSD":null},
                  {"status":"done"}]}
        """
        let list = try JSONDecoder().decode(KadeBackgroundTaskList.self, from: Data(tasksJSON.utf8))
        check(list.tasks.map(\.taskId) == ["k1", "k2"], "Tasks decode; an id-less row is dropped")
        check(list.tasks[0].chargedUSD == 0.03 && list.tasks[1].chargedUSD == nil, "Charged decodes, null stays unknown")
        check(list.tasks[1].conversationId == nil && list.tasks[1].isRunning, "Running task without a conversation")

        print("Synthetic soul words: \(count) checks passed")
    }
}
