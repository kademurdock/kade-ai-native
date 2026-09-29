import SwiftUI

// MARK: - Family history: the lists (placeholder)
//
// DESIGN 1.9 to 1.11: everyone in the tree (with search), Discoveries,
// Family mysteries (behind their heads-up) and the stories list are a later
// step of the build.

/// Which list the screen shows.
enum FamilyListMode: String, Hashable {
    case people, stories, discoveries, mysteries
}

struct FamilyListScreen: View {
    let apiClient: KadeAPIClient
    let mode: FamilyListMode

    var body: some View {
        FamilyPlaceholderScreen(title: route.fallbackTitle)
    }

    private var route: FamilyRoute {
        switch mode {
        case .people: return .people
        case .stories: return .stories
        case .discoveries: return .discoveries
        case .mysteries: return .mysteries
        }
    }
}
