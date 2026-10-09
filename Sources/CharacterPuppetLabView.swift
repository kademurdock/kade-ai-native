#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Manual, offline visual review. Synthetic motion is explicitly labelled;
/// the automatic audit separately drives this compositor from rendered PCM.
struct CharacterPuppetLabView: View {
    @EnvironmentObject private var agents: AgentsService
    @State private var character = ReviewCharacter.harley
    @State private var mode = Mode.listening
    @State private var expression = CharacterExpression.warm
    @State private var started = Date()
    @State private var still = false
    @State private var side = 208.0
    @State private var ready = false

    private enum ReviewCharacter: String, CaseIterable {
        case harley = "Harley", lilly = "Lilly"

        var agentID: String {
            switch self {
            case .harley: return CharacterMotion.harleyID
            case .lilly: return CharacterMotion.lillyID
            }
        }

        var appearance: String {
            switch self {
            case .harley:
                return "Harley has swept-back brown hair, a short beard and a denim shirt over white. His head moves independently of his shoulders. The close view shows his head and collar; it does not animate his arms. At compact sizes the familiar portrait returns."
            case .lilly:
                return "Lilly has long chestnut hair, floral earrings and a lilac hoodie, with an orange tabby on each shoulder. Her head moves independently of the hoodie. Both cats keep their original appearance and remain still. Her arms do not move independently. At compact sizes the familiar portrait returns."
            }
        }
    }

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
                Text(character.rawValue + " puppet study").font(.title).accessibilityAddTraits(.isHeader)
                Text("Offline simulator preview. Speech movement is synthetic and silent; it is not " + character.rawValue + "’s voice.")
                Picker("Character", selection: $character) {
                    ForEach(ReviewCharacter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                if ready {
                    CharacterPortraitView(agentID: character.agentID, name: character.rawValue,
                    playing: mode == .speaking && !still,
                    level: { simulatedLevel }, listening: mode == .listening,
                    presentation: { CharacterPresentation(activity: mode.activity,
                        expression: mode == .speaking ? expression : .neutral,
                        elapsed: Date().timeIntervalSince(started)) },
                    stage: true, side: side, reviewBust: true, motionPaused: still)
                    .frame(maxWidth: .infinity)
                }
                Text(description)
                Picker("Conversation state", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu)
                Picker("Delivery", selection: $expression) {
                    ForEach([CharacterExpression.warm, .amused, .serious, .concerned, .skeptical, .surprised], id: \.self) {
                        Text($0.rawValue.capitalized).tag($0)
                    }
                }.pickerStyle(.menu)
                Picker("Stage size", selection: $side) {
                    ForEach([84.0, 104, 160, 208], id: \.self) { Text("\(Int($0)) points").tag($0) }
                }.pickerStyle(.menu)
                Toggle("Keep the character still", isOn: $still)
                Button("Interrupt and listen") { mode = .listening; started = Date() }
                Text(character.appearance)
                Text("This experimental art is not enabled in conversations or calls. VoiceOver reads these controls and descriptions, never individual animation frames.")
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
