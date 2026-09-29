import SwiftUI

// MARK: - Family history: photos and records (placeholder)
//
// DESIGN 1.8 (Photos first, filter and sort, an eager grid of 48 per page,
// Play slideshow) is a later step of the build.

struct FamilyGalleryScreen: View {
    let apiClient: KadeAPIClient
    let route: FamilyGalleryRoute

    var body: some View {
        FamilyPlaceholderScreen(title: FamilyRoute.gallery(route).fallbackTitle)
    }
}
