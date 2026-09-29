import SwiftUI

// MARK: - Family history: your DNA (placeholder)
//
// DESIGN 1.7 (the owner's test for full siblings, family mysteries behind
// their heads-up, the paper fan, birthplaces in counts, born across the
// ocean, compare) is a later step of the build.

struct FamilyDNAScreen: View {
    let apiClient: KadeAPIClient
    /// The viewer, their spouse or a child (changes only the on-paper parts).
    let forId: String?

    var body: some View {
        FamilyPlaceholderScreen(title: FamilyRoute.dna(forId: forId).fallbackTitle)
    }
}
