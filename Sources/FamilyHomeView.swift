import SwiftUI
import UIKit

// MARK: - Family history: Home, the first ten seconds (Sep 29 2026)
//
// DESIGN 1.2. One GET /home draws the whole screen: the hero about the
// viewer and their faces, "Your family in 60 seconds", the featured card,
// "New since your last visit", four big tiles, More, the Coming soon line and
// the footnote (the cards are in FamilyHomeParts.swift). The last /home is
// kept for this account (FamilyHistoryService.cachedHome), so a return visit
// draws at once and then refreshes.
//
// "New since your last visit" counts from the version Home last showed this
// account: read once when Home opens, kept while Home stays in the stack (so
// coming back from the gallery does not lose the strip), and moved on when
// Home goes away.
//
// VoiceOver starts on the "Family history" heading about 550 ms after the
// push. A failure with nothing drawn shows a focused, announced Try again.

struct FamilyHomeView: View {
    let apiClient: KadeAPIClient
    private let archiveIdentity: String

    @State private var home: FHHome?
    @State private var failure: String?
    @State private var loadedAt: Date?
    /// The version "new" counts from during this visit.
    @State private var since: String?
    @State private var sinceRead = false
    @State private var note: FamilyNoteRequest?

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        archiveIdentity = FamilyArchiveRules.identity(FamilyHistoryService.shared.archiveId)
        _home = State(initialValue: FamilyHistoryService.shared.cachedHome())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FamilyHeading(text: "Family history", level: .h1, focusOnArrival: true)
                FamilyArchivePicker(apiClient: apiClient)
                content
            }
            .padding()
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Family history")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(force: false) }
        .refreshable { await load(force: true) }
        .onDisappear { rememberSeen() }
        .sheet(item: $note) { request in
            FamilyNoteSheet(request: request)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let home {
            sections(home)
        } else if let failure {
            FamilyTryAgain(message: failure) {
                Task { await load(force: true) }
            }
        } else {
            FamilyLoadingLine()
        }
    }

    @ViewBuilder
    private func sections(_ home: FHHome) -> some View {
        let featured = home.visibleFeatured
        let tiles = home.visibleTiles
        let more = home.visibleMore
        if let hero = home.hero {
            FamilyHeroCard(hero: hero, faces: home.faces, reelTitle: home.reel?.title)
        }
        if let reel = home.reel, !reel.visibleCards.isEmpty {
            FamilyReelCard(reel: reel)
        }
        if !featured.isEmpty {
            FamilyFeaturedCard(items: featured)
        }
        if let news = home.visibleNews {
            FamilyNewsStrip(news: news)
        }
        if !tiles.isEmpty {
            FamilyTileGrid(tiles: tiles) { personId in openNote(personId) }
        }
        if !more.isEmpty {
            FamilyMoreRows(rows: more) { personId in openNote(personId) }
        }
        FamilyHomeFooter(home: home)
    }

    private func openNote(_ personId: String?) {
        note = FamilyNoteRequest(personId: personId, kind: "memory", title: "Add a memory",
                                 prompt: "What would you like the family to know?")
    }

    // MARK: Loading

    @MainActor
    private func load(force: Bool) async {
        guard archiveIdentity == FamilyArchiveRules.identity(FamilyHistoryService.shared.archiveId) else { return }
        if !sinceRead {
            sinceRead = true
            since = FamilyMemory.string(FamilyMemory.seenVersion)
        }
        // Back from a screen on top: ask again only after a minute (a pull
        // always asks).
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 60 { return }
        do {
            let fresh = try await FamilyHistoryService.shared.home(since: since)
            home = fresh
            failure = nil
            loadedAt = Date()
        } catch {
            // Cut short by a push or a tab switch: it loads again on return.
            if LibraryLoad.cancelled(error) { return }
            let message: String = (error as? FamilyFailure)?.message ?? FamilyFailure.offline.message
            if home == nil {
                failure = message
            } else if force {
                // What is drawn stays; the pull says why it did not refresh.
                FamilyAnnounce.say(message)
            }
        }
    }

    /// The next visit's "new" counts from what this one showed.
    private func rememberSeen() {
        guard archiveIdentity == FamilyArchiveRules.identity(FamilyHistoryService.shared.archiveId) else { return }
        guard let version = FamilyAccessRules.nonEmpty(home?.version) else { return }
        FamilyMemory.set(version, FamilyMemory.seenVersion)
    }
}
