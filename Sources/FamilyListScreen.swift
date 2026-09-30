import SwiftUI

// MARK: - Family history: the lists (Sep 29 2026)
//
// One route per list, each its own screen (so any can move to a later
// build without touching the others):
// - Everyone in the tree (DESIGN 1.11), with search;
// - Stories (1.9);
// - Discoveries and Family mysteries (1.10), FamilyFindingsScreen.swift.

/// Which list the screen shows.
enum FamilyListMode: String, Hashable {
    case people, stories, discoveries, mysteries
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
        case .discoveries:
            FamilyFindingsScreen(apiClient: apiClient, mysteries: false)
        case .mysteries:
            FamilyFindingsScreen(apiClient: apiClient, mysteries: true)
        }
    }
}
