import SwiftUI

// MARK: - Family history: Home (placeholder)
//
// DESIGN 1.2 (hero, faces, "Your family in 60 seconds", featured, news, the
// four tiles, More, Coming soon, footnote) is the next step of the build.
// Until then the route opens this placeholder, so navigation is complete.

struct FamilyHomeView: View {
    let apiClient: KadeAPIClient

    var body: some View {
        FamilyPlaceholderScreen(title: FamilyRoute.home.fallbackTitle)
    }
}
