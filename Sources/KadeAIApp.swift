import SwiftUI

@main
struct KadeAIApp: App {
    @StateObject private var auth: AuthService
    @StateObject private var conversationsService: ConversationsService
    @StateObject private var messageSendingService: MessageSendingService
    @StateObject private var agentsService: AgentsService
    @StateObject private var voiceService: VoiceService

    init() {
        // One shared client so auth calls and data calls (and, as of
        // Phase 3, the chat send/stream calls, Phase 4's agent list, and
        // now Phase 5's speech endpoints) obey the same request-pacing
        // clock (see KadeAPIClient's doc comment).
        let client = KadeAPIClient()
        _auth = StateObject(wrappedValue: AuthService(client: client))
        _conversationsService = StateObject(wrappedValue: ConversationsService(client: client))
        _messageSendingService = StateObject(wrappedValue: MessageSendingService(client: client))
        _agentsService = StateObject(wrappedValue: AgentsService(client: client))
        _voiceService = StateObject(wrappedValue: VoiceService(client: client))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .environmentObject(conversationsService)
                .environmentObject(messageSendingService)
                .environmentObject(agentsService)
                .environmentObject(voiceService)
                .task { await auth.restore() }   // restore a saved session at launch
        }
    }
}
