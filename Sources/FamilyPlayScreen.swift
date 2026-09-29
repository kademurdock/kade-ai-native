import SwiftUI

// MARK: - Family history: How are you related? (placeholder)
//
// DESIGN 1.12 (five mixed rounds, no timers, the best score per account) is
// the last step of the build.

struct FamilyPlayScreen: View {
    let apiClient: KadeAPIClient

    var body: some View {
        FamilyPlaceholderScreen(title: FamilyRoute.play.fallbackTitle)
    }
}
