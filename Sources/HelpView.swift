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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Everything Kade-AI can do, and how to get to it. Turn on the Headings rotor to jump between sections.")
                    .font(.body)

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
        HelpSection(title: "Getting around", entries: [
            HelpEntry(
                title: "The home screen",
                body: "Sign in once and the app remembers you. From here you can call your Spotter, open your conversations, transcribe a voice memo, read this help, open the full web app, or sign out."
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
                body: "Every call is written up as a normal conversation you can read and carry on in text. Hanging up waits a moment and opens it for you, and there's a Skip button if you'd rather not wait."
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
                title: "Tidying it up",
                body: "Organize into notes gives you a title and bullet points. Clean up text keeps every word and just fixes the grammar, the filler words and the paragraphs. Undo puts back the version from before."
            ),
            HelpEntry(
                title: "Getting it out",
                body: "Copy transcript puts it on the clipboard. Share transcript opens the share sheet, including Save to Files."
            ),
        ]),
        HelpSection(title: "Siri", entries: [
            HelpEntry(
                title: "Calling your Spotter hands-free",
                body: "Say \"Hey Siri, call my Spotter with Kade-AI\" and the app opens straight into a Spotter call. You don't have to find the app or the button first."
            ),
            HelpEntry(
                title: "The other phrases",
                body: "\"Hey Siri, transcribe with Kade-AI\" opens the transcriber ready to record. \"Hey Siri, open my Kade-AI conversations\" goes straight to your conversation list."
            ),
            HelpEntry(
                title: "Renaming them",
                body: "If a phrase doesn't come naturally to you, open the Shortcuts app, find Kade-AI, and give any of these your own wording."
            ),
        ]),
        HelpSection(title: "Notifications and account", entries: [
            HelpEntry(
                title: "Notifications",
                body: "The app asks once, at first launch. Notifications go to whoever is signed in on this device, and signing out unlinks it so nothing lands for the wrong account."
            ),
            HelpEntry(
                title: "Signing out",
                body: "Sign out on the home screen clears your saved session on this phone and empties the conversation and companion lists so nothing of yours is left on screen."
            ),
            HelpEntry(
                title: "What's still on the web",
                body: "Games and the Game Room aren't in the app yet. Open Kade-AI web from the home screen for those."
            ),
        ]),
    ]
}

#Preview {
    NavigationStack { HelpView() }
}
