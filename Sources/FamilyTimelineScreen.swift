import SwiftUI

// MARK: - Family history: where and when (placeholder)
//
// DESIGN 1.6 ("Through the years / On a map"; `map` opens the map segment)
// is the last step of the build.

struct FamilyTimelineScreen: View {
    let apiClient: KadeAPIClient
    let map: Bool

    var body: some View {
        FamilyPlaceholderScreen(title: FamilyRoute.whereWhen(map: map).fallbackTitle)
    }
}
