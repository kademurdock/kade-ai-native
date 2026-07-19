import SwiftUI

@main
struct KadeAIApp: App {
    @StateObject private var auth = AuthService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .task { await auth.restore() }   // restore a saved session at launch
        }
    }
}
