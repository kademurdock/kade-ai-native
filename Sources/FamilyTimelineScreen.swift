import SwiftUI
import UIKit

// MARK: - Family history: where and when (Sep 29 2026)
//
// DESIGN 1.6: "Through the years" and "On a map". Through the years is one
// GET /timeline, newest decade first ("Scroll down to go back in time"),
// from "You, today" at the top down to the earliest decade. Each decade
// (FamilyDecadeSection.swift) has its heading, a card with its best photo
// and one line ("41 of your ancestors were alive"), the context lines ("12
// of your ancestors were adults during the Civil War"), a thin band of
// lifelines, and its events, 12 at a time. Ancestors, or all relatives.
// The map is a later step of the build; until it is in, "On a map" says it
// is coming soon.
//
// VoiceOver: the decade headings are always there (the Headings rotor walks
// the centuries). Each band is ONE element with the server's summary ("1880s:
// 41 ancestors alive, 12 events"). Each event opens its person.

struct FamilyTimelineScreen: View {
    let apiClient: KadeAPIClient

    @State private var showMap: Bool
    @State private var scope = "ancestors"
    @State private var timeline: FHTimeline?
    @State private var failure: String?
    @State private var viewer: FamilyViewerRequest?

    init(apiClient: KadeAPIClient, map: Bool) {
        self.apiClient = apiClient
        _showMap = State(initialValue: map)
        _timeline = State(initialValue: FamilyHistoryService.shared.cachedTimeline(scope: "ancestors"))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FamilyHeading(text: "Where and when", level: .h1, focusOnArrival: true)
                Picker("Show", selection: $showMap) {
                    Text("Through the years").tag(false)
                    Text("On a map").tag(true)
                }
                .pickerStyle(.segmented)
                if showMap {
                    mapPart
                } else {
                    yearsPart
                }
            }
            .padding()
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Where and when")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scope) { await load(force: false) }
        .refreshable { await load(force: true) }
        .background {
            Color.clear.fullScreenCover(item: $viewer) { request in
                FamilyPhotoViewer(request: request)
            }
        }
    }

    // MARK: On a map

    private var mapPart: some View {
        Text("The map is coming soon. Through the years shows the same family, decade by decade.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Through the years

    @ViewBuilder
    private var yearsPart: some View {
        Picker("Who", selection: $scope) {
            Text("Ancestors").tag("ancestors")
            Text("All relatives").tag("all")
        }
        .pickerStyle(.segmented)
        if let timeline {
            years(timeline)
        } else if let failure {
            FamilyTryAgain(message: failure) {
                Task { await load(force: true) }
            }
        } else {
            FamilyLoadingLine()
        }
    }

    @ViewBuilder
    private func years(_ timeline: FHTimeline) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(FamilyAccessRules.nonEmpty(timeline.top) ?? "You, today")
                .font(.title3.weight(.semibold))
            if let hint = FamilyAccessRules.nonEmpty(timeline.hint) {
                Text(hint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let follows = FamilyAccessRules.nonEmpty(timeline.follows) {
                Text(follows)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        FamilyLifelineLegend()
        if timeline.decades.isEmpty {
            Text("There is nothing to show here yet.")
                .foregroundStyle(.secondary)
        }
        ForEach(Array(timeline.decades.enumerated()), id: \.offset) { pair in
            FamilyDecadeSection(decade: pair.element, people: timeline.people,
                                lanes: timeline.lanes ?? 1) { photo in
                viewer = FamilyViewerRequest(items: [photo], start: 0)
            }
        }
    }

    // MARK: Loading

    @MainActor
    private func load(force: Bool) async {
        let asked: String = scope
        if !force, let cached = FamilyHistoryService.shared.cachedTimeline(scope: asked) {
            timeline = cached
            failure = nil
            return
        }
        do {
            let fresh = try await FamilyHistoryService.shared.timeline(scope: asked)
            guard asked == scope else { return }
            timeline = fresh
            failure = nil
        } catch {
            if LibraryLoad.cancelled(error) { return }
            let message: String = (error as? FamilyFailure)?.message ?? FamilyFailure.offline.message
            if timeline == nil {
                failure = message
            } else {
                FamilyAnnounce.say(message)
            }
        }
    }
}

/// What the lifelines' colours mean, in words (colour is never the only
/// cue: each event and person says their side too).
struct FamilyLifelineLegend: View {
    @KadeContrastPolicy private var highContrast: Bool

    private static let sides: [(FHSide, String)] = [
        (.father, "Dad's side"), (.mother, "Mom's side"), (.both, "Both sides"), (.marriage, "By marriage"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Each bar is one life, drawn in its side's colour:")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                swatch(0)
                swatch(1)
            }
            HStack(spacing: 14) {
                swatch(2)
                swatch(3)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func swatch(_ index: Int) -> some View {
        let entry: (FHSide, String) = Self.sides[index]
        return HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(FamilySideColor.color(entry.0, contrast: highContrast))
                .frame(width: 5, height: 14)
            Text(entry.1)
        }
    }
}
