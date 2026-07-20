import SwiftUI
import UIKit

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
    let apiClient: KadeAPIClient

    @EnvironmentObject private var voiceService: VoiceService
    @EnvironmentObject private var appearance: AppearancePreferences
    @EnvironmentObject private var feedback: FeedbackPrefs

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

    var body: some View {
        List {
            Section {
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

                speedRow
            } header: {
                Text("Speech")
            } footer: {
                Text("Voice message speed applies to every conversation and call from here on -- you can still change it from any single conversation too, and it remembers your last pick.")
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

                Picker("Line spacing", selection: $appearance.lineSpacing) {
                    ForEach(AppearancePreferences.LineSpacingLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .accessibilityHint("Changes the space between lines of message text.")
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

                Toggle(isOn: $feedback.forceReduceMotion) {
                    Text("Reduce motion")
                }
                .accessibilityHint("Turns off the app's decorative animations even if your iPhone's own Reduce Motion setting is off. Your system Reduce Motion setting is always honored on top of this.")

                Button {
                    Earcons.shared.play(.messageReceived)
                    UIAccessibility.post(notification: .announcement, argument: "Test sound played.")
                } label: {
                    Label("Play a test sound", systemImage: "speaker.wave.2")
                }
                .buttonStyle(.plain)
                .disabled(!feedback.soundEffects)
                .accessibilityHint("Plays the reply sound so you can hear how loud the effects are.")
            } header: {
                Text("Feedback")
            } footer: {
                Text("Sound effects and haptics are on by default. Sounds are brief and quiet, and always play alongside VoiceOver rather than interrupting it.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingPronunciationDictionary) {
            PronunciationDictionaryView(apiClient: apiClient)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voice message speed")
        .accessibilityValue(VoiceService.rateSpokenLabel(voiceService.playbackRate))
        .accessibilityHint("Double-tap to change how fast voice messages and Spotter calls play back.")
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
