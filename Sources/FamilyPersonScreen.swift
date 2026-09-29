import SwiftUI

// MARK: - Family history: one person (placeholder)
//
// DESIGN 1.4 (header, life in a nutshell, how you're related, pictures,
// life, family, records, grave, findings, sources) is a later step of the
// build. The route carries the name, so the heading is real at the push.

struct FamilyPersonScreen: View {
    let apiClient: KadeAPIClient
    let route: FamilyPersonRoute

    var body: some View {
        FamilyPlaceholderScreen(title: FamilyRoute.person(route).fallbackTitle)
    }
}
