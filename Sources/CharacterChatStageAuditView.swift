#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit

/// Exercises the same stage used by ConversationDetailView. Surrounding text
/// and composer are placeholders; no conversation, provider or audio is started.
struct CharacterChatStageAuditView: View {
    @EnvironmentObject private var agents: AgentsService
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.verticalSizeClass) private var verticalClass
    @AppStorage("kadeVoicePortraits") private var portraits = true
    @State private var ready = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private let person = CharacterAuditPerson(rawValue:
        ProcessInfo.processInfo.environment["KADE_CHAT_LAYOUT_CHARACTER"] ?? "") ?? .harley
    private let variant = ProcessInfo.processInfo.environment["KADE_CHAT_LAYOUT_VARIANT"] ?? "normal"
    private var side: Double {
        CharacterStageLayout.chatSide(height: Double(UIScreen.main.bounds.height),
            keyboard: variant == "keyboard", compactHeight: verticalClass == .compact,
            accessibilityText: textSize.isAccessibilitySize)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Talking to " + person.name).font(.headline).padding(8)
            if ready && portraits {
                CharacterConversationStage(agentID: person.agentID, name: person.name,
                    playing: false, side: side, level: { 0 }, presentation: { .idle })
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Offline stage layout check").font(.headline)
                    Text("This uses the production conversation stage. The transcript and composer in this fixture are placeholders.")
                    Text("No audio, microphone, sign-in or message request is started.")
                }.padding()
            }
            HStack {
                TextField("Message", text: $draft).textFieldStyle(.roundedBorder).focused($focused)
                Button("Send") {}.disabled(true)
            }.padding(8)
        }
        .task {
            agents.seedCharacterAudit()
            portraits = variant != "off"
            UserDefaults.standard.set(variant == "still", forKey: "kade.feedback.reduceMotion")
            ready = true
            focused = variant == "keyboard"
            try? await Task.sleep(nanoseconds: 600_000_000)
            let path = "/images/" + person.avatarFile
            let receipt: [String: Any] = ["character": person.rawValue,
                "agentID": person.agentID, "avatarFile": person.avatarFile,
                "variant": variant, "stagePoints": side, "portraitEnabled": portraits,
                "appReduceMotion": variant == "still", "sharedProductionStage": true,
                "productionPuppetRegistered": CharacterBustArtwork.approved(stage: true,
                    side: 208, agentID: person.agentID, avatarPath: path) != nil,
                "puppetEligibleAtSize": portraits && CharacterBustArtwork.approved(stage: true,
                    side: side, agentID: person.agentID, avatarPath: path) != nil,
                "placeholderTranscript": true, "completeConversationScreen": false,
                "audioStarted": false, "microphoneStarted": false]
            let target = FileManager.default.urls(for: .documentDirectory,
                in: .userDomainMask)[0].appendingPathComponent("chat-stage-ready.json")
            if let data = try? JSONSerialization.data(withJSONObject: receipt) {
                try? data.write(to: target, options: .atomic)
            }
        }
    }
}
#endif
