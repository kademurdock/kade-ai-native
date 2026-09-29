import SwiftUI

// MARK: - Family history: "Your family in 60 seconds" (placeholder)
//
// DESIGN 1.2 item 2 (swipeable cards for sight, a plain list under
// VoiceOver) is a later step of the build.

struct FamilyReelView: View {
    let apiClient: KadeAPIClient

    var body: some View {
        FamilyPlaceholderScreen(title: FamilyRoute.reel.fallbackTitle)
    }
}
