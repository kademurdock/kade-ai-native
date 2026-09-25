import SwiftUI

/// In-app help. Kade's standing priority has been "iPhone/Android stuff and
/// help stuff" for many sessions; the help that existed lived on the web
/// (`Kade-AI Help Manual.txt` and the site's own pages), which meant the
/// answer to "how does this work" was always somewhere outside the app.
///
/// Written to be READ ALOUD, not skimmed:
/// - Every section is a real VoiceOver heading, so the rotor's Headings
///   setting turns this into a table of contents you can jump around in
///   with one flick, rather than a wall you have to swipe through.
/// - Each entry is ONE accessibility element containing its title and its
///   explanation, so a single swipe gets the whole answer instead of
///   landing on a title and making you swipe again to find out what it
///   means.
/// - No screenshots, no "tap the icon in the corner" — every instruction
///   names the control by the exact words VoiceOver will speak for it, so
///   the instruction and the thing it describes match by ear.
struct HelpView: View {
    /// Session 23: nil when Help is opened signed-out (ContentView's
    /// pre-sign-in block) -- the Report a problem button only renders with
    /// a real client, since filing requires being signed in. Default nil
    /// keeps every existing `HelpView()` call site compiling untouched.
    var apiClient: KadeAPIClient? = nil
    @State private var showingReport = false
    @Environment(\.kadeNavigation) private var nav
    /// Sep 24 2026: the described-video help shows only for an account the
    /// server lets in (the owner trial).
    @ObservedObject private var describedVideo = DescribedVideoAccess.shared

    private var places: [HelpPlace] {
        HelpPlace.all.filter { !$0.ownerTrial || describedVideo.allowed }
    }

    private var sections: [HelpSection] {
        HelpSection.all.filter { !$0.ownerTrial || describedVideo.allowed }
    }

    private func entries(_ section: HelpSection) -> [HelpEntry] {
        section.entries.filter { !$0.ownerTrial || describedVideo.allowed }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Everything Kade-AI can do, and how to get to it. With VoiceOver, turn on the Headings rotor to jump between sections; without it, just scroll.")
                    .font(.body)

                /* Sep 23 2026 redesign (A4): "Where is…?" first, because
                 * "where did that go" is the question people actually open
                 * Help with. Each answer is a button that takes you there.
                 * Signed out there is nowhere to go yet, so it waits. */
                if apiClient != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Where is…?")
                            .font(.title3.bold())
                            .accessibilityAddTraits(.isHeader)
                        ForEach(places) { place in
                            Button {
                                nav.open(place.route)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.thing)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(place.whereItIs)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(place.thing): \(place.whereItIs)")
                            .accessibilityHint("Takes you there.")
                        }
                    }
                }

                // Session 23: the tester loop, closed -- Amber's first-day
                // bugs traveled by mouth; now any tester can file from the
                // exact place they go when something's wrong.
                if apiClient != nil {
                    Button {
                        showingReport = true
                    } label: {
                        Label("Report a problem or share an idea", systemImage: "exclamationmark.bubble")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Opens a short form that goes straight to Kade with your name on it.")
                }

                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 14) {
                        Text(section.title)
                            .font(.title3.bold())
                            .accessibilityAddTraits(.isHeader)

                        ForEach(entries(section)) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.title)
                                    .font(.headline)
                                Text(entry.body)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // One swipe, one whole answer. `.ignore` plus an
                            // explicit label rather than `.combine`, which
                            // this app avoids everywhere on principle after
                            // it caused real narration bugs twice.
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(entry.title). \(entry.body)")
                        }
                    }
                }

                Text("Still stuck? Search everything on the More tab finds any place in the app by the word you'd use. Or just ask any character — they know how the app works.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Help")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingReport) {
            if let apiClient {
                FeedbackReportView(apiClient: apiClient)
            }
        }
    }
}

/// One answer in Help's "Where is…?" list (redesign A4): the thing people are
/// looking for, where it lives now, and the route that takes them there.
struct HelpPlace: Identifiable {
    let thing: String
    let whereItIs: String
    let route: HomeRoute
    var id: String { thing }

    /// Make a described video: listed only for an account the server lets in.
    var ownerTrial: Bool {
        if case .describedVideo = route { return true }
        return false
    }

    static let all: [HelpPlace] = [
        HelpPlace(thing: "Your conversations", whereItIs: "Talk tab, under Call your Spotter", route: .conversations),
        HelpPlace(thing: "Your books, tapes and radio", whereItIs: "Library tab", route: .readingRoom),
        HelpPlace(thing: "Making a song or a scene", whereItIs: "Create tab, Sound Booth", route: .soundBooth),
        HelpPlace(thing: "Making a described video", whereItIs: "Create tab, Described video", route: .describedVideo(DescribedVideoStart())),
        HelpPlace(thing: "Things you've made", whereItIs: "Create tab, My Creations", route: .myCreations),
        HelpPlace(thing: "Games", whereItIs: "Play tab, The Parlor", route: .parlor),
        HelpPlace(thing: "Family voice rooms", whereItIs: "Play tab, Kade's Clubhouse", route: .lounge),
        HelpPlace(thing: "Meeting new characters", whereItIs: "Play tab, Marketplace", route: .marketplace),
        HelpPlace(thing: "Reminders", whereItIs: "More tab, Alerts", route: .alerts),
        HelpPlace(thing: "News from Kade", whereItIs: "More tab, Announcements", route: .announcements),
        HelpPlace(thing: "Ringtone, voice speed, your main character, app icon", whereItIs: "More tab, Settings", route: .settings),
        HelpPlace(thing: "Anything else", whereItIs: "More tab, Search everything", route: .search),
    ]
}

struct HelpEntry: Identifiable {
    let title: String
    let body: String
    /// Shown when this account can open the describer, including adult review accounts.
    var ownerTrial = false
    var id: String { title }
}

struct HelpSection: Identifiable {
    let title: String
    let entries: [HelpEntry]
    var ownerTrial = false
    var id: String { title }

    static let all: [HelpSection] = [
        // Session 18 (Kade's pick): a spoken changelog. Each build batch gets
        // a plain-language entry here -- newest first, what changed and what
        // to try -- so she hears it in-app instead of digging through chat
        // history. KEEP THIS CURRENT: every future batch should rewrite the
        // newest entry before the build fires, and collapse older ones. The
        // one-time card on the Talk tab (KadeWhatsNew.swift) says the same
        // thing in two sentences.
        HelpSection(title: "What's new", entries: [
            HelpEntry(
                title: "Newest build: Library actions and requests",
                body: "In the Library, what you can do with an item is in the VoiceOver Actions rotor as you pass it: Ask the librarian about this, Make a described copy on videos, Add to a collection, and for your own uploads Move or Delete. Swipe up or down on the item to hear them; a long press shows the same list. In the player those buttons moved into the rotor on the title and on Play, with What just happened? for videos, so there are fewer stops before Play. New under Add: ask the library for a book, recording or video, even if you only remember a little, and hear when it's filled. A YouTube link you copied fills in the described video link box by itself, and any link fills the Library's submit box. And a book that is already in the library with exactly the same text is no longer added twice."
            ),
            HelpEntry(
                title: "Before that: an easier layout",
                body: "Everything now lives in five tabs along the bottom of the screen: Talk, Library, Create, Play and More. Each tab keeps your place, so going to Talk and back to Library lands you right where you were, and tapping the tab you're already on takes you back to its start. The app still opens into a chat with your main character, Call your Spotter is still the first button on the Talk tab, and backing out of a chat still lands on your conversations, now grouped by day with each character's face beside them. Your book keeps playing while you move around the app, with a small Now Playing bar above the tabs, and it pauses by itself for a voice message or a call. New too: Search everything, a Where is list at the top of Help, little new badges on Alerts and Announcements, a friendlier first chat with starter lines, a Sound Booth that asks what you want to make, and in Settings, your pick of app icon: Kiana, Harley, Della or Lilly's face."
            ),
            HelpEntry(
                title: "New for you: Make a described video",
                body: "On the Create tab, and on videos you can access in the Library as Make a described copy. Choose a video from Files, Photos, a YouTube link or the Library, pick the narrator and how much to describe, hear the price, then try a preview or describe the whole thing. Watch it here, read it as a described transcript, save it to Files, or put it in the Library. It keeps playing when you leave the app or lock the phone, and with VoiceOver on the captions stay on screen without being read over the film. Adult accounts can use it. Narration is included; metered analysis uses your balance after you approve the maximum charge.",
                ownerTrial: true
            ),
            HelpEntry(
                title: "Recently",
                body: "The four main characters got real faces that move while they talk, at the top of every conversation. The Library arrived: books read aloud by a voice you pick, plus the family archive of tapes, radio, commercials and described videos. The Sound Booth writes and sings whole songs, scenes with several voices, and sound effects. Kade Keys learned to take dictation, and debate rooms can throw parties with a four-character code."
            ),
            HelpEntry(
                title: "Earlier",
                body: "Kade's Clubhouse went fully native, with hidden passcode-only Hotel rooms, and the Game Room folded into the Parlor. Native party tables in the Parlor. Bass haptics with a heartbeat thinking pulse and bubble sounds. Report a problem from Help or the More tab. Agent Builder with voices, starters, tools, photos, duplicating, and version history. Usage and Balance in Settings. Describe for photos, videos, and documents. Stop a reply mid-write. Matchmaker, Debate Room and the Conversation Hall went native. The Pronunciation Dictionary. Quick Dictate. Transcribe with file import. Calls with auto-reconnect and Siri phrases."
            ),
        ]),
        HelpSection(title: "Getting around", entries: [
            HelpEntry(
                title: "The five tabs",
                body: "The bar along the bottom has five tabs. Talk holds Call your Spotter, Talk to your main character, Describe, Transcribe, and all your conversations. Library holds books read aloud, tapes, radio and the family archive. Create holds the Sound Booth, My Creations, the Wall of Fame, Agent Builder and the Prompt Library. Play holds The Parlor's games, Kade's Clubhouse, the Debate Room, the Matchmaker and the Marketplace. More holds search, Alerts, Announcements, Agent work, Bookmarks, Settings, this help, a way to tell Kade how it's going, the web app, and Sign out. With VoiceOver each one reads as, for example, Library, tab, 2 of 5. The bar hides inside a conversation, where the message box needs the room."
            ),
            HelpEntry(
                title: "Search everything",
                body: "Search everything is the magnifying glass at the top of Talk, Library, Create and Play, and the second row on More. Type the word you'd use yourself: ringtone finds Settings, games finds The Parlor, a name like Harley starts a chat with him, and a book title searches the Library. Results come in groups, each with its own heading."
            ),
            HelpEntry(
                title: "Your conversations",
                body: "Every chat you've had, newest first and grouped by day: Pinned, Today, Yesterday, This week, This month and Earlier, each a heading you can jump between. Each row shows who the chat is with. Double-tap a conversation to open it, or just tap it without VoiceOver. There's a search field above the list that filters what's loaded, and the archive box button up top holds everything you've archived, restorable any time."
            ),
            HelpEntry(
                title: "Bookmarks",
                body: "Bookmarks are tags for conversations. With VoiceOver, focus any conversation row, flick down through the Actions rotor to Bookmark, and check off the tags you want on it, or type a brand-new one right there. Without VoiceOver, swipe the row to the left and tap Bookmark. Bookmarks on the More tab lists every tag with a count, and opening a tag shows exactly the conversations carrying it. Deleting a bookmark never touches the conversations themselves."
            ),
            HelpEntry(
                title: "The Prompt Library",
                body: "Prompts, on the Create tab, holds saved prompts, yours and any shared with you. Open one to hear the whole text, then Use in a new chat: you land in a fresh conversation with the prompt already typed into the message box, ready to send as-is or edit first. Save a new prompt lives at the bottom of the library list; name and text are all it needs."
            ),
            HelpEntry(
                title: "Actions on a conversation",
                body: "With VoiceOver, focus a conversation row and flick down through the Actions rotor for Pin, Rename, Archive, Delete, Share and Bookmark. Without VoiceOver, swipe the row sideways for the same things: right to pin, left for the rest. Archive tucks a chat away without deleting it; find it again under the archive box button, where Restore brings it home."
            ),
            HelpEntry(
                title: "Starting a new chat",
                body: "Talk to your main character, near the top of the Talk tab, starts a fresh conversation with them; the pencil button in the conversation list does the same. A new chat says hello with a few starter lines: tap one to put it in the message box, change it if you like, then send. If you'd rather carry on from before, Pick up where you left off opens your last conversation with that character."
            ),
        ]),
        HelpSection(title: "Chatting", entries: [
            HelpEntry(
                title: "Sending a message",
                body: "Type in the box at the bottom and activate Send. If a send fails you'll get a Retry button that resends exactly what you wrote, so you don't have to type it again."
            ),
            HelpEntry(
                title: "Talking instead of typing",
                body: "The microphone button next to the message box records what you say, turns it into text, and drops it into the box so you can check it before sending."
            ),
            HelpEntry(
                title: "Thinking: Auto, Deep or Fast",
                body: "The brain button beside the message box says how hard your character thinks. Auto decides per question, Deep always takes its time for careful answers, and Fast always answers quickly. It stays how you set it until you change it."
            ),
            HelpEntry(
                title: "Actions on a message",
                body: "With VoiceOver, focus any message and flick down through the Actions rotor: Copy Text, Play as Voice Message, Share Text, Save Voice Message, and, on the most recent turn only, Edit and Resend, Regenerate Reply, and Delete Message. Without VoiceOver, the Message actions button, the circle with three dots under each message, opens the same list."
            ),
            HelpEntry(
                title: "Why Edit and Delete only work on the newest messages",
                body: "The app shows your conversation as one straight line in the order it happened. Editing or deleting something from the middle would leave an answer to a question that no longer exists, so those actions are deliberately limited to the latest turn."
            ),
            HelpEntry(
                title: "Switching characters",
                body: "The Talking to row just above the message box opens the character picker, and so does tapping the face at the top of the conversation. The picker lands you in a search field with the keyboard up: start typing a name, or put the keyboard away to browse the characters with moving faces, your favorites, and the sections underneath."
            ),
        ]),
        HelpSection(title: "Hearing replies", entries: [
            HelpEntry(
                title: "Hearing replies out loud",
                body: "Turn Hear replies on in a conversation and every reply is spoken in that character's own voice as it arrives. It's a switch; VoiceOver reads it as On or Off. Settings, Hear replies by default, turns it on for every new chat."
            ),
            HelpEntry(
                title: "Voice speed",
                body: "The speed button beside Hear replies runs from 0.75 up to 2 times. It takes effect straight away, even in the middle of a clip, and it's remembered next time."
            ),
            HelpEntry(
                title: "Saving one",
                body: "Save Voice Message in a message's actions opens the share sheet, where Save to Files, AirDrop, Messages and Mail all live. The file is named after who said it and when."
            ),
        ]),
        HelpSection(title: "Calling", entries: [
            HelpEntry(
                title: "Starting a call",
                body: "The call button at the top of any conversation starts a real-time voice call with that character. Just talk; there's no button to hold."
            ),
            HelpEntry(
                title: "Interrupting",
                body: "Just start talking over her and she stops, the same way the phone line has always worked. She tries to ignore the room and only stops for an actual word, so a TV or your screen reader shouldn't set her off. Stop Talking is still there for the times you'd rather not make a sound, and it's the only thing that works while your microphone is muted, since a muted mic gives her nothing to hear."
            ),
            HelpEntry(
                title: "Deep Think, mid-conversation",
                body: "Deep Think on the call screen is for when you ask something you'd rather she took her time on. Activate it, ask your question, and she thinks it through instead of answering straight off. It turns itself off after that one answer, so the rest of the call stays quick, and you can say \"deep think on\" out loud instead if your hands are busy."
            ),
            HelpEntry(
                title: "Your Spotter",
                body: "Call your Spotter, the first button on the Talk tab, starts a call with your live visual helper, who sees through your camera and describes what's in front of you. On a call with anyone else, Bring in your Spotter hands the call over. The status line and captions change to her name so you always know who's talking."
            ),
            HelpEntry(
                title: "Letting the character you're already talking to see",
                body: "Let her see your camera is different from Spotter: the same voice you're already talking to gains sight and works what she sees into her own replies, instead of handing the call to someone else."
            ),
            HelpEntry(
                title: "The flashlight",
                body: "In a dark room the flashlight comes on by itself so the camera has something to work with, and announces that it did. Touch the flashlight button once and it stops deciding for you for the rest of that call."
            ),
            HelpEntry(
                title: "If a call drops",
                body: "You'll hear \"the call dropped, reconnecting\" and the app puts it back together on its own, camera and Spotter included. Long Spotter calls hit a limit roughly every ten minutes on the video service's side, and this is what carries you across it."
            ),
            HelpEntry(
                title: "Audio check",
                body: "The call screen has a line reporting where the sound is going, the volume, and how many clips have arrived and played. If a call ever has no sound, read that line out; it says which part failed."
            ),
            HelpEntry(
                title: "The lock screen",
                body: "A call keeps running when the screen locks and shows up on the lock screen and in Control Centre. Stop ends the call; play and pause interrupt her, the same as Stop Talking."
            ),
            HelpEntry(
                title: "After you hang up",
                body: "Every call is written up as a normal conversation you can read and carry on in text. Hanging up waits a moment and opens it for you, and there's a Skip button if you'd rather not wait. That written-up call opens over your original conversation; there's a Close button, top left, to get back to it."
            ),
        ]),
        HelpSection(title: "The Library", entries: [
            HelpEntry(
                title: "Three parts",
                body: "The Library tab is split three ways by a switch near the top. Listen holds what you're reading or hearing now, your shelf and your collections. Browse holds search, the archive's folders and loose donations. Add holds every way to donate a book or a recording. Continue, at the very top, picks up the book you were last in."
            ),
            HelpEntry(
                title: "Actions on every item",
                body: "Every item in the Library has its actions in the VoiceOver Actions rotor: Ask the librarian about this, Make a described copy on videos, Add to a collection, and on your own uploads Move to another folder or Delete, which asks first. You don't have to open an item to ask about it. In the player, the same actions are on the title and on Play, plus What just happened? on a video, which pauses and describes the last few minutes. Without VoiceOver the buttons are on screen, and a long press on an item shows the list."
            ),
            HelpEntry(
                title: "Asking for something",
                body: "Under Add, Ask the library for something takes a title or a few words, the kind of thing it is, and whatever you remember. The library owner sees every request, and you get an alert when yours is filled; then it says so at the top of the Library, and Open plays it. Each request's actions are Hear the details, Add details and Cancel this request. You can also just tell the librarian."
            ),
            HelpEntry(
                title: "It keeps playing",
                body: "A book or recording keeps playing while you use the rest of the app. A small Now Playing bar sits above the tabs with the title, Play or Pause, and Stop and close; tap the title to go back to the full player. A voice message or a call pauses the book by itself, and the bar then offers Resume. The lock screen and your headphone buttons keep working the whole time."
            ),
        ]),
        HelpSection(title: "Transcribe", entries: [
            HelpEntry(
                title: "What it's for",
                body: "Recording a thought, or a long voice memo somebody sent you, and getting it back as text you can edit and keep. It's on the Talk tab."
            ),
            HelpEntry(
                title: "Recording in takes",
                body: "Start recording, say your piece, stop. The text lands in the transcript. Record again and the next take is added on the end, so you can think in pieces without losing anything."
            ),
            HelpEntry(
                title: "Importing a file",
                body: "Import audio file picks a recording someone sent you from Files, iCloud Drive, or another app (a voice memo, a video's audio, up to about two hours long) and adds its words to the transcript the same way a recorded take does."
            ),
            HelpEntry(
                title: "Quick Dictate",
                body: "Reachable by Siri (\"quick dictate with Kade-AI\"), a Home Screen Quick Action, or an Action Button: it lands you here already listening. Tap Stop when you're done and the clean text is on your clipboard immediately, ready to paste into whatever you were doing."
            ),
            HelpEntry(
                title: "Tidying it up",
                body: "Organize into notes gives you a title and bullet points. Clean up text keeps every word and just fixes the grammar, the filler words and the paragraphs. Undo puts back the version from before."
            ),
            HelpEntry(
                title: "Getting it out",
                body: "Copy transcript puts it on the clipboard. Share transcript opens the share sheet, including Save to Files."
            ),
        ]),
        HelpSection(title: "Describe", entries: [
            HelpEntry(
                title: "What it's for",
                body: "Getting a photo, video, flyer, letter, screenshot, or document described to you, or read back word for word: a menu, a piece of mail, a photo or video someone sent you. It's on the Talk tab."
            ),
            HelpEntry(
                title: "Adding something",
                body: "Add a photo, video, or document gives you three ways in: Take a photo with the camera right now, Choose a photo or video from your library, or Choose a file for a PDF, Word document, text file, or video from Files. Videos top out at 30 megabytes: a clip of a few minutes, not a whole movie."
            ),
            HelpEntry(
                title: "What you get back",
                body: "A full spoken description: people, objects, colors, layout, and any text read word for word. For a video, the description covers what happens over the course of the clip, not just a single frame. For documents there's also Document text: the exact wording, separate from the description, for when you need it precise rather than summarized."
            ),
            HelpEntry(
                title: "Dates it finds",
                body: "If a document or photo has a future date on it (an appointment, a due date, an event) it shows up under Dates found with its own Save reminder button."
            ),
        ]),
        HelpSection(title: "Described video", entries: [
            HelpEntry(
                title: "What it makes",
                body: "A copy of a whole video with a narrator describing what happens on screen in the pauses, keeping the actors, music and sound. It's on the Create tab as Described video, and on any video in the Library as Make a described copy."
            ),
            HelpEntry(
                title: "Choosing a video",
                body: "Choose a video from Files or from Photos, paste a YouTube link, or start from a Library video. A YouTube link you copied in another app fills in by itself when you open the screen; iOS asks once whether Kade-AI may paste, and Settings, Kade-AI, Paste from Other Apps, Allow stops it asking. Checking a video is free. A long upload keeps going while Kade-AI is open; if it stops, choose the same video again and it carries on where it stopped."
            ),
            HelpEntry(
                title: "The narration",
                body: "Narrator voice opens a list of every voice, grouped and searchable, and Play a sample lets you hear it first. Then the usual speed and the fastest it may go, how much to describe, whether to pause the picture when a description will not fit, the narrator's volume, a closer look at fast scenes and logos, a first pass to learn who is who, notes for the describer, and Describe only part of it, with From and To times."
            ),
            HelpEntry(
                title: "The price",
                body: "Nothing is spent until you choose. The confirmation gives an estimate and the maximum charge you approve. Metered analysis uses your account balance, with unused reserved money returned when it stops or finishes. Narration and voice samples are included. Admin processing is paid by the platform. While it works you hear the stage and the percent now and then, the Lock Screen shows its progress, and a notification says when it's done."
            ),
            HelpEntry(
                title: "When it's done",
                body: "Play the described video, listen to the described audio, or read the described transcript one line at a time. Save or share sends the video, audio or transcript to Files or anywhere else. Keep it in your Library files it with the family or just for you. After a preview, Describe the rest finishes the video, and parts that could not be described can be tried again. Finished copies are kept for seven days."
            ),
            HelpEntry(
                title: "Watching with the screen locked, and captions",
                body: "The described video keeps playing when you switch apps or lock the phone, and play, pause, and back or forward 10 seconds work from the Lock Screen and your headphones. Captions show on the picture for anyone watching with you. With VoiceOver on, they are not read over the film. To have VoiceOver read them, turn on Read captions with VoiceOver, under Listen to the described audio or at the top of the player. VoiceOver then follows Media Descriptions in Settings, Accessibility, VoiceOver, Verbosity: Speech reads them aloud, Braille shows them on a braille display."
            ),
        ], ownerTrial: true),
        HelpSection(title: "My Creations and the Wall of Fame", entries: [
            HelpEntry(
                title: "My Creations",
                body: "On the Create tab: every picture, video, and song you've made with your characters, newest first. Each one reads its description in a single swipe, then Play for videos and songs, Save or share to put it in your Photos through the share sheet, and a Wall of Fame switch to share it with the family or take it back off."
            ),
            HelpEntry(
                title: "Wall of Fame",
                body: "Creations the whole family chose to share, with who made them. You can play or save anything on the Wall; only the person who made something can take it down."
            ),
        ]),
        HelpSection(title: "Games, Matchmaker, and Game Room", entries: [
            HelpEntry(
                title: "Playing a game",
                body: "The Parlor on the Play tab has every game on a menu. You can also just tell any character \"deal me in\" in an ordinary chat, on a call, or by phone, and they'll deal you into Blackjack, Uno, Trivia, Hangman, and more. The game runs right in the conversation."
            ),
            HelpEntry(
                title: "The Matchmaker",
                body: "Five quick questions about what you're in the mood for, then three characters who might be a good match, each with why they were picked. Nothing you answer is saved, and you can retake it as many times as you like. A Start talking to button on each match takes you straight into a new conversation with them."
            ),
            HelpEntry(
                title: "The Game Room",
                body: "Family standings from every finished game: who's won the most, recent results, and highlights like the biggest Blackjack win. It lives inside The Parlor, on the menu right under the games. Walking away from a table mid-game doesn't count against you; only played-out games land there."
            ),
        ]),
        HelpSection(title: "Kade's Clubhouse", entries: [
            HelpEntry(
                title: "What it is",
                body: "Live voice rooms for the family: real stereo sound, person to person on Kade's own room server. Open Kade's Clubhouse on the Play tab, pick a room like The Porch, and you're in with your mic live. The roster says who's here and who's talking, one button mutes your mic, and another reads the room out loud. Joining can take a few extra seconds while a sleeping room server wakes up; the screen says so while it happens."
            ),
            HelpEntry(
                title: "The shared jukebox",
                body: "One music player for the whole room, and everybody holds the remote: anyone can play, pause, skip ahead, jump back, or stop it, and it changes for everyone, like a real living-room stereo. Add a song from your files politely with Add it to the queue, or rudely with Cut in and play it now. If somebody skips your song, hit Back a song and take it back; radio fights are allowed. Your music volume is yours alone: it starts low so talk carries over the music, and the volume slider changes only your ears. Voices always come through at full volume."
            ),
            HelpEntry(
                title: "The Hotel: private rooms",
                body: "Private rooms that stay off the list on purpose; the code is the key. Check in with your group's passcode and the Hotel finds your room; nobody ever sees a list of who has a room open. Open a room of your own with a name and a speakable passcode (letters and numbers only) and pass the code around. A Parlor party table's code works as a passcode too, so one code can carry both the cards and the voices. Whoever opened a room can close it for good, from the same screen."
            ),
            HelpEntry(
                title: "Character guests",
                body: "From inside any room you can invite one character to sit in as a guest. They're honest about being a turn-taker: press Your turn with their name when you want them to speak, and they answer out loud in their own voice for the whole room. Between turns they follow the conversation through a rough transcription. Anyone in the room can ask them to leave, and rooms with no guest seated are never transcribed at all."
            ),
        ]),
        HelpSection(title: "Debate Room and Conversation Hall", entries: [
            HelpEntry(
                title: "Starting a room",
                body: "The Debate Room is on the Play tab. Its plus button lets you set a topic or scene, add optional ground rules, and pick 2 to 6 characters to put in it together."
            ),
            HelpEntry(
                title: "Running a room",
                body: "Continue lets whoever's turn it is speak next. Choose who's next lets you pick a specific character to jump in out of turn. You can type something yourself at any point; you don't have to wait for a turn."
            ),
            HelpEntry(
                title: "Hearing the debate",
                body: "Voices is on by default: every new line plays out loud in that character's own voice the moment it lands. Opening an old room never reads the whole backlog at you. With VoiceOver, flick to \u{2018}Play this line\u{2019} or \u{2018}Play from here\u{2019} in the Actions rotor on any line; without it, touch and hold the line for the same choices. The speaker toggle under the turn buttons turns voices off and on."
            ),
            HelpEntry(
                title: "Keep it going",
                body: "The forward toggle runs the debate by itself: each character takes their turn, each clip finishes before the next turn starts, twelve turns at a stretch, then it pauses and says so before spending more. Any error or daily cap stops it immediately, out loud. Turn it off any time to take the wheel back."
            ),
            HelpEntry(
                title: "Deep Think debates",
                body: "The brain toggle makes every turn reason hard before speaking: slower and a little costlier, but the arguments come back sharper. It remembers the setting per room."
            ),
            HelpEntry(
                title: "Changing the cast",
                body: "The person-with-a-plus button in the top corner adds or removes characters mid-debate; a room holds two to six. The Narrator notes who joined or left right in the transcript, so returning characters know what they walked into."
            ),
            HelpEntry(
                title: "Debate parties",
                body: "The share button holds the party door: Open the doors mints a four-character code. Anyone signed in types it into \u{2018}Join a debate by code\u{2019} on the Debate Room screen and steps inside. They can say their piece, ask for turns, and hear every line land in the cast's voices on their own phone. The Narrator notes who walks in. Hosts keep the keys: cast changes, Hall sharing, and closing the doors stay yours."
            ),
            HelpEntry(
                title: "Sharing to the Hall",
                body: "The share button in the top corner of a room lets you share it, with a title, to the Conversation Hall, where everyone signed in to a grown-up account on the family plan can read it. Stop sharing at any time from the same button."
            ),
            HelpEntry(
                title: "The Conversation Hall",
                body: "Reached from Debate Room's Hall button. Every shared room, newest first; tap one to read the whole thing. Grown-up accounts only."
            ),
        ]),
        HelpSection(title: "Agent Builder", entries: [
            HelpEntry(
                title: "Creating a character",
                body: "Agent Builder is on the Create tab. Its plus button builds a new character from scratch: a name, a short description, their persona and instructions, a category, which model powers them, their speaking voice, and up to four conversation starters, the tappable opening lines people see when they start a chat."
            ),
            HelpEntry(
                title: "Editing, duplicating, or deleting one",
                body: "Tap any character in your list to open and change it. Swipe it, or use the Actions rotor with VoiceOver, for Delete and Duplicate. Duplicate makes a full copy, announces it, and drops it in your list ready to rename. Deleting a character doesn't touch conversations you already had with them."
            ),
            HelpEntry(
                title: "Tools",
                body: "The Tools group in the editor lists real abilities you can switch on for a character: making pictures, sending phone notifications, placing calls, checking weather, and more. The count in the group's label tells you how many are on. Anything this app doesn't recognize stays exactly as it was, so editing here never quietly unplugs something set up on the web."
            ),
            HelpEntry(
                title: "Avatar photo",
                body: "While editing an existing character, the Avatar section picks a photo from your library to be that character's picture. It uploads when you press Save, and shows beside their name in the character picker and your conversation list."
            ),
            HelpEntry(
                title: "Version history",
                body: "While editing an existing character, Version history lists every setup you've saved over. Tap one to restore it. The setup you're replacing is kept as the newest entry first, so restoring is always undoable."
            ),
            HelpEntry(
                title: "What's not here yet",
                body: "Custom actions, connecting other characters together, and attaching knowledge files exist on the web version and are still on the list for the app."
            ),
        ]),
        HelpSection(title: "Settings", entries: [
            HelpEntry(
                title: "Finding it",
                body: "Settings is on the More tab. It has its own search field at the top, and Search everything finds settings too: try ringtone, speed, or font."
            ),
            HelpEntry(
                title: "Your app icon",
                body: "Settings, App icon, lets you swap the Kade-AI icon on your home screen for Kiana, Harley, Della or Lilly's face, or back to the classic K."
            ),
            HelpEntry(
                title: "Usage & Balance",
                body: "Under Account, Usage & Balance shows what this account has spent this month and overall (chat, voices, pictures, phone calls) plus your balance. It's read-only: the one link opens the chip-in page in your browser, and nothing is ever charged from inside the app."
            ),
            HelpEntry(
                title: "Voice & Audio",
                body: "Turn Hear replies on by default for every new conversation, set the voice speed for replies and Spotter calls, and open the Pronunciation Dictionary."
            ),
            HelpEntry(
                title: "Accessibility",
                body: "High contrast switches the whole app to a true-black dark appearance with solid colors and real borders. Easy-read font and line spacing currently change how conversation messages look; Lexend and OpenDyslexic are both included. Text size isn't set here: your iPhone's own Display & Text Size setting under Settings, Accessibility already resizes everything in this app."
            ),
            HelpEntry(
                title: "Troubleshooting",
                body: "The last section of Settings holds two switches that only matter if the app freezes and Kade asks you to try them."
            ),
        ]),
        HelpSection(title: "Pronunciation Dictionary", entries: [
            HelpEntry(
                title: "What it's for",
                body: "A name or word Kade-AI mishears or says wrong: add it here once, spelled the way it sounds, and it's used everywhere, recognizing your voice on calls and in Transcribe, and reading it back correctly in replies and Spotter calls."
            ),
            HelpEntry(
                title: "Adding a word",
                body: "The plus button adds one entry: the word as it's normally spelled, and a respelling for how it should sound. For example, Kade spelled out as Katie."
            ),
            HelpEntry(
                title: "Changing or removing one",
                body: "Tap an entry to change its pronunciation. The word itself can't be edited in place: swipe it away (or use the Actions rotor with VoiceOver) and add a fresh entry if the word was wrong, not just how it sounds."
            ),
        ]),
        HelpSection(title: "Siri, widgets and shortcuts", entries: [
            HelpEntry(
                title: "Calling your Spotter hands-free",
                body: "Say \"Hey Siri, call my Spotter with Kade-AI\" and the app opens straight into a Spotter call. You don't have to find the app or the button first."
            ),
            HelpEntry(
                title: "The other phrases",
                body: "\"Hey Siri, quick dictate with Kade-AI\" starts listening immediately and copies the result to your clipboard when you stop. \"Hey Siri, transcribe with Kade-AI\" opens the transcriber ready to record without auto-starting. \"Hey Siri, describe something with Kade-AI\" opens Describe. \"Hey Siri, open my Kade-AI conversations\" goes straight to your conversation list."
            ),
            HelpEntry(
                title: "Home Screen widget",
                body: "Touch and hold an empty spot on your Home Screen, tap Edit, then Add Widget, and pick Kade-AI. The widget shows your character's face, which changes with the time of day, and a Talk button; the larger size adds Continue listening for the Library. To choose which character it shows, touch and hold the widget and pick Edit Widget."
            ),
            HelpEntry(
                title: "Call your Spotter from Control Center",
                body: "On iOS 18 and later, Call your Spotter can sit in Control Center, on the Lock Screen, or on the Action Button: edit Control Center, tap Add a Control, and search for Kade-AI."
            ),
            HelpEntry(
                title: "Progress on the Lock Screen",
                body: "While the Sound Booth makes a song or a Library upload runs, its progress shows on the Lock Screen and in the Dynamic Island, and VoiceOver reads it there, so you can put the phone down and check back."
            ),
            HelpEntry(
                title: "The Action Button",
                body: "On phones that have one, open Settings, Action Button, choose Shortcut, and pick Quick Dictate (or any of the others) from Kade-AI. One press of the side button and it's listening, no unlocking to a home screen first."
            ),
            HelpEntry(
                title: "Renaming them",
                body: "If a phrase doesn't come naturally to you, open the Shortcuts app, find Kade-AI, and give any of these your own wording."
            ),
            HelpEntry(
                title: "Quick Actions on the app icon",
                body: "Touch and hold the Kade-AI icon on your Home Screen for the same shortcuts (Call your Spotter, Transcribe, Describe, Quick Dictate, and Your conversations) without needing to say anything out loud."
            ),
        ]),
        HelpSection(title: "Kade Keys keyboard", entries: [
            HelpEntry(
                title: "Adding the keyboard",
                body: "Settings, General, Keyboard, Keyboards, Add New Keyboard, then pick Kade Keys. In any app, the globe key on the system keyboard switches between keyboards: hold it and pick Kade Keys, or tap it to cycle. Everything on Kade Keys is a big labeled button: your phrases, then globe, space and delete along the bottom."
            ),
            HelpEntry(
                title: "Dictating with Kade Keys",
                body: "The big Dictate key opens Kade-AI listening (keyboards aren't allowed microphones; every dictation keyboard does this dance). Say your piece, tap Stop, then swipe back to where you were, and the words type themselves. That self-typing needs Allow Full Access (Settings, General, Keyboard, Kade Keys); Apple gates shared storage behind the same switch as network access, but this keyboard makes no connections at all. Without the switch, your words wait on the clipboard: one long-press paste. The six quick phrases sit under the Dictate key, same as ever."
            ),
        ]),
        HelpSection(title: "Notifications and account", entries: [
            HelpEntry(
                title: "Notifications",
                body: "The app asks about notifications after your first reply, with a card saying why: so your character can tell you when a long reply is ready, and so characters can call you. Say Not now and it won't ask again; Settings, Notifications, can turn them on any time. Notifications go to whoever is signed in on this device, and signing out unlinks it so nothing lands for the wrong account. Alerts, on the More tab, keeps the history: your last 15 reminders and check-ins, how each one arrived, and your delivery choices, with a test button to prove the whole path works. A small new badge shows when something arrived since you last looked."
            ),
            HelpEntry(
                title: "Signing out",
                body: "Sign out, at the bottom of the More tab, clears your saved session on this phone, stops any book that's playing, and empties the conversation and character lists so nothing of yours is left on screen."
            ),
            HelpEntry(
                title: "What's still on the web",
                body: "Nearly everything is in the app now. The web app remains the place to top up the server fund, create a character's custom actions, and fine-tune a connection's handoff wording, and it stays available any time from the More tab as a backup."
            ),
        ]),
    ]
}

#Preview {
    NavigationStack { HelpView() }
}
