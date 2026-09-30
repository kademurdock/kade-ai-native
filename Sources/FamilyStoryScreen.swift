import SwiftUI
import UIKit

// MARK: - Family history: one story (Sep 29 2026)
//
// DESIGN 1.9, one GET /story/:slug, every word the server's. Top to bottom:
// the title (h1), how long it takes, the research banner when the story
// rests on research findings, Listen, "Who's who for you" (the stories are
// written in the owner's voice, "my grandmother", so each person's term for
// this viewer is shown), "The short version" (three lines), then the story:
// the server's blocks as real headings, paragraphs, list items and quotes,
// each paragraph its own element. Source numbers are small links that jump
// to the numbered Sources list at the end.
//
// Listen (FamilyStoryPlayer.swift): a bar at the bottom with the sentence
// being read on a solid caption strip (two lines at most), Back one part,
// Play or Pause, Forward one part, the speed, and Stop. The paragraph being
// read is highlighted, and the text scrolls to follow it unless motion is
// reduced. The caption strip is drawn for anyone watching but hidden from
// VoiceOver, which hears the voice itself (the described-video captions
// rule), so nothing is ever read over the story. Listen stops when the story
// closes and pauses when the app goes to the background.

struct FamilyStoryScreen: View {
    let apiClient: KadeAPIClient
    let slug: String
    let title: String

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @KadeMotionPolicy private var motionAllowed: Bool
    @ObservedObject private var player = FamilyStoryPlayer.shared
    @State private var story: FHStory?
    @State private var failure: String?
    /// For every part and sentence, the block it is read from.
    @State private var cueBlocks: [[Int]] = []
    @AccessibilityFocusState private var focusKey: String?

    private var shownTitle: String {
        FamilyAccessRules.nonEmpty(story?.title) ?? FamilyAccessRules.nonEmpty(title) ?? "Story"
    }

    private var listening: Bool { player.isLoaded(slug) }

    /// The block being read, when this story is playing or paused.
    private var activeBlock: Int? {
        guard listening, let cue = player.cue, cueBlocks.indices.contains(cue.part) else { return nil }
        let row: [Int] = cueBlocks[cue.part]
        guard row.indices.contains(cue.index), row[cue.index] >= 0 else { return nil }
        return row[cue.index]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FamilyHeading(text: shownTitle, level: .h1, focusOnArrival: true)
                    content(proxy)
                }
                .padding()
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: activeBlock) { _, block in
                follow(block, proxy: proxy)
            }
        }
        .navigationTitle(shownTitle)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { listenBar }
        .task { await load(force: false) }
        .refreshable { await load(force: true) }
        .onDisappear {
            if player.isLoaded(slug) { player.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, player.isLoaded(slug) { player.pause() }
        }
    }

    @ViewBuilder
    private var listenBar: some View {
        if listening {
            FamilyListenBar(player: player)
        }
    }

    @ViewBuilder
    private func content(_ proxy: ScrollViewProxy) -> some View {
        if let story {
            storyBody(story, proxy: proxy)
        } else if let failure {
            FamilyTryAgain(message: failure) {
                Task { await load(force: true) }
            }
        } else {
            FamilyLoadingLine()
        }
    }

    @ViewBuilder
    private func storyBody(_ story: FHStory, proxy: ScrollViewProxy) -> some View {
        Group {
            FamilyStoryIntro(story: story, listening: listening) {
                player.play(slug: slug, chunks: story.chunks)
            }
            if !story.whoswho.isEmpty {
                FamilyWhosWho(people: story.whoswho)
            }
            if !story.short.isEmpty {
                FamilyShortVersion(lines: story.short)
            }
        }
        if !story.blocks.isEmpty {
            FamilyStoryBlocks(blocks: story.blocks, active: activeBlock, sentence: listening ? player.caption : "")
                .environment(\.openURL, OpenURLAction { (url: URL) -> OpenURLAction.Result in
                    guard let n = FamilyStoryText.sourceNumber(url) else { return .systemAction }
                    showSource(n, proxy: proxy)
                    return .handled
                })
        } else if let markdown = FamilyAccessRules.nonEmpty(story.markdown) {
            // The first version sent the story as markdown only.
            Text(markdown)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !story.sources.isEmpty {
            FamilyStorySources(sources: story.sources, focus: $focusKey)
        }
    }

    // MARK: Following the voice

    private func follow(_ block: Int?, proxy: ScrollViewProxy) {
        guard let block, motionAllowed, !voiceOverOn else { return }
        withAnimation(.easeInOut(duration: 0.45)) {
            proxy.scrollTo(FamilyStoryBlocks.blockId(block), anchor: .center)
        }
    }

    /// A source chip: the Sources list comes into view and VoiceOver moves there.
    private func showSource(_ n: Int, proxy: ScrollViewProxy) {
        let key: String = FamilyStorySources.key(n)
        if motionAllowed {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(key, anchor: .top) }
        } else {
            proxy.scrollTo(key, anchor: .top)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            focusKey = key
        }
    }

    // MARK: Loading

    @MainActor
    private func load(force: Bool) async {
        if !force, story != nil { return }
        do {
            let fresh = try await FamilyHistoryService.shared.story(slug)
            story = fresh
            failure = nil
            cueBlocks = FamilyGeometry.cueBlocks(chunks: fresh.chunks, blocks: fresh.blocks)
        } catch {
            if LibraryLoad.cancelled(error) { return }
            let message: String = (error as? FamilyFailure)?.message ?? FamilyFailure.offline.message
            if story == nil {
                failure = message
            } else {
                FamilyAnnounce.say(message)
            }
        }
    }
}

// MARK: - How long, the research banner, Listen

struct FamilyStoryIntro: View {
    let story: FHStory
    let listening: Bool
    let onListen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let detail = FamilyAccessRules.nonEmpty(story.detail) {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let banner = FamilyAccessRules.nonEmpty(story.research?.banner) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    FamilyResearchPill()
                    Text(banner)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .familyCard()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Research. " + banner)
            }
            if story.listen == true, !story.chunks.isEmpty, !listening {
                Button(action: onListen) {
                    Label("Listen", systemImage: "headphones")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Reads the story aloud in the Library's voice, with its sentences shown as it reads.")
            }
        }
    }
}

// MARK: - Who's who, and the short version

/// Each person in the story with their term for this viewer: faces for
/// sight, a plain list under VoiceOver.
struct FamilyWhosWho: View {
    let people: [FHPerson]

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @Environment(\.kadeNavigation) private var nav

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FamilyHeading(text: "Who's who for you", level: .h2)
            if voiceOverOn {
                ForEach(people) { person in
                    FamilyPersonRow(person: person)
                }
            } else {
                faces
            }
        }
    }

    private var faces: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(people) { person in
                    VStack(spacing: 2) {
                        FamilyFaceButton(person: person, size: 56) {
                            nav.pushLibrary(.family(.person(FamilyPersonRoute(id: person.id, name: person.shownName))))
                        }
                        if let term = FamilyAccessRules.nonEmpty(person.term) {
                            Text(term)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 88)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct FamilyShortVersion: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FamilyHeading(text: "The short version", level: .h2)
            ForEach(Array(lines.enumerated()), id: \.offset) { pair in
                Text(pair.element)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .familyCard()
    }
}
