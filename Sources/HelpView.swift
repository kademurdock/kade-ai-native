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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Everything Kade-AI can do, and how to get to it. Turn on the Headings rotor to jump between sections.")
                    .font(.body)

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

                ForEach(HelpSection.all) { section in
                    VStack(alignment: .leading, spacing: 14) {
                        Text(section.title)
                            .font(.title3.bold())
                            .accessibilityAddTraits(.isHeader)

                        ForEach(section.entries) { entry in
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

                Text("Still stuck? Open Kade-AI web from the home screen and use the help pages there, or just ask any companion — they know how the app works.")
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

struct HelpEntry: Identifiable {
    let title: String
    let body: String
    var id: String { title }
}

struct HelpSection: Identifiable {
    let title: String
    let entries: [HelpEntry]
    var id: String { title }

    static let all: [HelpSection] = [
        // Session 18 (Kade's pick): a spoken changelog. Each build batch gets
        // a plain-language entry here -- newest first, what changed and what
        // to try -- so she hears it in-app instead of digging through chat
        // history. KEEP THIS CURRENT: every future batch should rewrite the
        // newest entry before the build fires, and collapse older ones.
        HelpSection(title: "What's new", entries: [
            HelpEntry(
                title: "Newest build",
                body: "The haptics grew bass: every tap is now a real pattern — hard knocks with low rumbles behind them — and the thinking pulse became a true heartbeat, a lub-dub in your hand in rhythm with the dot on screen. The sounds turned into bubbles: sending slides up like a bloop rising, a reply slides back down, and the audition list in Settings plays them all. Deep think now switches off the moment you switch it off — it had been lingering up to ten minutes after. And turning Deep think off is instant everywhere: web, app, and phone."
            ),
            HelpEntry(
                title: "The build before",
                body: "My Creations and the Wall of Fame went native: play, save, and share everything the family has made. Recording no longer cuts off at one minute — it runs as long as you're talking and stops itself only after ten silent seconds, with a warning and a spoken line. Report a problem from the top of this Help screen. Settings grew the sound-and-tap audition list, the Pulse with the visuals switch, and Deep think arrived as the brain button at the start of the message row. Plus two VoiceOver fixes from family testing: the voice messages toggle flips reliably at any text size, and a brand-new chat is right there in your list when you back out of it."
            ),
            HelpEntry(
                title: "Earlier",
                body: "Agent Builder with voices, starters, tools, photos, duplicating, and version history. Usage and Balance in Settings. Spotter call audio fixed, with a chirp when audio starts flowing. Describe for photos, videos, and documents. Stop a reply mid-write. Matchmaker, Game Room, Debate Room and the Conversation Hall went native. The Pronunciation Dictionary. Quick Dictate. Transcribe with file import. Calls with auto-reconnect and Siri phrases."
            ),
        ]),
        HelpSection(title: "Getting around", entries: [
            HelpEntry(
                title: "The home screen",
                body: "Sign in once and the app remembers you. Everything is grouped in three sections you can jump between with the Headings rotor: Talk holds Call your Spotter, Your conversations, and Alerts. Tools holds Transcribe, Describe, Matchmaker, Game Room, Debate Room, and Agent Builder. Settings and help holds Settings, this help, the full web app, and Sign out."
            ),
            HelpEntry(
                title: "Your conversations",
                body: "Every chat you've had, newest first, including the written version of every call. Double-tap a conversation to open it. There's a search field above the list that filters what's loaded."
            ),
            HelpEntry(
                title: "Actions on a conversation",
                body: "With VoiceOver, focus a conversation row and flick down through the Actions rotor for Rename, Archive and Delete. Sighted users can swipe the row sideways for the same things."
            ),
            HelpEntry(
                title: "Starting a new chat",
                body: "The pencil button in the conversation list starts a fresh conversation. Whoever you were last talking to carries over until you pick someone else."
            ),
        ]),
        HelpSection(title: "Chatting", entries: [
            HelpEntry(
                title: "Sending a message",
                body: "Type in the box at the bottom and activate Send. If a send fails you'll get a Retry button that resends exactly what you wrote — you don't have to type it again."
            ),
            HelpEntry(
                title: "Talking instead of typing",
                body: "The microphone button next to the composer records what you say, turns it into text, and drops it into the box so you can check it before sending."
            ),
            HelpEntry(
                title: "Actions on a message",
                body: "Focus any message and flick down through the Actions rotor: Copy Text, Play as Voice Message, Share Text, Save Voice Message, and — on the most recent turn only — Edit and Resend, Regenerate Reply, and Delete Message."
            ),
            HelpEntry(
                title: "Why Edit and Delete only work on the newest messages",
                body: "The app shows your conversation as one straight line in the order it happened. Editing or deleting something from the middle would leave an answer to a question that no longer exists, so those actions are deliberately limited to the latest turn."
            ),
            HelpEntry(
                title: "Switching companions",
                body: "The companion button at the top of a conversation opens the picker. It lands you straight in a search field with the keyboard up — start typing a name, or dismiss the keyboard to browse Recent and the category sections underneath."
            ),
        ]),
        HelpSection(title: "Voice messages", entries: [
            HelpEntry(
                title: "Hearing replies out loud",
                body: "Turn Voice messages on in a conversation and every reply is spoken in that companion's own voice as it arrives. It's a toggle — VoiceOver reads its value as On or Off."
            ),
            HelpEntry(
                title: "Speed",
                body: "The speed control beside the toggle runs from 0.75 up to 2 times. It takes effect straight away, even in the middle of a clip, and it's remembered next time."
            ),
            HelpEntry(
                title: "Saving one",
                body: "Save Voice Message in a message's actions opens the share sheet, where Save to Files, AirDrop, Messages and Mail all live. The file is named after who said it and when."
            ),
        ]),
        HelpSection(title: "Calling", entries: [
            HelpEntry(
                title: "Starting a call",
                body: "The call button at the top of any conversation starts a real-time voice call with that companion. Just talk — there's no button to hold."
            ),
            HelpEntry(
                title: "Interrupting",
                body: "Stop Talking cuts her off mid-sentence so you can get a word in. You can also just start talking over her; she'll stop on her own."
            ),
            HelpEntry(
                title: "Your Spotter",
                body: "Bring in your Spotter hands the call to your live visual companion, who can see through your camera and describe what's in front of you. The status line and captions change to her name so you always know who's talking."
            ),
            HelpEntry(
                title: "Letting the companion you're already talking to see",
                body: "Let her see your camera is different from Spotter: the same voice you're already talking to gains sight and works what she sees into her own replies, instead of handing the call to someone else."
            ),
            HelpEntry(
                title: "The flashlight",
                body: "In a dark room the flashlight now comes on by itself so the camera has something to work with, and announces that it did. Touch the flashlight button once and it stops deciding for you for the rest of that call."
            ),
            HelpEntry(
                title: "If a call drops",
                body: "You'll hear \"the call dropped, reconnecting\" and the app puts it back together on its own, camera and Spotter included. Long Spotter calls hit a limit roughly every ten minutes on the video service's side, and this is what carries you across it."
            ),
            HelpEntry(
                title: "Audio check",
                body: "The call screen has a line reporting where the sound is going, the volume, and how many clips have arrived and played. If a call ever has no sound, read that line out — it says which part failed."
            ),
            HelpEntry(
                title: "The lock screen",
                body: "A call keeps running when the screen locks and shows up on the lock screen and in Control Centre. Stop ends the call; play and pause interrupt her, the same as Stop Talking."
            ),
            HelpEntry(
                title: "After you hang up",
                body: "Every call is written up as a normal conversation you can read and carry on in text. Hanging up waits a moment and opens it for you, and there's a Skip button if you'd rather not wait. That written-up call opens over your original conversation — there's a Close button, top left, to get back to it."
            ),
        ]),
        HelpSection(title: "Transcribe", entries: [
            HelpEntry(
                title: "What it's for",
                body: "Recording a thought, or a long voice memo somebody sent you, and getting it back as text you can edit and keep."
            ),
            HelpEntry(
                title: "Recording in takes",
                body: "Start recording, say your piece, stop. The text lands in the transcript. Record again and the next take is added on the end, so you can think in pieces without losing anything."
            ),
            HelpEntry(
                title: "Importing a file",
                body: "Import audio file picks a recording someone sent you from Files, iCloud Drive, or another app — a voice memo, a video's audio, up to about two hours long — and adds its words to the transcript the same way a recorded take does."
            ),
            HelpEntry(
                title: "Quick Dictate",
                body: "Reachable by Siri (\"quick dictate with Kade-AI\"), a Home Screen Quick Action, or an Action Button — lands you here already listening. Tap Stop when you're done and the clean text is on your clipboard immediately, ready to paste into whatever you were doing. This is the fast way to get your voice into any app without a whole separate keyboard to install."
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
                body: "Getting a photo, video, flyer, letter, screenshot, or document described to you, or read back word for word — a menu, a piece of mail, a photo or video someone sent you."
            ),
            HelpEntry(
                title: "Adding something",
                body: "Add a photo, video, or document gives you three ways in: Take a photo with the camera right now, Choose a photo or video from your library, or Choose a file for a PDF, Word document, text file, or video from Files. Videos top out at 30 megabytes — a clip of a few minutes, not a whole movie."
            ),
            HelpEntry(
                title: "What you get back",
                body: "A full spoken description — people, objects, colors, layout, and any text read word for word. For a video, the description covers what happens over the course of the clip, not just a single frame. For documents there's also Document text: the exact wording, separate from the description, for when you need it precise rather than summarized."
            ),
            HelpEntry(
                title: "Dates it finds",
                body: "If a document or photo has a future date on it — an appointment, a due date, an event — it shows up under Dates found with its own Save reminder button."
            ),
        ]),
        HelpSection(title: "My Creations and the Wall of Fame", entries: [
            HelpEntry(
                title: "My Creations",
                body: "Every picture, video, and song you've made with your companions, newest first. Each one reads its description in a single swipe, then Play for videos and songs, Save or share to put it in your Photos through the share sheet, and a Wall of Fame switch to share it with the family or take it back off."
            ),
            HelpEntry(
                title: "Wall of Fame",
                body: "Creations the whole family chose to share, with who made them. You can play or save anything on the Wall; only the person who made something can take it down."
            ),
        ]),
        HelpSection(title: "Games, Matchmaker, and Game Room", entries: [
            HelpEntry(
                title: "Playing a game",
                body: "You don't need a special screen for this — just tell any companion \"deal me in\" in an ordinary chat, on a call, or by phone, and they'll deal you into Blackjack, Uno, Trivia, Hangman, and more. The game runs right in the conversation."
            ),
            HelpEntry(
                title: "The Matchmaker",
                body: "Five quick questions about what you're in the mood for, then three companions who might be a good match, each with why they were picked. Nothing you answer is saved, and you can retake it as many times as you like. A Start talking to button on each match takes you straight into a new conversation with them."
            ),
            HelpEntry(
                title: "The Game Room",
                body: "Family standings from every finished game — who's won the most, recent results, and a couple of highlights like the biggest Blackjack win. Walking away from a table mid-game doesn't count against you; only played-out games land here."
            ),
        ]),
        HelpSection(title: "Debate Room and Conversation Hall", entries: [
            HelpEntry(
                title: "Starting a room",
                body: "The plus button in Debate Room lets you set a topic or scene, add optional ground rules, and pick 2 to 6 companions to put in it together."
            ),
            HelpEntry(
                title: "Running a room",
                body: "Continue lets whoever's turn it is speak next. Choose who's next lets you pick a specific companion to jump in out of turn. You can type something yourself at any point — you don't have to wait for a turn."
            ),
            HelpEntry(
                title: "Sharing to the Hall",
                body: "The button in the top corner of a room lets you share it, with a title, to the Conversation Hall — where everyone signed in to a grown-up account on the family plan can read it. Stop sharing at any time from the same button."
            ),
            HelpEntry(
                title: "The Conversation Hall",
                body: "Reached from Debate Room's Hall button. Every shared room, newest first — tap one to read the whole thing. Grown-up accounts only."
            ),
        ]),
        HelpSection(title: "Agent Builder", entries: [
            HelpEntry(
                title: "Creating an agent",
                body: "The plus button in Agent Builder lets you build a new companion from scratch: a name, a short description, their persona and instructions, a category, which model powers them, their speaking voice, and up to four conversation starters — tappable opening lines people see when they start a chat."
            ),
            HelpEntry(
                title: "Editing, duplicating, or deleting one",
                body: "Tap any agent in your list to open and change it. Swipe it, or use the Actions rotor, for Delete and Duplicate — Duplicate makes a full copy, announces it, and drops it in your list ready to rename. Deleting an agent doesn't touch conversations you already had with them."
            ),
            HelpEntry(
                title: "Tools",
                body: "The Tools group in the editor lists real abilities you can switch on for an agent — making pictures, sending phone notifications, placing calls, checking weather, and more. The count in the group's label tells you how many are on. Anything this app doesn't recognize stays exactly as it was, so editing here never quietly unplugs something set up on the web."
            ),
            HelpEntry(
                title: "Avatar photo",
                body: "While editing an existing agent, the Avatar section picks a photo from your library to be that agent's picture. It uploads when you press Save. The picture shows on the web version today; native list rows don't draw pictures yet."
            ),
            HelpEntry(
                title: "Version history",
                body: "While editing an existing agent, Version history lists every setup you've saved over. Tap one to restore it — the setup you're replacing is kept as the newest entry first, so restoring is always undoable."
            ),
            HelpEntry(
                title: "What's not here yet",
                body: "Custom actions, connecting other agents together, and attaching knowledge files exist on the web version and are still on the list for native."
            ),
        ]),
        HelpSection(title: "Settings", entries: [
            HelpEntry(
                title: "Finding it",
                body: "The Settings button on the home screen holds Speech, Accessibility, Feedback, and Account together in one place, including the Pronunciation Dictionary and Usage & Balance."
            ),
            HelpEntry(
                title: "Usage & Balance",
                body: "Under Account, Usage & Balance shows what this account has spent this month and overall — chat, voices, pictures, phone calls — plus your balance. It's read-only: the one link opens the chip-in page in your browser, and nothing is ever charged from inside the app."
            ),
            HelpEntry(
                title: "Speech",
                body: "Turn voice messages on by default for every new conversation, set how fast voice messages and Spotter calls play back, and open the Pronunciation Dictionary."
            ),
            HelpEntry(
                title: "Accessibility",
                body: "High contrast switches the whole app to a true-black dark appearance. Easy-read font and line spacing currently change how conversation messages look — Lexend and OpenDyslexic are both included. Text size isn't set here: your iPhone's own Display & Text Size setting under Settings, Accessibility already resizes everything in this app."
            ),
        ]),
        HelpSection(title: "Pronunciation Dictionary", entries: [
            HelpEntry(
                title: "What it's for",
                body: "A name or word Kade-AI mishears or says wrong — add it here once, spelled the way it sounds, and it's used everywhere: recognizing your voice on calls and in Transcribe, and reading it back correctly in voice messages and Spotter calls."
            ),
            HelpEntry(
                title: "Adding a word",
                body: "The plus button adds one entry: the word as it's normally spelled, and a respelling for how it should sound — for example, Kade spelled out as Katie."
            ),
            HelpEntry(
                title: "Changing or removing one",
                body: "Tap an entry to change its pronunciation. The word itself can't be edited in place — swipe it away (or use the Actions rotor) and add a fresh entry if the word was wrong, not just how it sounds."
            ),
        ]),
        HelpSection(title: "Siri and Quick Actions", entries: [
            HelpEntry(
                title: "Calling your Spotter hands-free",
                body: "Say \"Hey Siri, call my Spotter with Kade-AI\" and the app opens straight into a Spotter call. You don't have to find the app or the button first."
            ),
            HelpEntry(
                title: "The other phrases",
                body: "\"Hey Siri, quick dictate with Kade-AI\" starts listening immediately and copies the result to your clipboard when you stop. \"Hey Siri, transcribe with Kade-AI\" opens the transcriber ready to record without auto-starting. \"Hey Siri, describe something with Kade-AI\" opens Describe. \"Hey Siri, open my Kade-AI conversations\" goes straight to your conversation list."
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
                body: "Touch and hold the Kade-AI icon on your Home Screen for the same shortcuts — Call your Spotter, Transcribe, Describe, Quick Dictate, and Your conversations — without needing to say anything out loud."
            ),
        ]),
        HelpSection(title: "Notifications and account", entries: [
            HelpEntry(
                title: "Notifications",
                body: "The app asks once, at first launch. Notifications go to whoever is signed in on this device, and signing out unlinks it so nothing lands for the wrong account. The Alerts button on the home screen keeps the history: your last 15 reminders and check-ins, how each one arrived, and your delivery choices, with a test button to prove the whole path works."
            ),
            HelpEntry(
                title: "Signing out",
                body: "Sign out on the home screen clears your saved session on this phone and empties the conversation and companion lists so nothing of yours is left on screen."
            ),
            HelpEntry(
                title: "What's still on the web",
                body: "Nearly everything is native now. The web app remains the place to top up the server fund, create an agent's custom actions, and fine-tune a connection's handoff wording -- and it stays available any time as a backup."
            ),
        ]),
    ]
}

#Preview {
    NavigationStack { HelpView() }
}
