import SwiftUI
import UIKit
import AVFoundation

/// The real Settings tab session 17/18's own doc comments kept flagging as
/// "still open" -- Kade: "We also need a native way to access settings
/// like speech and whatnot. Accessability low vision stuff like that."
/// Two sections today:
///
/// - Speech: the Pronunciation Dictionary (moved here from its own
///   home-screen button -- see git history for `PronunciationDictionaryView`'s
///   doc comment, which already flagged this exact move as "session 17/18's
///   still-open tabs decision"), the voice-messages-by-default toggle, and
///   voice message speed.
/// - Accessibility: high contrast, easy-read font family, line spacing --
///   the native counterpart to the web app's Settings > General >
///   Accessibility. See `AppearancePreferences` for what's genuinely wired
///   app-wide today versus scoped to message text for now.
///
/// The playback-speed control deliberately REUSES ConversationDetailView's
/// own button + confirmationDialog pattern rather than a native `Picker` --
/// that file's own doc comment documents this as a deliberate house rule
/// for this specific control (reads its current value rather than burying
/// it in the label, its own sibling accessibility element, never combined
/// into the toggle -- session 11 fixed a real bug getting to that state).
/// Two different controls for the identical setting in two screens of the
/// same app would just be a second thing to relearn by touch/VoiceOver.
/// Font family and line spacing are novel controls with no prior
/// convention to preserve, so they use the same plain `Picker` this
/// codebase already uses for Agent Builder's Category/Provider/Model.
struct SettingsView: View {
    /// Aug 4 2026 (her pick): VoiceOver-spoken progress during long deep
    /// thinks ("Still thinking -- about 900 characters so far," roughly
    /// every 20 seconds). Announcement-only; thoughts are never read by
    /// TTS. Same key ConversationDetailView reads.
    @AppStorage("kade.thinkingProgress.spoken") private var spokenThinkingProgress = true

    /// Build 217: shared with ConversationDetailView by key. See its own
    /// declaration there for what the two answers mean.
    @AppStorage("kade.chat.simpleTranscript") private var simpleTranscript = false
    /// Build 218: see the `simpleComposer` declaration in
    /// ConversationDetailView for what its two answers mean.
    @AppStorage("kade.chat.simpleComposer") private var simpleComposer = false
    // Aug 6 2026: whisper mode — night-quiet delivery, the native twin of the
    // web toggle that shipped in Part 32. Rides the send payload; the server
    // appends the whisper head line while it's on.
    @AppStorage("kade.speech.whisperMode") private var whisperMode = false
    let apiClient: KadeAPIClient

    @EnvironmentObject private var voiceService: VoiceService
    @EnvironmentObject private var appearance: AppearancePreferences
    /// Part 75 (Aug 21 2026): the agent-call ringtone pick rides the next
    /// /push-register so the bridge knows this user's DEFAULT ring.
    @EnvironmentObject private var pushService: PushService
    @State private var callRingtone = UserDefaults.standard.string(forKey: PushService.ringtoneDefaultsKey) ?? "ring_classic"
    @State private var ringtonePlayer: AVAudioPlayer?
    @EnvironmentObject private var feedback: FeedbackPrefs
    /// July 23 2026: opt-in location ride-along (singleton — the watch must
    /// outlive this screen, so it's observed here, never owned here).
    @ObservedObject private var locationShare = KadeLocationShare.shared

    /// Aug 13 2026 — LONG-TASK PING. Server-side preference, not @AppStorage:
    /// the fork is what watches the clock and the subscriber count, so the
    /// fork is what has to know the answer. Lives on the same per-user
    /// KadeNudgePref doc as the reminder channels, read and written through
    /// the existing GET/POST /api/kade/nudges/prefs pair.
    @State private var longTaskPing = false
    /// Until the real value lands, the switch is disabled rather than shown
    /// as OFF — a toggle that reads "off" before it has loaded is a lie, and
    /// under VoiceOver it's a lie the user acts on.
    @State private var longTaskPingLoaded = false
    @State private var showingSpeedPicker = false
    /// Bool-based (not a `NavigationLink`, matching this app's own house
    /// rule -- see `RoomListView`'s doc comment) push onto the SAME
    /// NavigationStack this screen already lives in. `PronunciationDictionaryView`
    /// itself sets only `.navigationTitle` with no `NavigationStack` of its
    /// own, i.e. it already expects to be PUSHED (an automatic back
    /// chevron), not sheet-presented -- sheet-presenting it here would
    /// reintroduce the exact "no way out" trap this session's earlier fix
    /// (see `ConversationDetailView`'s `isStandalonePresentation` doc
    /// comment) was about.
    @State private var showingPronunciationDictionary = false
    @State private var showingMemories = false
    @State private var showingLogbook = false
    /// Same Bool-push house pattern as the dictionary above.
    @State private var showingUsage = false
    /// Aug 4 2026: Kade Keys phrases screen, same Bool-push pattern.
    @State private var showingKeyboardPhrases = false
    /// Aug 4 2026 (her redesign): the keyboard lane's automatic transcript
    /// cleanup. Same key TranscribeView reads.
    @AppStorage("kade.keyboard.autoClean") private var keyboardAutoClean = true
    @State private var showingAccountSecurity = false
    /// Build 193: morning-brief settings screen, same Bool-push pattern.
    @State private var showingBrief = false
    /// Build 193 — OWN YOUR DATA: /api/export/mine downloads a zip of
    /// everything that's theirs; the share sheet hands it wherever they
    /// want it (Files, AirDrop, mail to themselves). `exportItem != nil`
    /// presents the sheet — prepared-state shape, same as voice messages.
    @State private var exportBusy = false
    @State private var exportItem: ShareItem?
    @State private var exportStatus: String?
    /// Session 26 (her ask: "put a box to check or something, where people
    /// can choose their default agent"): sheet flag for the main-agent
    /// picker, plus a mirror of the stored name so the row re-renders the
    /// moment a new pick lands (UserDefaults itself isn't observed).
    @State private var showingMainAgentPicker = false
    @State private var mainAgentName = DefaultAgentStore.displayName

    var body: some View {
        List {
            // Session 26: the headline personal setting — who the app opens
            // with and who new chats start pointed at. Reuses the same
            // search-first picker as everywhere else; picking from it here
            // changes the DEFAULT only, never any existing conversation.
            Section {
                Button {
                    showingMainAgentPicker = true
                } label: {
                    LabeledContent {
                        Text(mainAgentName)
                    } label: {
                        Label("Your main agent", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Your main agent: \(mainAgentName)")
                .accessibilityHint("Opens the agent picker. Your main agent answers when the app opens into a chat, and every new chat starts with them.")
            } header: {
                Text("Main agent")
            } footer: {
                Text("The app opens into a chat with your main agent, and new chats start with them. Pick anyone -- a Kade-AI character or one of your own. You can still switch who answers inside any single conversation.")
            }

            // Part 75 (Aug 21 2026, agent calls): which sound an agent CALL
            // rings with -- the default for call plans that don't name their
            // own tone. Tapping a row saves the pick AND plays the real
            // ringtone, so the choice is made by ear, not by label -- the
            // only honest way to pick a sound on a screen reader. The pick
            // rides the next /push-register (PushService reads it back).
            Section {
                ForEach(Self.callRingtones) { tone in
                    Button {
                        callRingtone = tone.id
                        UserDefaults.standard.set(tone.id, forKey: PushService.ringtoneDefaultsKey)
                        pushService.ringtoneChanged()
                        previewRingtone(tone)
                    } label: {
                        LabeledContent {
                            if callRingtone == tone.id {
                                Image(systemName: "checkmark")
                            }
                        } label: {
                            Text(tone.label)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(callRingtone == tone.id ? "\(tone.label), your current ringtone" : tone.label)
                    .accessibilityHint("Sets this as your agent-call ringtone and plays it so you can hear it. Tap another to compare.")
                }
            } header: {
                Text("Agent call ringtone")
            } footer: {
                Text("When a companion calls you, this is the sound your phone rings with. Tap a tone to hear it and make it yours. An agent can also pick a different tone for one specific scheduled call.")
            }

            Section {
                Button {
                    showingMemories = true
                } label: {
                    Label("Memories", systemImage: "brain.head.profile")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Every memory card your companions keep about you — hear them, edit them, forget them, or add one. New memories also announce themselves in chat the moment they're saved.")

                Button {
                    showingLogbook = true
                } label: {
                    Label("Your Logbook", systemImage: "book.closed")
                }
                .buttonStyle(.plain)
                .accessibilityHint("The dated record your companions keep of your days — browse by day, add a line by voice, or forget entries for good.")

                // Aug 9 2026 — The World moved under Admin (her word: Reverie stays
                // out of casual reach until it's a public asset; nobody steps into
                // the city unaware). It returns here the day she opens the gates.

                Button {
                    showingPronunciationDictionary = true
                } label: {
                    Label("Pronunciation Dictionary", systemImage: "textformat.abc")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens your pronunciation dictionary -- used on calls, in Transcribe, and in voice messages.")

                Toggle(isOn: $voiceService.defaultReadAloudOn) {
                    Text("Voice messages by default")
                }
                .accessibilityHint("New conversations start with voice messages already on. You can still turn it off in any single conversation.")

                Toggle(isOn: $spokenThinkingProgress) {
                    Text("Spoken thinking progress")
                }
                .accessibilityHint("During a long Deep Think, VoiceOver quietly says how much thinking has streamed so far, about every twenty seconds. The thoughts themselves are never read out loud.")

                Toggle(isOn: $whisperMode) {
                    Text("Whisper mode (night-quiet voices)")
                }
                .accessibilityHint("While this is on, companions deliver every voice reply hushed, slow, and gentle. Same words, night-quiet delivery. Flip it off and they go back to full life.")

                speedRow
            } header: {
                Text("Speech")
            } footer: {
                Text("Voice message speed applies to every conversation and call from here on -- you can still change it from any single conversation too, and it remembers your last pick.")
            }

            // Aug 4 2026 (her keyboard redesign): Kade Keys' own home in
            // Settings -- personal phrases + the auto-cleanup toggle.
            Section {
                Button {
                    showingKeyboardPhrases = true
                } label: {
                    Label("My Keyboard Phrases", systemImage: "keyboard")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens your personal quick phrases -- the one-tap buttons on the Kade Keys keyboard.")

                Toggle(isOn: $keyboardAutoClean) {
                    Text("Clean up keyboard dictation")
                }
                .accessibilityHint("When the keyboard's Transcribe key takes your words, the transcript is tidied automatically -- filler words out, grammar fixed, your meaning untouched -- before it types. Turn off to type exactly what was heard.")
            } header: {
                Text("Kade Keys")
            } footer: {
                Text("The keyboard's big key is called Transcribe -- it opens Kade-AI to listen, cleans up what you said, and types it when you swipe back. Your phrases ride along; the keyboard needs Allow Full Access to read them.")
            }

            // Aug 4 2026: the crash catcher's user-facing half. Apple
            // writes a crash report the next time the app opens
            // (MetricKit); this shares those reports plus the breadcrumb
            // trail of recent app events -- see KadeDiagnostics.swift.
            Section {
                ShareLink(items: KadeCrashWatch.shared.shareableFiles()) {
                    Label("Share diagnostics", systemImage: "stethoscope")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the share sheet with recent crash reports and a short trail of app events, so they can be sent for debugging. Conversations are never included.")
            } header: {
                Text("Support")
            } footer: {
                Text("If the app ever crashes, open it again and share diagnostics here -- the crash report plus a timeline of what the app was doing. Never your conversations.")
            }

            // Aug 13 2026 (her ask: "you know how claude sends you a
            // notification when it's been thinking a long time"): the
            // long-task ping. OFF by default, per person, decided server-side
            // — the fork fires it only when the turn ran past 30 seconds AND
            // nobody was still attached to the stream when the reply landed.
            Section {
                Toggle(isOn: Binding(
                    get: { longTaskPing },
                    set: { newValue in
                        longTaskPing = newValue
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: newValue
                                ? "You'll be told when a slow reply lands."
                                : "Long reply notifications off."
                        )
                        Task { await saveLongTaskPing(newValue) }
                    }
                )) {
                    Text("Tell me when a slow reply lands")
                }
                .disabled(!longTaskPingLoaded)
                .accessibilityHint("Sends a notification if a reply takes more than about half a minute and you've already left the app.")
            } header: {
                Text("Long replies")
            } footer: {
                Text("Only when you've actually walked away -- if you're still in the conversation watching it arrive, nothing is sent. Quiet hours still apply, so a reply that finishes overnight waits for morning.")
            }

            // July 23 2026 (Maps/GPS slice 1, Kade-approved): opt-in
            // location ride-along for the kade_location tool. OFF by
            // default; flipping it on triggers the system permission prompt
            // via KadeLocationShare.
            Section {
                Toggle(isOn: $locationShare.enabled) {
                    Text("Share my location with your companions")
                }
                .accessibilityHint("Lets companions answer where am I, what's around me, and give walking directions, using this phone's location while the app is open.")
            } header: {
                Text("Location")
            } footer: {
                Text("Only while the app is open, and only when this is on. Nothing is shared when it's off.")
            }

            Section {
                Toggle(isOn: $appearance.highContrast) {
                    Text("High contrast")
                }
                .accessibilityHint("Switches the whole app to a true-black dark appearance.")

                Picker("Easy-read font", selection: $appearance.fontFamily) {
                    ForEach(AppearancePreferences.FontFamily.allCases) { font in
                        Text(font.displayName).tag(font)
                    }
                }
                .accessibilityHint("Changes the font used for message text.")
                .sensoryFeedback(trigger: appearance.fontFamily) { _, _ in
                    FeedbackPrefs.gate(.selection)
                }

                Picker("Line spacing", selection: $appearance.lineSpacing) {
                    ForEach(AppearancePreferences.LineSpacingLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .accessibilityHint("Changes the space between lines of message text.")
                .sensoryFeedback(trigger: appearance.lineSpacing) { _, _ in
                    FeedbackPrefs.gate(.selection)
                }
            } header: {
                Text("Accessibility")
            } footer: {
                Text("Text size isn't a separate setting here -- your iPhone's own Display & Text Size setting (Settings app, Accessibility, Display & Text Size, Larger Text) already resizes everything in this app. High contrast applies everywhere already; font and line spacing above currently apply to conversation message text, with more screens on the list.")
            }

            // Session 20 (Kade: "Auditory flare by doing haptics and sounds?
            // Earcons, nothing crazy obnoxious"). One home for every non-speech
            // cue in the app, all opt-out (default on). These are on-device
            // only, same as everything else on this screen.
            Section {
                Toggle(isOn: $feedback.soundEffects) {
                    Text("Sound effects")
                }
                .accessibilityHint("Short sounds when a message sends, a reply lands, or something goes wrong. They play alongside VoiceOver, never over it.")

                Toggle(isOn: $feedback.haptics) {
                    Text("Haptics")
                }
                .accessibilityHint("Gentle taps at key moments -- sending, a reply landing, recording start and stop, a call connecting or ending.")

                // Session 23 (Kade: "make them pulse with the visuals...
                // you could always turn it off").
                Toggle(isOn: $feedback.sensorySync) {
                    Text("Pulse with the visuals")
                }
                .disabled(!feedback.haptics)
                .accessibilityHint("When something on screen is gently pulsing, like the dot while a companion is thinking, a soft tap pulses in time with it. Haptics must be on.")

                /* ⭐ BUILD 217 -- the send-freeze bisect, in her hands.
                 * Lives here rather than in a hidden debug screen because SHE
                 * is the one who can answer the question, in one tap, without
                 * waiting on another build. Default OFF; harmless to leave on
                 * if she ever prefers the plainer transcript. */
                Toggle(isOn: $simpleTranscript) {
                    Text("Simple transcript (troubleshooting)")
                }
                .accessibilityHint("Renders each message as plain text with no per-message actions, bubble, or timestamp. Turn this on if sending a message freezes the app -- it tells us whether the message rows are the cause. Message actions are still available from the Actions menu.")

                /* ⭐ BUILD 218 -- the second half of the bisect. Build 217's
                 * transcript switch already cleared the message rows (she
                 * froze with every row a bare Text), so this one aims at the
                 * only other text-measuring surface on the screen. */
                Toggle(isOn: $simpleComposer) {
                    Text("Simple composer (troubleshooting)")
                }
                .accessibilityHint("Makes the message box a single line that scrolls instead of growing to five lines. Turn this on if sending still freezes the app -- it tells us whether the message box is the cause. You can still type and send messages of any length.")

                Toggle(isOn: $feedback.forceReduceMotion) {
                    Text("Reduce motion")
                }
                .accessibilityHint("Turns off the app's decorative animations even if your iPhone's own Reduce Motion setting is off. Your system Reduce Motion setting is always honored on top of this.")

                // Session 23 (Kade: "Eventually I'll make new sounds"):
                // the two lonely test buttons grew into the full vocabulary
                // -- every sound playable, every tap feelable, so she can
                // audition the current set and redesign from real hearings
                // rather than memory. Plain Buttons in Form rows, each its
                // own element, no children:.ignore (the Amber rule).
                DisclosureGroup("Hear every sound") {
                    auditionSoundRow("Message sent", .messageSent)
                    auditionSoundRow("Reply landed", .messageReceived)
                    auditionSoundRow("Working", .actionStart)
                    auditionSoundRow("Done", .actionDone)
                    auditionSoundRow("Something went wrong", .error)
                }
                .disabled(!feedback.soundEffects)
                .accessibilityHint("Opens a list of every sound the app makes, each with a play button.")

                DisclosureGroup("Feel every tap") {
                    auditionTapRow("Tap") { KadeHaptics.tap() }
                    auditionTapRow("Success") { KadeHaptics.success() }
                    auditionTapRow("Warning") { KadeHaptics.warning() }
                    auditionTapRow("Error") { KadeHaptics.error() }
                    auditionTapRow("Heartbeat") { KadeHaptics.pulseBeat() }
                    auditionTapRow("Big press") { KadeHaptics.press() }
                }
                .disabled(!feedback.haptics)
                .accessibilityHint("Opens a list of every haptic the app uses, each with a button that fires it once.")
            } header: {
                Text("Feedback")
            } footer: {
                Text("Sound effects and haptics are on by default. Sounds are brief and quiet, and always play alongside VoiceOver rather than interrupting it.")
            }
            Section {
                Button {
                    showingUsage = true
                } label: {
                    Label("Usage & Balance", systemImage: "dollarsign.circle")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows what this account has spent this month and overall, and your balance. Read-only -- nothing is charged from inside the app.")

                // Session 26, leftovers item 7: change password (the whole
                // reset flow runs in-app -- see AccountSecurityView's doc
                // comment) and delete account, double-confirmed.
                Button {
                    showingAccountSecurity = true
                } label: {
                    Label("Password & Account", systemImage: "key")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Change your password, or permanently delete this account.")

                // Build 193: the morning brief — per-account, written by
                // your own companion, delivered as a push with LISTEN/READ
                // buttons. Settings for it live one push away.
                Button {
                    showingBrief = true
                } label: {
                    Label("Morning brief", systemImage: "sun.horizon")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Your companion's morning rundown — turn it on, pick the time, choose what's in it, and hear today's.")

                // Build 193 — OWN YOUR DATA (her spec: "so people can take
                // ownership of their own data"). One tap, one zip: memory
                // cards, logbook, every conversation — readable text first,
                // machine JSON beside it. Own account only, by construction
                // (the JWT is the only key the server uses).
                Button {
                    Task { await downloadMyData() }
                } label: {
                    Label(exportBusy ? "Gathering your data…" : "Download your data", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.plain)
                .accessibilityHint("Builds a zip of your memories, logbook, and conversations, then opens the share sheet to save it wherever you like.")
                if let exportStatus {
                    Text(exportStatus)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Your words belong to you. The download is everything this account has — readable text plus the raw data.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadLongTaskPing() }
        .sheet(isPresented: $showingMainAgentPicker) {
            AgentPickerView(currentAgentId: DefaultAgentStore.storedId) { agent in
                DefaultAgentStore.set(agent)
                mainAgentName = agent.name
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "\(agent.name) is now your main agent."
                )
            }
        }
        .navigationDestination(isPresented: $showingPronunciationDictionary) {
            PronunciationDictionaryView(apiClient: apiClient)
        }
        .navigationDestination(isPresented: $showingMemories) {
            MemoriesView(apiClient: apiClient)
        }
        .navigationDestination(isPresented: $showingLogbook) {
            LogbookView(apiClient: apiClient)
        }
        .navigationDestination(isPresented: $showingKeyboardPhrases) {
            KeyboardPhrasesView(apiClient: apiClient)
        }
        .navigationDestination(isPresented: $showingUsage) {
            UsageView(apiClient: apiClient)
        }
        .navigationDestination(isPresented: $showingAccountSecurity) {
            AccountSecurityView(apiClient: apiClient)
        }
        .navigationDestination(isPresented: $showingBrief) {
            BriefView(apiClient: apiClient)
        }
        .sheet(item: $exportItem) { item in
            ShareSheet(item: item)
        }
        .confirmationDialog(
            "Voice message speed",
            isPresented: $showingSpeedPicker,
            titleVisibility: .visible
        ) {
            ForEach(VoiceService.availableRates, id: \.self) { rate in
                Button(VoiceService.rateSpokenLabel(rate)) {
                    voiceService.playbackRate = rate
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: "Voice message speed \(VoiceService.rateSpokenLabel(rate))."
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The long-task preference lives on the same per-user prefs doc as the
    /// reminder channels. Read-only failure is deliberately silent: a settings
    /// screen that shouts about a network hiccup teaches people to distrust
    /// every switch on it. The toggle simply stays disabled until a real value
    /// arrives, so it can never show a state the server doesn't agree with.
    private func loadLongTaskPing() async {
        guard !longTaskPingLoaded else { return }
        let req = apiClient.request(path: "api/kade/nudges/prefs", method: "GET", authorized: true)
        guard let result = try? await apiClient.send(req),
              result.1.statusCode == 200,
              let parsed = try? JSONDecoder().decode(NudgePrefsEnvelope.self, from: result.0)
        else { return }
        longTaskPing = parsed.prefs?.longTaskPing ?? false
        longTaskPingLoaded = true
    }

    /// Write-back. A failure here DOES get spoken — the user just made a
    /// choice and deserves to know it didn't take, and the switch snaps back
    /// so the screen never claims a setting that isn't saved.
    private func saveLongTaskPing(_ enabled: Bool) async {
        var req = apiClient.request(path: "api/kade/nudges/prefs", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["longTaskPing": enabled])
        let ok = (try? await apiClient.send(req)).map { (200 ..< 300).contains($0.1.statusCode) } ?? false
        if !ok {
            longTaskPing = !enabled
            UIAccessibility.post(
                notification: .announcement,
                argument: "That didn't save. Check your connection and try again."
            )
        }
    }

    /// Build 193: fetch the export zip WITH the bearer token (a naked link
    /// can't ride JWT — the web side learned the same lesson at build time),
    /// land it in a real dated file, then hand it to the share sheet.
    private func downloadMyData() async {
        guard !exportBusy else { return } // politely decline the double-tap
        exportBusy = true
        exportStatus = nil
        defer { exportBusy = false }
        // The server zips a whole account in one breath — give it a longer
        // leash than the 60-second default, same mechanism as the long
        // Debate turns.
        let req = apiClient.request(path: "api/export/mine", authorized: true, timeout: 180)
        do {
            let (data, http) = try await apiClient.send(req)
            guard http.statusCode == 200, !data.isEmpty else {
                exportStatus = "The export didn't come back — try again in a moment."
                UIAccessibility.post(notification: .announcement, argument: "The export didn't come back.")
                return
            }
            let stamp = String(KadeDateFormatting.isoNow().prefix(10)) // yyyy-MM-dd
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("kade-ai-export-\(stamp).zip")
            try data.write(to: url)
            exportItem = ShareItem(fileURL: url)
            let mb = String(format: "%.1f", Double(data.count) / 1_048_576)
            exportStatus = "Your export is ready — \(mb) megabytes."
            UIAccessibility.post(notification: .announcement, argument: "Export ready. The share sheet is open — save it wherever you like.")
        } catch {
            exportStatus = "Couldn't download the export. Check the connection and try again."
            UIAccessibility.post(notification: .announcement, argument: "Couldn't download the export.")
        }
    }

    private var speedRow: some View {
        Button {
            showingSpeedPicker = true
        } label: {
            HStack {
                Text("Voice message speed")
                    .foregroundStyle(Color.primary)
                Spacer()
                Text(VoiceService.rateLabel(voiceService.playbackRate))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        // Session 26, the Amber rule (build 139 / df915e2): no
        // children:.ignore on a Button — this was the exact construction
        // that killed Amber's conversation rows. Label/value/hint stay.
        .accessibilityLabel("Voice message speed")
        .accessibilityValue(VoiceService.rateSpokenLabel(voiceService.playbackRate))
        .accessibilityHint("Double-tap to change how fast voice messages and Spotter calls play back.")
    }

    // MARK: - Session 23 audition rows

    private func auditionSoundRow(_ name: String, _ earcon: Earcon) -> some View {
        Button {
            Earcons.shared.play(earcon)
        } label: {
            HStack {
                Text(name)
                Spacer()
                Image(systemName: "play.circle")
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play the \(name) sound")
    }

    private func auditionTapRow(_ name: String, _ fire: @escaping () -> Void) -> some View {
        Button(action: fire) {
            HStack {
                Text(name)
                Spacer()
                Image(systemName: "hand.tap")
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Feel the \(name) haptic")
    }
}

#Preview {
    NavigationStack {
        SettingsView(apiClient: KadeAPIClient())
    }
    .environmentObject(AppearancePreferences())
    .environmentObject(VoiceService(client: KadeAPIClient()))
    .environmentObject(FeedbackPrefs.shared)
}

/// Just the sliver of GET /api/kade/nudges/prefs this screen needs. Every
/// field optional on purpose: that route serves reminder channels, birthday
/// settings and a phone number too, and this screen must not care when any of
/// them change shape.
// MARK: - Agent-call ringtones (Part 75, Aug 21 2026)

extension SettingsView {
    struct RingtoneOption: Identifiable {
        let id: String
        let label: String
        let file: String
    }

    /// The bundled ring set — ids match the bridge's CALL_RINGTONES map and
    /// the files ship in Sources/ (XcodeGen bundles non-source files as
    /// resources). Adding a tone = new .caf here + one bridge map line.
    static let callRingtones: [RingtoneOption] = [
        RingtoneOption(id: "ring_classic", label: "Classic bell", file: "KadeRingClassic"),
        RingtoneOption(id: "ring_marimba", label: "Marimba", file: "KadeRingMarimba"),
        RingtoneOption(id: "ring_chimes", label: "Chimes", file: "KadeRingChimes"),
        RingtoneOption(id: "ring_pulse", label: "Soft pulse", file: "KadeRingPulse"),
        RingtoneOption(id: "ring_harp", label: "Harp sweep", file: "KadeRingHarp"),
    ]

    /// Plays the actual ringtone file, replacing any running preview. Quiet-
    /// failing on purpose: a missing file should never break Settings.
    func previewRingtone(_ tone: RingtoneOption) {
        guard let url = Bundle.main.url(forResource: tone.file, withExtension: "caf") else { return }
        ringtonePlayer?.stop()
        ringtonePlayer = try? AVAudioPlayer(contentsOf: url)
        ringtonePlayer?.play()
    }
}

private struct NudgePrefsEnvelope: Decodable {
    struct Prefs: Decodable {
        let longTaskPing: Bool?
    }
    let prefs: Prefs?
}
