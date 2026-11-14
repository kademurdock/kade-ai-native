import SwiftUI
import UIKit

/// Tellavision "Follow along" (Nov 14 2026): the sheet (design 5.3, "The sheet").
///
/// Top to bottom: the heading (Follow along, then the film's name); the
/// status line, always the last thing said and NOT a live region, so
/// VoiceOver does not repeat it; the privacy sentence, right above the Start
/// button, because pressing Start after it is her consent; the big button,
/// ONE button that only changes its words (Start listening, Pause
/// descriptions, Turn descriptions on, Listen again, Open Settings), so the
/// control under VoiceOver is never taken away; Where am I?; Stop; the line
/// being spoken, as text for anyone watching with her, hidden from VoiceOver
/// so it is not said twice; a closed Settings group; Copy test report; the
/// AI warning. Focus is never moved. Magic Tap pauses and resumes the
/// descriptions.
///
/// NO LAZY CONTAINER (the Part-87 freeze law): the words here change while
/// VoiceOver may be reading them. FollowAlongTests checks the source.
///
/// Closing the sheet (Done, or the escape gesture) stops listening first, with
/// its sentence, so the microphone is never left on behind a closed screen.
struct FollowAlongSheet: View {
    @ObservedObject var player: FollowAlongPlayer
    let track: FollowStoredTrack
    /// Stops the screen's other sounds (listen-while-made, a voice sample)
    /// before the microphone opens.
    let stopOthers: () -> Void

    @ObservedObject private var feedback = FeedbackPrefs.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @State private var settingsOpen = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heading
                    Text(player.status)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(FollowWords.privacy)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    mainButton
                    otherButtons
                    // For anyone watching with her; VoiceOver hears it spoken already.
                    Text(player.nowSaying)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityHidden(true)
                    DisclosureGroup("Settings", isExpanded: $settingsOpen) {
                        settingsRows
                    }
                    .accessibilityHint("Voice, speed, how much to say, sounds, the chime, and timing.")
                    Button("Copy test report") {
                        player.noteVoiceOver()
                        player.copyReport()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Copies numbers only, like how long it took to find your place, so you can paste them into a message.")
                    if let warning = player.trackWarning {
                        Text(warning)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityHint("Closes Follow along. If it is listening, it stops first and turns the microphone off.")
                }
            }
        }
        .accessibilityAction(.magicTap) {
            if player.phase == .listening { player.toggleDescriptions() }
        }
        .onAppear { player.open(track, stopOthers: stopOthers) }
        .onDisappear { player.close() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            player.appBecameActive()
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Follow along")
                .font(.title2.bold())
            Text(track.title)
                .font(.title3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: The buttons

    private var mainButton: some View {
        Button {
            player.noteVoiceOver()
            Task { await player.mainButton() }
        } label: {
            Text(mainLabel)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(KadeCardButtonStyle())
        .disabled(!mainEnabled)
        .accessibilityLabel(mainLabel)
        .accessibilityHint(mainHint)
    }

    private var mainLabel: String {
        switch player.phase {
        case .listening: return player.descriptionsOn ? "Pause descriptions" : "Turn descriptions on"
        case .stoppedByCall: return "Listen again"
        case .micDenied: return "Open Settings"
        case .closed, .preparing: return "Getting ready"
        case .ready, .stopping, .failed: return "Start listening"
        }
    }

    private var mainEnabled: Bool {
        switch player.phase {
        case .ready, .listening, .stoppedByCall, .micDenied: return true
        case .closed, .preparing, .stopping, .failed: return false
        }
    }

    private var mainHint: String {
        switch player.phase {
        case .ready:
            return "Turns on the microphone and listens for the film. Then start the film on your TV."
        case .listening:
            return player.descriptionsOn
                ? "Stops the descriptions. The phone keeps listening, so it stays in step. Magic Tap does the same."
                : "Speaks the descriptions again, from where the film is now."
        case .stoppedByCall:
            return "Turns the microphone on again and finds your place."
        case .micDenied:
            return "Opens Kade-AI in the Settings app, where Microphone is."
        case .closed, .preparing:
            return "The track is getting ready."
        case .stopping, .failed:
            return "Not available right now."
        }
    }

    private var otherButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Where am I?") { player.whereAmI() }
                .buttonStyle(.bordered)
                .disabled(player.phase != .listening)
                .accessibilityHint("Says how far into the film you are, or that it is still listening.")
            Button("Stop") { player.stop() }
                .buttonStyle(.bordered)
                .disabled(player.phase != .listening)
                .accessibilityHint("Turns off the microphone and stops the descriptions.")
        }
    }

    // MARK: Settings (design 5.3)

    private var settingsRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Voice: your phone's own voice. With VoiceOver on, it is your VoiceOver voice.")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Use the recorded narrator") {}
                    .buttonStyle(.bordered)
                    .disabled(!player.narratorAvailable)
                    .accessibilityHint("Not available yet. This track has no recorded narrator, so your phone's own voice speaks.")
            }
            Picker("Speed", selection: speedBinding) {
                Text(FollowAlongSettings.speedWords(nil, voiceOver: voiceOverOn)).tag(0.0)
                ForEach(FollowAlongSettings.speeds, id: \.self) { speed in
                    Text(FollowAlongSettings.speedWords(speed, voiceOver: voiceOverOn)).tag(speed)
                }
            }
            .pickerStyle(.menu)
            .accessibilityHint("Same as VoiceOver uses your VoiceOver voice and speed. A number uses the phone's standard voice at that speed.")
            Picker("How much to say", selection: amountBinding) {
                Text("Everything that fits").tag(FollowAlongSettings.Amount.everything)
                Text("Important lines only").tag(FollowAlongSettings.Amount.important)
            }
            .pickerStyle(.menu)
            .accessibilityHint("Important lines only leaves out the smallest details.")
            Toggle("Sounds when it finds or loses the film", isOn: soundsBinding)
                .accessibilityHint("Two rising notes when it finds your place, two falling notes when it loses the film or the film pauses.")
            Toggle("Chime when a line does not fit", isOn: chimeBinding)
                .accessibilityHint("A soft chime means pause your TV to hear more. While the film is paused, the phone reads the lines it held.")
            Stepper(value: nudgeBinding, in: -1...1, step: 0.1) {
                Text("Timing: \(FollowAlongSettings.nudgeWords(player.settings.nudge))")
            }
            .accessibilityValue(FollowAlongSettings.nudgeWords(player.settings.nudge))
            .accessibilityHint("Starts each line earlier or later, a tenth of a second at a time, up to one second. Earlier helps when earbuds make lines late.")
        }
        .padding(.top, 8)
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { player.settings.speed ?? 0 },
            set: { value in player.settings.speed = value > 0 ? value : nil }
        )
    }

    private var amountBinding: Binding<FollowAlongSettings.Amount> {
        Binding(
            get: { player.settings.amount },
            set: { value in player.settings.amount = value }
        )
    }

    private var soundsBinding: Binding<Bool> {
        Binding(
            get: { player.settings.soundsOn(soundEffects: feedback.soundEffects) },
            set: { value in player.settings.sounds = value }
        )
    }

    private var chimeBinding: Binding<Bool> {
        Binding(
            get: { player.settings.heldChime },
            set: { value in player.settings.heldChime = value }
        )
    }

    private var nudgeBinding: Binding<Double> {
        Binding(
            get: { player.settings.nudge },
            set: { value in player.settings.nudge = FollowAlongSettings.clampNudge(value) }
        )
    }
}
