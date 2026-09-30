import SwiftUI
import UIKit

// MARK: - Family history: the stories (Sep 29 2026)
//
// DESIGN 1.9, GET /stories. Each story is ONE row: its title, how long it
// takes ("About 18 minutes"), and the Research pill when it rests on
// research findings (said as "research finding"). A second section, "From
// the tree", lists the clippings and write-ups that have words in them;
// each opens in the photo viewer, where "Read the text" shows the words.
// Closing the viewer hands VoiceOver back to the clipping it came from.

struct FamilyStoriesScreen: View {
    let apiClient: KadeAPIClient

    @State private var answer: FHStories?
    @State private var failure: String?
    @State private var viewer: FamilyViewerRequest?
    @State private var returnKey: String?
    @AccessibilityFocusState private var focusKey: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FamilyHeading(text: "Stories", level: .h1, focusOnArrival: true)
                content
            }
            .padding()
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Stories")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(force: false) }
        .refreshable { await load(force: true) }
        .background {
            Color.clear.fullScreenCover(item: $viewer, onDismiss: { returnFocus() }) { request in
                FamilyPhotoViewer(request: request)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let answer {
            lists(answer)
        } else if let failure {
            FamilyTryAgain(message: failure) {
                Task { await load(force: true) }
            }
        } else {
            FamilyLoadingLine()
        }
    }

    @ViewBuilder
    private func lists(_ answer: FHStories) -> some View {
        if answer.stories.isEmpty && answer.clippings.isEmpty {
            Text("There are no stories yet.")
                .foregroundStyle(.secondary)
        }
        ForEach(Array(answer.stories.enumerated()), id: \.offset) { pair in
            FamilyStoryRow(story: pair.element)
                .buttonStyle(KadeCardButtonStyle())
        }
        if !answer.clippings.isEmpty {
            FamilyHeading(text: "From the tree", level: .h2)
            ForEach(Array(answer.clippings.enumerated()), id: \.offset) { pair in
                clippingRow(pair.element, index: pair.offset)
            }
        }
    }

    // MARK: Clippings

    private func clippingRow(_ clipping: FHClipping, index: Int) -> some View {
        let key: String = "clipping-\(index)"
        return Button {
            open(clipping, key: key)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "newspaper")
                    .font(.title3)
                    .foregroundStyle(.brown)
                    .frame(width: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(clipping.title ?? "A clipping")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let names = Self.names(clipping.people) {
                        Text(names)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(KadeCardButtonStyle())
        .accessibilityLabel(Self.spoken(clipping))
        .accessibilityHint("Opens it, with its words.")
        .accessibilityInputLabels([clipping.title ?? "Clipping"])
        .accessibilityFocused($focusKey, equals: key)
    }

    /// "Dan Example, your grandfather; Hugo Example, your great-grandfather".
    static func names(_ people: [FHPerson]) -> String? {
        let words: [String] = people.map { FamilyViewerPanel.nameAndTerm($0) }.filter { !$0.isEmpty }
        return words.isEmpty ? nil : words.joined(separator: "; ")
    }

    static func spoken(_ clipping: FHClipping) -> String {
        let title: String = clipping.title ?? "A clipping"
        guard let names = names(clipping.people) else { return title }
        return title + ". " + names
    }

    /// The clipping as a picture the viewer can open (it signs the picture
    /// and reads its words from /media/:id/info).
    static func image(_ clipping: FHClipping) -> FHImage {
        let title: String = clipping.title ?? ""
        return FHImage(id: clipping.mediaId ?? "", category: FHImageCategory.story.rawValue,
                       short: title, alt: title, hasText: true, caption: title, people: clipping.people)
    }

    private func open(_ clipping: FHClipping, key: String) {
        guard FamilyAccessRules.nonEmpty(clipping.mediaId) != nil else { return }
        returnKey = key
        viewer = FamilyViewerRequest(items: [Self.image(clipping)], start: 0)
    }

    private func returnFocus() {
        guard let key = returnKey else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            focusKey = key
        }
    }

    // MARK: Loading

    @MainActor
    private func load(force: Bool) async {
        if !force, answer != nil { return }
        do {
            let fresh = try await FamilyHistoryService.shared.stories()
            answer = fresh
            failure = nil
        } catch {
            if LibraryLoad.cancelled(error) { return }
            let message: String = (error as? FamilyFailure)?.message ?? FamilyFailure.offline.message
            if answer == nil {
                failure = message
            } else {
                FamilyAnnounce.say(message)
            }
        }
    }
}

/// One story: its title, how long it takes, and the Research pill.
struct FamilyStoryRow: View {
    let story: FHStoryRow

    private var title: String { story.title ?? story.slug }

    private var spoken: String {
        var parts: [String] = [title]
        if let detail = FamilyAccessRules.nonEmpty(story.detail) { parts.append(detail) }
        if story.research == true { parts.append("research finding, not proven by records") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        NavigationLink(value: HomeRoute.library(.family(.story(slug: story.slug, title: title)))) {
            HStack(spacing: 12) {
                Image(systemName: "book")
                    .font(.title3)
                    .foregroundStyle(.brown)
                    .frame(width: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if let detail = FamilyAccessRules.nonEmpty(story.detail) {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if story.research == true {
                            FamilyResearchPill()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityLabel(spoken)
        .accessibilityHint("Opens the story. You can listen to it there.")
        .accessibilityInputLabels([title])
    }
}
