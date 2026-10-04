import SwiftUI

// MARK: - Family history: the lists (Sep 29 2026)
//
// One route per list, each its own screen (so any can move to a later
// build without touching the others):
// - Everyone in the tree (DESIGN 1.11), with search;
// - Stories (1.9).

/// Which list the screen shows.
enum FamilyListMode: String, Hashable {
    case people, stories
}

struct FamilyListScreen: View {
    let apiClient: KadeAPIClient
    let mode: FamilyListMode

    var body: some View {
        switch mode {
        case .people:
            FamilyPeopleScreen(apiClient: apiClient)
        case .stories:
            FamilyStoriesScreen(apiClient: apiClient)
        }
    }
}
