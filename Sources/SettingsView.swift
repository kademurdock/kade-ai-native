import SwiftUI
import UIKit
import AVFoundation

/// The real Settings tab session 17/18's own doc comments kept flagging as
/// "still open" -- Kade: "We also need a native way to access settings
/// like speech and whatnot. Accessability low vision stuff like that."
///
/// PART 85 (Aug 22 2026) — THE RESTRUCTURE + SEARCH. What changed and why:
///
/// - Sections now run in priority order (Main agent → Voice & Audio → Calls
///   → Notifications → Memory → Accessibility → Feedback & Sounds → Kade
///   Keys → Location → Account → Support), everything ONE tap deep.
/// - The 73-row ringtone picker moved to its OWN pushed screen
///   (`RingtoneSettingsView` below) — the main screen shows one row with the
///   current tone's name. 70+ rows off the first flick-through.
/// - THE SEARCH FIELD is the headline: `.searchable` over a registry of
///   every actionable row. While a query is active the list flattens to the
///   REAL rows (same bindings — a toggle found by search IS the toggle),
///   each with its section name PREPENDED to the accessibility label
///   ("Calls, Agent call ringtone, button"), so a VoiceOver user hears where
///   a found thing lives. A small offline synonym map (tone/ring/sound →
///   ringtone; speed/rate/fast → voice speed; vibrate/buzz → haptics …)
///   costs nothing and needs no model call.
///
/// THE SCARS, still law in this file: no LazyVStack anywhere near a
/// VoiceOver path (Apple framework bug, radar FB21851974, builds 204-225);
/// Bool-based pushes onto the host NavigationStack, never sheet-trapping a
/// pushed-style screen (see `RoomListView`'s doc comment); no
/// `children: .ignore` on Buttons (the Amber rule, build 139); haptics never
/// ride a transcript-mutation commit (these Settings pickers are ordinary
/// screens — allowed).
///
/// The playback-speed control deliberately REUSES ConversationDetailView's
/// own button + confirmationDialog pattern rather than a native `Picker` --
/// that file's own doc comment documents this as a deliberate house rule
/// for this specific control (reads its current value rather than burying
/// it in the label, its own sibling accessibility element, never combined
/// into the toggle -- session 11 fixed a real bug getting to that state).
struct SettingsView: View {
    /// Aug 4 2026 (her pick): VoiceOver-spoken progress during long deep
    /// thinks ("Still thinking -- about 900 characters so far," roughly
    /// every 20 seconds). Announcement-only; thoughts are never read by
    /// TTS. Same key ConversationDetailView reads.
    @AppStorage("kade.thinkingProgress.spoken") private var spokenThinkingProgress = true
    // Part 91.6 — the streaming-speech switch. Default ON because it strictly
    // shortens the wait; here as a switch because a voice change is the kind
    // of thing that should be undoable without a TestFlight build.

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
    /// Part 85: the ringtone picker's own screen, same Bool-push pattern.
    @State private var showingRingtones = false
    /// Part 85: mirror of the saved ringtone id so the Calls row re-renders
    /// when a pick lands on the pushed screen (UserDefaults isn't observed;
    /// `.onAppear` refreshes it when the push comes back).
    @State private var currentRingtoneId = UserDefaults.standard.string(forKey: PushService.ringtoneDefaultsKey) ?? "ring_classic"
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
    /// Part 85 — the settings search query. Empty = the normal sections.
    @State private var settingsQuery = ""

    private var trimmedQuery: String {
        settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            if trimmedQuery.isEmpty {
                mainAgentSection
                voiceAudioSection
                callsSection
                notificationsSection
                memorySection
                accessibilitySection
                feedbackSection
                kadeKeysSection
                locationSection
                accountSection
                supportSection
            } else {
                searchResultsSection
            }
        }
        .searchable(text: $settingsQuery, prompt: "Search settings")
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadLongTaskPing() }
        .onAppear {
            currentRingtoneId = UserDefaults.standard.string(forKey: PushService.ringtoneDefaultsKey) ?? "ring_classic"
        }
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
        .navigationDestination(isPresented: $showingRingtones) {
            RingtoneSettingsView()
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

    // MARK: - The sections, in Part-85 priority order

    private var mainAgentSection: some View {
        // Session 26: the headline personal setting — who the app opens
        // with and who new chats start pointed at. Reuses the same
        // search-first picker as everywhere else; picking from it here
        // changes the DEFAULT only, never any existing conversation.
        Section {
            mainAgentRow(searchStyle: false)
        } header: {
            sectionHeader("Main agent")
        } footer: {
            Text("The app opens into a chat with your main agent, and new chats start with them. Pick anyone -- a Kade-AI character or one of your own. You can still switch who answers inside any single conversation.")
        }
    }

    private var voiceAudioSection: some View {
        Section {
            voiceDefaultRow(searchStyle: false)
            thinkingProgressRow(searchStyle: false)
            streamingVoiceRow(searchStyle: false)
            whisperRow(searchStyle: false)
            speedRow(searchStyle: false)
            pronunciationRow(searchStyle: false)
        } header: {
            sectionHeader("Voice & Audio")
        } footer: {
            Text("Voice message speed applies to every conversation and call from here on -- you can still change it from any single conversation too, and it remembers your last pick.")
        }
    }

    private var callsSection: some View {
        // Part 75/84 (agent calls): the ringtone pick. Part 85 demoted the
        // 73-row picker to its own pushed screen — this row shows the current
        // tone and opens the full grouped picker one level down.
        Section {
            ringtoneRow(searchStyle: false)
        } header: {
            sectionHeader("Calls")
        } footer: {
            Text("When a companion calls you, this is the sound your phone rings with. The picker plays every tone out loud so the choice is made by ear — and an agent can pick a different tone for one specific scheduled call; every tone has a name they know.")
        }
    }

    private var notificationsSection: some View {
        Section {
            longTaskPingRow(searchStyle: false)
            briefRow(searchStyle: false)
        } header: {
            sectionHeader("Notifications")
        } footer: {
            Text("The slow-reply ping only fires when you've actually walked away -- if you're still in the conversation watching it arrive, nothing is sent. Quiet hours still apply, so a reply that finishes overnight waits for morning.")
        }
    }

    private var memorySection: some View {
        Section {
            memoriesRow(searchStyle: false)
            logbookRow(searchStyle: false)
        } header: {
            sectionHeader("Memory")
        } footer: {
            Text("What your companions keep about you, in your hands — hear it, edit it, forget it.")
        }
    }

    private var accessibilitySection: some View {
        Section {
            highContrastRow(searchStyle: false)
            fontRow(searchStyle: false)
            spacingRow(searchStyle: false)
        } header: {
            sectionHeader("Accessibility")
        } footer: {
            Text("Text size isn't a separate setting here -- your iPhone's own Display & Text Size setting (Settings app, Accessibility, Display & Text Size, Larger Text) already resizes everything in this app. High contrast applies everywhere already; font and line spacing above currently apply to conversation message text, with more screens on the list.")
        }
    }

    private var feedbackSection: some View {
        // Session 20 (Kade: "Auditory flare by doing haptics and sounds?
        // Earcons, nothing crazy obnoxious"). One home for every non-speech
        // cue in the app, all opt-out (default on). These are on-device
        // only, same as everything else on this screen.
        Section {
            soundEffectsRow(searchStyle: false)
            hapticsRow(searchStyle: false)
            sensorySyncRow(searchStyle: false)
            simpleTranscriptRow(searchStyle: false)
            simpleComposerRow(searchStyle: false)
            reduceMotionRow(searchStyle: false)

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
                // Part 87 §2.5: the four arrival shapes, auditionable. A
                // pattern you can only feel when a real push happens is a
                // pattern nobody can learn -- and the whole point is that the
                // hand knows what arrived before VoiceOver gets a word out.
                // Learn them here once, on purpose, then recognise them later.
                auditionTapRow("Arriving: a message") { KadeHaptics.arrival(.message) }
                auditionTapRow("Arriving: a call") { KadeHaptics.arrival(.call) }
                auditionTapRow("Arriving: a reminder") { KadeHaptics.arrival(.reminder) }
                auditionTapRow("Arriving: an alert") { KadeHaptics.arrival(.alert) }
            }
            .disabled(!feedback.haptics)
            .accessibilityHint("Opens a list of every haptic the app uses, each with a button that fires it once.")
        } header: {
            sectionHeader("Feedback & Sounds")
        } footer: {
            Text("Sound effects and haptics are on by default. Sounds are brief and quiet, and always play alongside VoiceOver rather than interrupting it.")
        }
    }

    private var kadeKeysSection: some View {
        // Aug 4 2026 (her keyboard redesign): Kade Keys' own home in
        // Settings -- personal phrases + the auto-cleanup toggle.
        Section {
            keyboardPhrasesRow(searchStyle: false)
            keyboardCleanRow(searchStyle: false)
        } header: {
            sectionHeader("Kade Keys")
        } footer: {
            Text("The keyboard's big key is called Transcribe -- it opens Kade-AI to listen, cleans up what you said, and types it when you swipe back. Your phrases ride along; the keyboard needs Allow Full Access to read them.")
        }
    }

    private var locationSection: some View {
        // July 23 2026 (Maps/GPS slice 1, Kade-approved): opt-in
        // location ride-along for the kade_location tool. OFF by
        // default; flipping it on triggers the system permission prompt
        // via KadeLocationShare.
        Section {
            locationRow(searchStyle: false)
        } header: {
            sectionHeader("Location")
        } footer: {
            Text("Only while the app is open, and only when this is on. Nothing is shared when it's off.")
        }
    }

    private var accountSection: some View {
        Section {
            usageRow(searchStyle: false)
            accountSecurityRow(searchStyle: false)
            exportRow(searchStyle: false)
            if let exportStatus {
                Text(exportStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("Account")
        } footer: {
            Text("Your words belong to you. The download is everything this account has — readable text plus the raw data.")
        }
    }

    private var supportSection: some View {
        // Aug 4 2026: the crash catcher's user-facing half. Apple
        // writes a crash report the next time the app opens
        // (MetricKit); this shares those reports plus the breadcrumb
        // trail of recent app events -- see KadeDiagnostics.swift.
        Section {
            diagnosticsRow(searchStyle: false)
        } header: {
            sectionHeader("Support")
        } footer: {
            Text("If the app ever crashes, open it again and share diagnostics here -- the crash report plus a timeline of what the app was doing. Never your conversations.")
        }
    }

    /// §2.2: section titles are headings to the rotor. SwiftUI List headers
    /// mostly get this for free; the explicit trait is belt-and-braces and
    /// costs nothing.
    private func sectionHeader(_ title: String) -> some View {
        Text(title).accessibilityAddTraits(.isHeader)
    }

    // MARK: - Part 85: search

    /// Every actionable row on this screen, searchable offline. `keywords`
    /// carry the synonym map — tone/ring/sound find the ringtone row,
    /// speed/rate/fast find voice speed, vibrate/buzz find haptics — so a
    /// person types the word THEY have, not the word the screen has.
    private enum SettingRow: String, CaseIterable, Identifiable {
        case mainAgent, ringtone
        case voiceDefault, thinkingProgress, streamingVoice, whisper, speed, pronunciation
        case longTaskPing, brief
        case memories, logbook
        case highContrast, font, spacing
        case soundEffects, haptics, sensorySync, simpleTranscript, simpleComposer, reduceMotion
        case keyboardPhrases, keyboardClean
        case location
        case usage, accountSecurity, export
        case diagnostics

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mainAgent: return "Your main agent"
            case .ringtone: return "Agent call ringtone"
            case .voiceDefault: return "Voice messages by default"
            case .thinkingProgress: return "Spoken thinking progress"
            case .streamingVoice: return "Faster voice (streaming)"
            case .whisper: return "Whisper mode"
            case .speed: return "Voice message speed"
            case .pronunciation: return "Pronunciation Dictionary"
            case .longTaskPing: return "Tell me when a slow reply lands"
            case .brief: return "Morning brief"
            case .memories: return "Memories"
            case .logbook: return "Your Logbook"
            case .highContrast: return "High contrast"
            case .font: return "Easy-read font"
            case .spacing: return "Line spacing"
            case .soundEffects: return "Sound effects"
            case .haptics: return "Haptics"
            case .sensorySync: return "Pulse with the visuals"
            case .simpleTranscript: return "Simple transcript"
            case .simpleComposer: return "Simple composer"
            case .reduceMotion: return "Reduce motion"
            case .keyboardPhrases: return "My Keyboard Phrases"
            case .keyboardClean: return "Clean up keyboard dictation"
            case .location: return "Share my location"
            case .usage: return "Usage & Balance"
            case .accountSecurity: return "Password & Account"
            case .export: return "Download your data"
            case .diagnostics: return "Share diagnostics"
            }
        }

        var section: String {
            switch self {
            case .mainAgent: return "Main agent"
            case .ringtone: return "Calls"
            case .voiceDefault, .thinkingProgress, .streamingVoice, .whisper, .speed, .pronunciation: return "Voice & Audio"
            case .longTaskPing, .brief: return "Notifications"
            case .memories, .logbook: return "Memory"
            case .highContrast, .font, .spacing: return "Accessibility"
            case .soundEffects, .haptics, .sensorySync, .simpleTranscript, .simpleComposer, .reduceMotion: return "Feedback & Sounds"
            case .keyboardPhrases, .keyboardClean: return "Kade Keys"
            case .location: return "Location"
            case .usage, .accountSecurity, .export: return "Account"
            case .diagnostics: return "Support"
            }
        }

        var keywords: String {
            switch self {
            case .mainAgent: return "agent main default character companion who answers opens picker"
            case .ringtone: return "ringtone ring rings tone tones sound call calls phone marimba preview stop music"
            case .voiceDefault: return "voice messages read aloud speak spoken tts audio default on"
            case .thinkingProgress: return "thinking progress deep think spoken voiceover announce"
            case .streamingVoice: return "faster voice streaming stream latency delay gap wait quick sooner beta first word space between message"
            case .whisper: return "whisper quiet night hushed gentle soft volume"
            case .speed: return "speed rate fast slow playback voice quicker talk faster"
            case .pronunciation: return "pronunciation pronounce names dictionary say saying word words"
            case .longTaskPing: return "notification notify ping slow reply long task push tell alert"
            case .brief: return "morning brief briefing rundown daily news push"
            case .memories: return "memory memories remember cards forget companions know"
            case .logbook: return "logbook diary journal days record entries"
            case .highContrast: return "contrast dark black theme appearance display low vision"
            case .font: return "font text typeface easy read dyslexic letters"
            case .spacing: return "spacing line space text gap read"
            case .soundEffects: return "sound sounds effects earcon earcons chime beep audio"
            case .haptics: return "haptic haptics vibrate vibration buzz tap taps feel"
            case .sensorySync: return "pulse visuals sync haptic thinking dot rhythm"
            case .simpleTranscript: return "simple transcript troubleshooting freeze plain rows debug"
            case .simpleComposer: return "simple composer troubleshooting freeze message box debug"
            case .reduceMotion: return "motion animation reduce animations still"
            case .keyboardPhrases: return "keyboard phrases quick kade keys buttons typing"
            case .keyboardClean: return "keyboard dictation clean cleanup transcribe filler grammar typing"
            case .location: return "location gps where directions maps share place"
            case .usage: return "usage balance money spend spent cost dollars account"
            case .accountSecurity: return "password account security delete change login"
            case .export: return "export download data zip backup own take"
            case .diagnostics: return "diagnostics crash bug report share support stethoscope trouble"
            }
        }

        func matches(_ query: String) -> Bool {
            let q = query.lowercased()
            let terms = q.split(separator: " ").map(String.init)
            let haystack = "\(title.lowercased()) \(section.lowercased()) \(keywords)"
            // Every typed word must land somewhere — "voice speed" finds the
            // speed row, not every row containing "voice".
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    private var matchedRows: [SettingRow] {
        SettingRow.allCases.filter { $0.matches(trimmedQuery) }
    }

    private var searchResultsSection: some View {
        Section {
            if matchedRows.isEmpty {
                Text("Nothing here matches \"\(trimmedQuery)\". Try a plainer word — ring, speed, font, password…")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(matchedRows) { row in
                    searchRow(row)
                }
            }
        } header: {
            sectionHeader(matchedRows.isEmpty ? "No matches" : "Matches")
        } footer: {
            Text("These are the live controls — flip a switch right here, or open a row where it lives.")
        }
    }

    /// The REAL control for each row, rendered in search results. Same
    /// bindings as the sectioned copies; `searchStyle: true` prepends the
    /// section name to the accessibility label per the Part-85 brief.
    @ViewBuilder
    private func searchRow(_ row: SettingRow) -> some View {
        switch row {
        case .mainAgent: mainAgentRow(searchStyle: true)
        case .ringtone: ringtoneRow(searchStyle: true)
        case .voiceDefault: voiceDefaultRow(searchStyle: true)
        case .thinkingProgress: thinkingProgressRow(searchStyle: true)
        case .streamingVoice: streamingVoiceRow(searchStyle: true)
        case .whisper: whisperRow(searchStyle: true)
        case .speed: speedRow(searchStyle: true)
        case .pronunciation: pronunciationRow(searchStyle: true)
        case .longTaskPing: longTaskPingRow(searchStyle: true)
        case .brief: briefRow(searchStyle: true)
        case .memories: memoriesRow(searchStyle: true)
        case .logbook: logbookRow(searchStyle: true)
        case .highContrast: highContrastRow(searchStyle: true)
        case .font: fontRow(searchStyle: true)
        case .spacing: spacingRow(searchStyle: true)
        case .soundEffects: soundEffectsRow(searchStyle: true)
        case .haptics: hapticsRow(searchStyle: true)
        case .sensorySync: sensorySyncRow(searchStyle: true)
        case .simpleTranscript: simpleTranscriptRow(searchStyle: true)
        case .simpleComposer: simpleComposerRow(searchStyle: true)
        case .reduceMotion: reduceMotionRow(searchStyle: true)
        case .keyboardPhrases: keyboardPhrasesRow(searchStyle: true)
        case .keyboardClean: keyboardCleanRow(searchStyle: true)
        case .location: locationRow(searchStyle: true)
        case .usage: usageRow(searchStyle: true)
        case .accountSecurity: accountSecurityRow(searchStyle: true)
        case .export: exportRow(searchStyle: true)
        case .diagnostics: diagnosticsRow(searchStyle: true)
        }
    }

    /// "Ringtones, Calls, button" — the section rides ahead of the label so
    /// a search hit says where it lives. Identity function outside search.
    private func searchLabel(_ row: SettingRow, _ base: String) -> String {
        "\(row.section). \(base)"
    }

    // MARK: - The rows (one definition each; sections and search share them)

    private func mainAgentRow(searchStyle: Bool) -> some View {
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
        .accessibilityLabel(searchStyle ? searchLabel(.mainAgent, "Your main agent: \(mainAgentName)") : "Your main agent: \(mainAgentName)")
        .accessibilityHint("Opens the agent picker. Your main agent answers when the app opens into a chat, and every new chat starts with them.")
    }

    private func ringtoneRow(searchStyle: Bool) -> some View {
        Button {
            showingRingtones = true
        } label: {
            LabeledContent {
                Text(RingtoneSettingsView.label(forId: currentRingtoneId))
            } label: {
                Label("Agent call ringtone", systemImage: "bell.badge")
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel((searchStyle ? "Calls. " : "") + "Agent call ringtone: \(RingtoneSettingsView.label(forId: currentRingtoneId))")
        .accessibilityHint("Opens the ringtone picker — every tone grouped by feel, played out loud as you choose.")
    }

    private func voiceDefaultRow(searchStyle: Bool) -> some View {
        Toggle(isOn: $voiceService.defaultReadAloudOn) {
            Text(searchStyle ? searchLabel(.voiceDefault, "Voice messages by default") : "Voice messages by default")
        }
        .accessibilityHint("New conversations start with voice messages already on. You can still turn it off in any single conversation.")
    }

    private func thinkingProgressRow(searchStyle: Bool) -> some View {
        Toggle(isOn: $spokenThinkingProgress) {
            Text(searchStyle ? searchLabel(.thinkingProgress, "Spoken thinking progress") : "Spoken thinking progress")
        }
        .accessibilityHint("During a long Deep Think, VoiceOver quietly says how much thinking has streamed so far, about every twenty seconds. The thoughts themselves are never read out loud.")
    }

    private func streamingVoiceRow(searchStyle: Bool) -> some View {
        Toggle(isOn: $voiceService.streamingPlaybackOn) {
            Text(searchStyle ? searchLabel(.streamingVoice, "Faster voice (streaming)") : "Faster voice (streaming)")
        }
        .accessibilityHint("Her voice starts almost immediately instead of waiting for each whole clip to arrive — the gap between a message landing and hearing it gets much shorter. New and still being tested: if a voice reply ever sounds odd, turn this off and it plays the old way.")
    }

    private func whisperRow(searchStyle: Bool) -> some View {
        Toggle(isOn: $whisperMode) {
            Text(searchStyle ? searchLabel(.whisper, "Whisper mode (night-quiet voices)") : "Whisper mode (night-quiet voices)")
        }
        .accessibilityHint("While this is on, companions deliver every voice reply hushed, slow, and gentle. Same words, night-quiet delivery. Flip it off and they go back to full life.")
    }

    private func speedRow(searchStyle: Bool) -> some View {
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
        .accessibilityLabel(searchStyle ? searchLabel(.speed, "Voice message speed") : "Voice message speed")
        .accessibilityValue(VoiceService.rateSpokenLabel(voiceService.playbackRate))
        .accessibilityHint("Double-tap to change how fast voice messages and Spotter calls play back.")
    }

    private func pronunciationRow(searchStyle: Bool) -> some View {
        Button {
            showingPronunciationDictionary = true
        } label: {
            Label("Pronunciation Dictionary", systemImage: "textformat.abc")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(searchStyle ? searchLabel(.pronunciation, "Pronunciation Dictionary") : "Pronunciation Dictionary")
        .accessibilityHint("Opens your pronunciation dictionary -- used on calls, in Transcribe, and in voice messages.")
    }

    private func longTaskPingRow(searchStyle: Bool) -> some View {
        // Aug 13 2026 (her ask: "you know how claude sends you a
        // notification when it's been thinking a long time"): the
        // long-task ping. OFF by default, per person, decided server-side
        // — the fork fires it only when the turn ran past 30 seconds AND
        // nobody was still attached to the stream when the reply landed.
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
            Text(searchStyle ? searchLabel(.longTaskPing, "Tell me when a slow reply lands") : "Tell me when a slow reply lands")
        }
        .disabled(!longTaskPingLoaded)
        .accessibilityHint("Sends a notification if a reply takes more than about half a minute and you've already left the app.")
    }

    private func briefRow(searchStyle: Bool) -> some View {
        // Build 193: the morning brief — per-account, written by
        // your own companion, delivered as a push with LISTEN/READ
        // buttons. Settings for it live one push away.
        Button {
            showingBrief = true
        } label: {
            Label("Morning brief", systemImage: "sun.horizon")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(searchStyle ? searchLabel(.brief, "Morning brief") : "Morning brief")
        .accessibilityHint("Your companion's morning rundown — turn it on, pick the time, choose what's in it, and hear today's.")
    }

    private func memoriesRow(searchStyle: Bool) -> some View {
        Button {
            showingMemories = true
        } label: {
            Label("Memories", systemImage: "brain.head.profile")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(searchStyle ? searchLabel(.memories, "Memories") : "Memories")
        .accessibilityHint("Every memory card your companions keep about you — hear them, edit them, forget them, or add one. New memories also announce themselves in chat the moment they're saved.")
    }

    private func logbookRow(searchStyle: Bool) -> some View {
        Button {
            showingLogbook = true
        } label: {
            Label("Your Logbook", systemImage: "book.closed")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(searchStyle ? searchLabel(.logbook, "Your Logbook") : "Your Logbook")
        .accessibilityHint("The dated record your companions keep of your days — browse by day, add a line by voice, or forget entries for good.")
    }

    private func highContrastRow(searchStyle: Bool) -> some View {
        Toggle(isOn: $appearance.highContrast) {
            Text(searchStyle ? searchLabel(.highContrast, "High contrast") : "High contrast")
        }
        .accessibilityHint("Switches the whole app to a true-black dark appearance.")
    }

    private func fontRow(searchStyle: Bool) -> some View {
        Picker(searchStyle ? searchLabel(.font, "Easy-read font") : "Easy-read font", selection: $appearance.fontFamily) {
            ForEach(AppearancePreferences.FontFamily.allCases) { font in
                Text(font.displayName).tag(font)
            }
        }
        .accessibilityHint("Changes the font used for message text.")
        .sensoryFeedback(trigger: appearance.fontFamily) { _, _ in
            FeedbackPrefs.gate(.selection)
        }
    }

    private func spacingRow(searchStyle: Bool) -> some View {
        Picker(searchStyle ? searchLabel(.spacing, "Line spacing") : "Line spacing", selection: $appearance.lineSpacing) {
            ForEach(AppearancePreferences.LineSpacingLevel.allCases) { level in
                Text(level.displayName).tag(level)
            }
        }
        .accessibilityHint("Changes the space between lines of message text.")
        .sensoryFeedback(trigger: appearance.lineSpacing) { _, _ in
            FeedbackPrefs.gate(.selection)
        }
    }

    private func soundEffectsRow(searchStyle: Bool) -> some View {
        Toggle(isOn: $feedback.soundEffects) {
            Text(searchStyle ? searchLabel(.soundEffects, "Sound effects") : "Sound effects")
        }
        .accessibilityHint("Short sounds when a message sends, a reply lands, or something goes wrong. They play alongside VoiceOver, never over it.")
    }

    private func hapticsRow(searchStyle: Bool) -> some View {
        Toggle(isOn: $feedback.haptics) {
            Text(searchStyle ? searchLabel(.haptics, "Haptics") : "Haptics")
        }
        .accessibilityHint("Gentle taps at key moments -- sending, a reply landing, recording start and stop, a call connecting or ending.")
    }

    private func sensorySyncRow(searchStyle: Bool) -> some View {
        // Session 23 (Kade: "make them pulse with the visuals...
        // you could always turn it off").
        Toggle(isOn: $feedback.sensorySync) {
            Text(searchStyle ? searchLabel(.sensorySync, "Pulse with the visuals") : "Pulse with the visuals")
        }
        .disabled(!feedback.haptics)
        .accessibilityHint("When something on screen is gently pulsing, like the dot while a companion is thinking, a soft tap pulses in time with it. Haptics must be on.")
    }

    private func simpleTranscriptRow(searchStyle: Bool) -> some View {
        /* ⭐ BUILD 217 -- the send-freeze bisect, in her hands.
         * Lives here rather than in a hidden debug screen because SHE
         * is the one who can answer the question, in one tap, without
         * waiting on another build. Default OFF; harmless to leave on
         * if she ever prefers the plainer transcript. */
        Toggle(isOn: $simpleTranscript) {
            Text(searchStyle ? searchLabel(.simpleTranscript, "Simple transcript (troubleshooting)") : "Simple transcript (troubleshooting)")
        }
        .accessibilityHint("Renders each message as plain text with no per-message actions, bubble, or timestamp. Turn this on if sending a message freezes the app -- it tells us whether the message rows are the cause. Message actions are still available from the Actions menu.")
    }

    private func simpleComposerRow(searchStyle: Bool) -> some View {
        /* ⭐ BUILD 218 -- the second half of the bisect. Build 217's
         * transcript switch already cleared the message rows (she
         * froze with every row a bare Text), so this one aims at the
         * only other text-measuring surface on the screen. */
        Toggle(isOn: $simpleComposer) {
            Text(searchStyle ? searchLabel(.simpleComposer, "Simple composer (troubleshooting)") : "Simple composer (troubleshooting)")
        }
        .accessibilityHint("Makes the message box a single line that scrolls instead of growing to five lines. Turn this on if sending still freezes the app -- it tells us whether the message box is the cause. You can still type and send messages of any length.")
    }

    private func reduceMotionRow(searchStyle: Bool) -> some View {
        Toggle(isOn: $feedback.forceReduceMotion) {
            Text(searchStyle ? searchLabel(.reduceMotion, "Reduce motion") : "Reduce motion")
        }
        .accessibilityHint("Turns off the app's decorative animations even if your iPhone's own Reduce Motion setting is off. Your system Reduce Motion setting is always honored on top of this.")
    }

    private func keyboardPhrasesRow(searchStyle: Bool) -> some View {
        Button {
            showingKeyboardPhrases = true
        } label: {
            Label("My Keyboard Phrases", systemImage: "keyboard")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(searchStyle ? searchLabel(.keyboardPhrases, "My Keyboard Phrases") : "My Keyboard Phrases")
        .accessibilityHint("Opens your personal quick phrases -- the one-tap buttons on the Kade Keys keyboard.")
    }

    private func keyboardCleanRow(searchStyle: Bool) -> some View {
        Toggle(isOn: $keyboardAutoClean) {
            Text(searchStyle ? searchLabel(.keyboardClean, "Clean up keyboard dictation") : "Clean up keyboard dictation")
        }
        .accessibilityHint("When the keyboard's Transcribe key takes your words, the transcript is tidied automatically -- filler words out, grammar fixed, your meaning untouched -- before it types. Turn off to type exactly what was heard.")
    }

    private func locationRow(searchStyle: Bool) -> some View {
        Toggle(isOn: $locationShare.enabled) {
            Text(searchStyle ? searchLabel(.location, "Share my location with your companions") : "Share my location with your companions")
        }
        .accessibilityHint("Lets companions answer where am I, what's around me, and give walking directions, using this phone's location while the app is open.")
    }

    private func usageRow(searchStyle: Bool) -> some View {
        Button {
            showingUsage = true
        } label: {
            Label("Usage & Balance", systemImage: "dollarsign.circle")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(searchStyle ? searchLabel(.usage, "Usage & Balance") : "Usage & Balance")
        .accessibilityHint("Shows what this account has spent this month and overall, and your balance. Read-only -- nothing is charged from inside the app.")
    }

    private func accountSecurityRow(searchStyle: Bool) -> some View {
        // Session 26, leftovers item 7: change password (the whole
        // reset flow runs in-app -- see AccountSecurityView's doc
        // comment) and delete account, double-confirmed.
        Button {
            showingAccountSecurity = true
        } label: {
            Label("Password & Account", systemImage: "key")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(searchStyle ? searchLabel(.accountSecurity, "Password & Account") : "Password & Account")
        .accessibilityHint("Change your password, or permanently delete this account.")
    }

    private func exportRow(searchStyle: Bool) -> some View {
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
        .accessibilityLabel(searchStyle ? searchLabel(.export, exportBusy ? "Gathering your data" : "Download your data") : (exportBusy ? "Gathering your data" : "Download your data"))
        .accessibilityHint("Builds a zip of your memories, logbook, and conversations, then opens the share sheet to save it wherever you like.")
    }

    private func diagnosticsRow(searchStyle: Bool) -> some View {
        ShareLink(items: KadeCrashWatch.shared.shareableFiles()) {
            Label("Share diagnostics", systemImage: "stethoscope")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(searchStyle ? searchLabel(.diagnostics, "Share diagnostics") : "Share diagnostics")
        .accessibilityHint("Opens the share sheet with recent crash reports and a short trail of app events, so they can be sent for debugging. Conversations are never included.")
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
private struct NudgePrefsEnvelope: Decodable {
    struct Prefs: Decodable {
        let longTaskPing: Bool?
    }
    let prefs: Prefs?
}

// MARK: - The ringtone picker's own screen (Part 85 — demoted from the main list)

/// Part 75 (Aug 21 2026): which sound an agent CALL rings with -- the
/// default for call plans that don't name their own tone. Tapping a row
/// saves the pick AND plays the real ringtone, so the choice is made by
/// ear, not by label -- the only honest way to pick a sound on a screen
/// reader. The pick rides the next /push-register (PushService reads it
/// back).
/// Part 84 (Aug 21 2026): Kade's 72 homemade tones, grouped by feel so 70+
/// rows stay navigable by rotor-heading; previews have a STOP control and
/// stop on their own when the screen closes.
/// Part 85 (Aug 22 2026): the whole picker moved HERE, one push deep, so
/// the main Settings screen carries one row instead of seventy-three.
struct RingtoneSettingsView: View {
    @EnvironmentObject private var pushService: PushService
    @State private var callRingtone = UserDefaults.standard.string(forKey: PushService.ringtoneDefaultsKey) ?? "ring_classic"
    @State private var ringtonePlayer: AVAudioPlayer?

    var body: some View {
        List {
            Section {
                Button {
                    stopRingtonePreview()
                } label: {
                    Label("Stop preview", systemImage: "stop.circle")
                }
                .accessibilityHint("Stops the ringtone that's playing right now.")
            } footer: {
                Text("Tap any tone to hear it and make it yours; tap Stop preview to hush it. An agent can pick a different tone for one specific scheduled call — every tone has a name they know.")
            }
            ForEach(Self.ringtoneGroups, id: \.self) { group in
                Section {
                    ForEach(Self.callRingtones.filter { $0.group == group }) { tone in
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
                        .accessibilityHint("Sets this as your agent-call ringtone and plays it so you can hear it. Tap another to compare, or Stop preview to hush it.")
                    }
                } header: {
                    Text(group).accessibilityAddTraits(.isHeader)
                }
            }
        }
        .navigationTitle("Ringtones")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { stopRingtonePreview() }
    }

    /// The Calls row on the main screen shows the current pick by name.
    static func label(forId id: String) -> String {
        callRingtones.first(where: { $0.id == id })?.label ?? "Marimba"
    }

    /// Plays the actual ringtone file, replacing any running preview. Quiet-
    /// failing on purpose: a missing file should never break Settings.
    private func previewRingtone(_ tone: RingtoneOption) {
        // Full-length preview when the tone has one; the 29s ring caf otherwise.
        let url = tone.preview.flatMap { Bundle.main.url(forResource: $0, withExtension: "m4a") }
            ?? Bundle.main.url(forResource: tone.file, withExtension: "caf")
        guard let url else { return }
        ringtonePlayer?.stop()
        ringtonePlayer = try? AVAudioPlayer(contentsOf: url)
        ringtonePlayer?.play()
    }

    /// Part 84 — her gripe on the launch set: "there's no way to make it stop
    /// other than the magic tap or something."
    private func stopRingtonePreview() {
        ringtonePlayer?.stop()
        ringtonePlayer = nil
    }
}

// MARK: - Agent-call ringtones (Part 75, Aug 21 2026 — the catalog; ids match the bridge's CALL_RINGTONES map)

extension RingtoneSettingsView {
    struct RingtoneOption: Identifiable {
        let id: String
        let label: String
        let file: String
        /// Part 84.2: full-length high-quality preview (m4a). The 30-second
        /// law binds only the LOCKED-PHONE ring (Apple plays default past
        /// 30s, CallKit or not) — but her EAR-PICKING deserves the whole
        /// minute at real quality, so previews play this when present.
        let preview: String?
        let group: String
    }

    /// The bundled ring set — ids match the bridge's CALL_RINGTONES map and
    /// the files ship in Sources/ (XcodeGen bundles non-source files as
    /// resources). Adding a tone = new .caf here + one bridge map line.
    static let callRingtones: [RingtoneOption] = [
        // Classics (the launch survivor; no long preview — its caf plays).
        RingtoneOption(id: "ring_marimba", label: "Marimba", file: "KadeRingMarimba", preview: nil, group: "Classics"),
        // Dreamy & gentle
        RingtoneOption(id: "ring_ballroom_ghost", label: "Ballroom Ghost", file: "KadeRingBallroomGhost", preview: "KadePrevBallroomGhost", group: "Dreamy & gentle"),
        RingtoneOption(id: "ring_carousel", label: "Carousel", file: "KadeRingCarousel", preview: "KadePrevCarousel", group: "Dreamy & gentle"),
        RingtoneOption(id: "ring_counting_sheep", label: "Counting Sheep", file: "KadeRingCountingSheep", preview: "KadePrevCountingSheep", group: "Dreamy & gentle"),
        RingtoneOption(id: "ring_cradle_song", label: "Cradle Song", file: "KadeRingCradleSong", preview: "KadePrevCradleSong", group: "Dreamy & gentle"),
        RingtoneOption(id: "ring_creek_bed", label: "Creek Bed", file: "KadeRingCreekBed", preview: "KadePrevCreekBed", group: "Dreamy & gentle"),
        RingtoneOption(id: "ring_firefly_jar", label: "Firefly Jar", file: "KadeRingFireflyJar", preview: "KadePrevFireflyJar", group: "Dreamy & gentle"),
        RingtoneOption(id: "ring_first_frost", label: "First Frost", file: "KadeRingFirstFrost", preview: "KadePrevFirstFrost", group: "Dreamy & gentle"),
        RingtoneOption(id: "ring_harp_house", label: "Harp House", file: "KadeRingHarpHouse", preview: "KadePrevHarpHouse", group: "Dreamy & gentle"),
        RingtoneOption(id: "ring_koi_pond", label: "Koi Pond", file: "KadeRingKoiPond", preview: "KadePrevKoiPond", group: "Dreamy & gentle"),
        RingtoneOption(id: "ring_meadowlark", label: "Meadowlark", file: "KadeRingMeadowlark", preview: "KadePrevMeadowlark", group: "Dreamy & gentle"),
        RingtoneOption(id: "ring_mobile", label: "Mobile", file: "KadeRingMobile", preview: "KadePrevMobile", group: "Dreamy & gentle"),
        RingtoneOption(id: "ring_music_box", label: "Music Box", file: "KadeRingMusicBox", preview: "KadePrevMusicBox", group: "Dreamy & gentle"),
        RingtoneOption(id: "ring_nightlight", label: "Nightlight", file: "KadeRingNightlight", preview: "KadePrevNightlight", group: "Dreamy & gentle"),
        RingtoneOption(id: "ring_snow_globe", label: "Snow Globe", file: "KadeRingSnowGlobe", preview: "KadePrevSnowGlobe", group: "Dreamy & gentle"),
        RingtoneOption(id: "ring_storybook", label: "Storybook", file: "KadeRingStorybook", preview: "KadePrevStorybook", group: "Dreamy & gentle"),
        RingtoneOption(id: "ring_watercolor", label: "Watercolor", file: "KadeRingWatercolor", preview: "KadePrevWatercolor", group: "Dreamy & gentle"),
        RingtoneOption(id: "ring_wind_bells", label: "Wind Bells", file: "KadeRingWindBells", preview: "KadePrevWindBells", group: "Dreamy & gentle"),
        RingtoneOption(id: "ring_wishing_well", label: "Wishing Well", file: "KadeRingWishingWell", preview: "KadePrevWishingWell", group: "Dreamy & gentle"),
        // Calm & lo-fi
        RingtoneOption(id: "ring_aquarium", label: "Aquarium", file: "KadeRingAquarium", preview: "KadePrevAquarium", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_corner_booth", label: "Corner Booth", file: "KadeRingCornerBooth", preview: "KadePrevCornerBooth", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_drive_home", label: "Drive Home", file: "KadeRingDriveHome", preview: "KadePrevDriveHome", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_golden_hour", label: "Golden Hour", file: "KadeRingGoldenHour", preview: "KadePrevGoldenHour", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_house_plants", label: "House Plants", file: "KadeRingHousePlants", preview: "KadePrevHousePlants", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_last_call", label: "Last Call", file: "KadeRingLastCall", preview: "KadePrevLastCall", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_lava_lamp", label: "Lava Lamp", file: "KadeRingLavaLamp", preview: "KadePrevLavaLamp", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_moon_roof", label: "Moon Roof", file: "KadeRingMoonRoof", preview: "KadePrevMoonRoof", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_night_owl", label: "Night Owl", file: "KadeRingNightOwl", preview: "KadePrevNightOwl", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_night_shift", label: "Night Shift", file: "KadeRingNightShift", preview: "KadePrevNightShift", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_old_photographs", label: "Old Photographs", file: "KadeRingOldPhotographs", preview: "KadePrevOldPhotographs", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_porch_swing", label: "Porch Swing", file: "KadeRingPorchSwing", preview: "KadePrevPorchSwing", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_rain_check", label: "Rain Check", file: "KadeRingRainCheck", preview: "KadePrevRainCheck", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_rooftop", label: "Rooftop", file: "KadeRingRooftop", preview: "KadePrevRooftop", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_screen_door", label: "Screen Door", file: "KadeRingScreenDoor", preview: "KadePrevScreenDoor", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_silk_robe", label: "Silk Robe", file: "KadeRingSilkRobe", preview: "KadePrevSilkRobe", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_slow_elevator", label: "Slow Elevator", file: "KadeRingSlowElevator", preview: "KadePrevSlowElevator", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_sundial", label: "Sundial", file: "KadeRingSundial", preview: "KadePrevSundial", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_tape_deck", label: "Tape Deck", file: "KadeRingTapeDeck", preview: "KadePrevTapeDeck", group: "Calm & lo-fi"),
        RingtoneOption(id: "ring_warm_coffee", label: "Warm Coffee", file: "KadeRingWarmCoffee", preview: "KadePrevWarmCoffee", group: "Calm & lo-fi"),
        // Soul & groove
        RingtoneOption(id: "ring_boom_bap", label: "Boom Bap", file: "KadeRingBoomBap", preview: "KadePrevBoomBap", group: "Soul & groove"),
        RingtoneOption(id: "ring_honey_dip", label: "Honey Dip", file: "KadeRingHoneyDip", preview: "KadePrevHoneyDip", group: "Soul & groove"),
        RingtoneOption(id: "ring_slow_jam", label: "Slow Jam", file: "KadeRingSlowJam", preview: "KadePrevSlowJam", group: "Soul & groove"),
        RingtoneOption(id: "ring_sunday_best", label: "Sunday Best", file: "KadeRingSundayBest", preview: "KadePrevSundayBest", group: "Soul & groove"),
        RingtoneOption(id: "ring_turntable", label: "Turntable", file: "KadeRingTurntable", preview: "KadePrevTurntable", group: "Soul & groove"),
        RingtoneOption(id: "ring_wind_up_crew", label: "Wind-Up Crew", file: "KadeRingWindUpCrew", preview: "KadePrevWindUpCrew", group: "Soul & groove"),
        // Bright & playful
        RingtoneOption(id: "ring_arcade_token", label: "Arcade Token", file: "KadeRingArcadeToken", preview: "KadePrevArcadeToken", group: "Bright & playful"),
        RingtoneOption(id: "ring_big_parade", label: "Big Parade", file: "KadeRingBigParade", preview: "KadePrevBigParade", group: "Bright & playful"),
        RingtoneOption(id: "ring_cartoon_hop", label: "Cartoon Hop", file: "KadeRingCartoonHop", preview: "KadePrevCartoonHop", group: "Bright & playful"),
        RingtoneOption(id: "ring_clockwork_tea", label: "Clockwork Tea", file: "KadeRingClockworkTea", preview: "KadePrevClockworkTea", group: "Bright & playful"),
        RingtoneOption(id: "ring_cobblestone", label: "Cobblestone", file: "KadeRingCobblestone", preview: "KadePrevCobblestone", group: "Bright & playful"),
        RingtoneOption(id: "ring_front_porch", label: "Front Porch", file: "KadeRingFrontPorch", preview: "KadePrevFrontPorch", group: "Bright & playful"),
        RingtoneOption(id: "ring_high_score", label: "High Score", file: "KadeRingHighScore", preview: "KadePrevHighScore", group: "Bright & playful"),
        RingtoneOption(id: "ring_jewelry_box", label: "Jewelry Box", file: "KadeRingJewelryBox", preview: "KadePrevJewelryBox", group: "Bright & playful"),
        RingtoneOption(id: "ring_paper_boat", label: "Paper Boat", file: "KadeRingPaperBoat", preview: "KadePrevPaperBoat", group: "Bright & playful"),
        RingtoneOption(id: "ring_roller_rink", label: "Roller Rink", file: "KadeRingRollerRink", preview: "KadePrevRollerRink", group: "Bright & playful"),
        RingtoneOption(id: "ring_toybox", label: "Toybox", file: "KadeRingToybox", preview: "KadePrevToybox", group: "Bright & playful"),
        // Driving & bold
        RingtoneOption(id: "ring_alarm_clock_trap", label: "Alarm Clock Trap", file: "KadeRingAlarmClockTrap", preview: "KadePrevAlarmClockTrap", group: "Driving & bold"),
        RingtoneOption(id: "ring_bird_flute", label: "Bird Flute", file: "KadeRingBirdFlute", preview: "KadePrevBirdFlute", group: "Driving & bold"),
        RingtoneOption(id: "ring_chess_club", label: "Chess Club", file: "KadeRingChessClub", preview: "KadePrevChessClub", group: "Driving & bold"),
        RingtoneOption(id: "ring_curtain_rise", label: "Curtain Rise", file: "KadeRingCurtainRise", preview: "KadePrevCurtainRise", group: "Driving & bold"),
        RingtoneOption(id: "ring_fast_lane", label: "Fast Lane", file: "KadeRingFastLane", preview: "KadePrevFastLane", group: "Driving & bold"),
        RingtoneOption(id: "ring_rosin", label: "Rosin", file: "KadeRingRosin", preview: "KadePrevRosin", group: "Driving & bold"),
        RingtoneOption(id: "ring_storm_chaser", label: "Storm Chaser", file: "KadeRingStormChaser", preview: "KadePrevStormChaser", group: "Driving & bold"),
        // World & cinematic
        RingtoneOption(id: "ring_bamboo_grove", label: "Bamboo Grove", file: "KadeRingBambooGrove", preview: "KadePrevBambooGrove", group: "World & cinematic"),
        RingtoneOption(id: "ring_caravan", label: "Caravan", file: "KadeRingCaravan", preview: "KadePrevCaravan", group: "World & cinematic"),
        RingtoneOption(id: "ring_dragon_boat", label: "Dragon Boat", file: "KadeRingDragonBoat", preview: "KadePrevDragonBoat", group: "World & cinematic"),
        RingtoneOption(id: "ring_jade_dragon", label: "Jade Dragon", file: "KadeRingJadeDragon", preview: "KadePrevJadeDragon", group: "World & cinematic"),
        RingtoneOption(id: "ring_misty_river", label: "Misty River", file: "KadeRingMistyRiver", preview: "KadePrevMistyRiver", group: "World & cinematic"),
        RingtoneOption(id: "ring_morning_raga", label: "Morning Raga", file: "KadeRingMorningRaga", preview: "KadePrevMorningRaga", group: "World & cinematic"),
        RingtoneOption(id: "ring_paper_lantern", label: "Paper Lantern", file: "KadeRingPaperLantern", preview: "KadePrevPaperLantern", group: "World & cinematic"),
        RingtoneOption(id: "ring_sand_drum", label: "Sand Drum", file: "KadeRingSandDrum", preview: "KadePrevSandDrum", group: "World & cinematic"),
        RingtoneOption(id: "ring_tea_garden", label: "Tea Garden", file: "KadeRingTeaGarden", preview: "KadePrevTeaGarden", group: "World & cinematic"),
        RingtoneOption(id: "ring_weeping_strings", label: "Weeping Strings", file: "KadeRingWeepingStrings", preview: "KadePrevWeepingStrings", group: "World & cinematic"),
    ]

    /// Group order for the picker sections — a VoiceOver user jumps these
    /// by heading instead of flicking 73 rows.
    static let ringtoneGroups: [String] = [
        "Classics", "Dreamy & gentle", "Calm & lo-fi", "Soul & groove",
        "Bright & playful", "Driving & bold", "World & cinematic",
    ]
}
