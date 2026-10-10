#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Manual, offline visual review. Synthetic motion is explicitly labelled;
/// the automatic audit separately drives this compositor from rendered PCM.
struct CharacterPuppetLabView: View {
    @EnvironmentObject private var agents: AgentsService
    @State private var character = CharacterAuditPerson.harley
    @State private var mode = Mode.listening
    @State private var expression = CharacterExpression.warm
    @State private var started = Date()
    @State private var still = false
    @State private var side = 208.0
    @State private var ready = false
    @AppStorage("kade.della.articulatedReview") private var articulatedDella = false

    private enum Mode: String, CaseIterable {
        case idle = "Resting", listening = "Listening", thinking = "Thinking", speaking = "Speaking"
        var activity: CharacterActivity {
            switch self {
            case .idle: return .idle
            case .listening: return .listening
            case .thinking: return .thinking
            case .speaking: return .speaking
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(character.auditName + " puppet study").font(.title).accessibilityAddTraits(.isHeader)
                Text("Offline simulator preview using the conversation and call renderer. Speech movement is synthetic and silent; it is not " + character.name + "’s voice.")
                Picker("Character", selection: $character) {
                    ForEach(CharacterAuditPerson.allCases, id: \.self) { Text($0.auditName).tag($0) }
                }.pickerStyle(.menu)
                if ready {
                    CharacterPortraitView(agentID: character.agentID, name: character.name,
                    playing: mode == .speaking && !still,
                    level: { simulatedLevel }, listening: mode == .listening,
                    presentation: { CharacterPresentation(activity: mode.activity,
                        expression: mode == .speaking ? expression : .neutral,
                        elapsed: Date().timeIntervalSince(started)) },
                    stage: true, side: side, motionPaused: still,
                    dellaArticulatedReview: articulatedDella && character == .della)
                    .frame(maxWidth: .infinity)
                }
                Text(description)
                Picker("Conversation state", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu)
                Picker("Delivery", selection: $expression) {
                    ForEach(CharacterExpression.allCases, id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }.pickerStyle(.menu)
                Picker("Stage size", selection: $side) {
                    ForEach([84.0, 104, 132, 160, 208], id: \.self) { Text("\(Int($0)) points").tag($0) }
                }.pickerStyle(.menu)
                Toggle("Keep the character still", isOn: $still)
                if character == .della {
                    Toggle("Preview Della’s articulated body study", isOn: $articulatedDella)
                    if articulatedDella {
                        Text("Optional simulator body preview for this lab and call/chat screens. The original face keeps its size above two attached sleeves and hands. The review asset must be staged; editing, crowded controls and compact screens use the shorter portrait. Phone review is pending.")
                            .font(.footnote)
                    }
                }
                Button("Interrupt and listen") { mode = .listening; started = Date() }
                if let appearance = CharacterAppearance.description(agentID: character.agentID,
                        avatarPath: "/images/" + character.avatarFile) {
                    Text(appearance)
                }
                Text("Compact stages use the portrait. This preview follows the app’s portrait and motion settings. VoiceOver reads these controls and descriptions, never individual animation frames.")
                    .font(.footnote)
            }.padding()
        }
        .onAppear { agents.seedCharacterAudit(); ready = true }
        .onChange(of: mode) { _, _ in started = Date() }
        .onChange(of: character) { _, _ in started = Date() }
    }

    private var simulatedLevel: Double {
        guard mode == .speaking, !still else { return 0 }
        let time = Date().timeIntervalSince(started)
        // Audible output is deliberately absent from this manual art study.
        let phrase = time.truncatingRemainder(dividingBy: 3)
        return phrase > 2.4 ? 0 : 0.035 + 0.11 * abs(sin(time * 5.4))
    }

    private var description: String {
        if still { return "Still view. Mouth and body movement are stopped." }
        switch mode {
        case .idle: return "Resting: gentle breathing and occasional blinks."
        case .listening: return "Listening: an interested expression and a small head inclination."
        case .thinking: return "Thinking: a thoughtful expression and a slight head tilt."
        case .speaking: return "Speaking study: changing mouth shapes, expression and small head movements, with pauses between simulated phrases."
        }
    }
}
#endif
