import SwiftUI

// MARK: - Family history: one story (placeholder)
//
// DESIGN 1.9 and 4.9 (Who's who, the short version, the research banner, the
// story's blocks, Listen with sentence captions) are a later step of the
// build.

struct FamilyStoryScreen: View {
    let apiClient: KadeAPIClient
    let slug: String
    let title: String

    var body: some View {
        FamilyPlaceholderScreen(title: FamilyRoute.story(slug: slug, title: title).fallbackTitle)
    }
}
