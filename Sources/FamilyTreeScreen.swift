import SwiftUI

// MARK: - Family history: the family tree (placeholder)
//
// DESIGN 1.3 and 4.5 (Climb, Chart and List, centred on `focus`; nil = the
// viewer) are a later step of the build.

struct FamilyTreeScreen: View {
    let apiClient: KadeAPIClient
    let focus: String?
    let name: String

    var body: some View {
        FamilyPlaceholderScreen(title: FamilyRoute.tree(focus: focus, name: name).fallbackTitle)
    }
}
