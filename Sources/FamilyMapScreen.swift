import MapKit
import SwiftUI
import UIKit

// MARK: - Family history: where and when, on a map (Sep 29 2026)
//
// DESIGN 1.6 and 4.6, one GET /places (404 "coming soon" until the export
// has found the places; the timeline's mapReady says so first).
// - The map opens on the richest decade. "Previous decade" and "Next
//   decade", the decade in big type, and Play (2.5 seconds a decade; it stops
//   at the last one, when the screen closes and when the app is not active).
//   The camera moves with the decade (a cut when motion is reduced).
// - "Across the ocean": a card for each ancestor born abroad, with "Fly
//   across the ocean". The camera starts high over the old country on the
//   satellite map, tilts and crosses to the first place in America; its
//   sentence shows on a solid band and is said. A cut when motion is
//   reduced. "Back to the map" ends it.
// - Journeys, and "In the 1880s", the text version: every place by state or
//   country with its people as links. At the largest text sizes the text
//   version comes first.
// VoiceOver: the map is ONE element, "Map of the 1880s", its value the
// server's sentence ("41 ancestors in 17 places, most in two states. The
// list below names every place."); swipe up or down moves exactly one
// decade. Play says each decade at normal priority, waiting until what is
// being said has finished and at least 4 seconds; focus never moves.

struct FamilyMapSection: View {
    let apiClient: KadeAPIClient
    let scope: String
    /// The timeline's word: false while the places are not ready.
    let ready: Bool?

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @KadeMotionPolicy private var motionAllowed: Bool
    @State private var places: FHPlaces?
    @State private var failure: String?
    @State private var comingSoon: String?
    @State private var index = 0
    @State private var camera: MapCameraPosition = .automatic
    @State private var playing = false
    @State private var speaking = false
    @State private var flight: FHOceanCrossing?
    @State private var flightTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .task(id: scope) { await load() }
        .task(id: playing) { await runPlay() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playing = false }
        }
        .onDisappear {
            playing = false
            flightTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.announcementDidFinishNotification)) { _ in
            speaking = false
        }
    }

    @ViewBuilder
    private var content: some View {
        if ready == false {
            soon("The map is coming soon.")
        } else if let comingSoon {
            soon(comingSoon)
        } else if let places, places.decades.indices.contains(index) {
            loaded(places, decade: places.decades[index])
        } else if places != nil {
            soon("The map is coming soon.")
        } else if let failure {
            FamilyTryAgain(message: failure) {
                Task { await load() }
            }
        } else {
            FamilyLoadingLine()
        }
    }

    private func soon(_ words: String) -> some View {
        Text(words + " Through the years shows the same family, decade by decade.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func loaded(_ places: FHPlaces, decade: FHPlaceDecade) -> some View {
        if typeSize.isAccessibilitySize {
            FamilyPlaceList(decade: decade, people: places.people)
            mapBlock(places, decade: decade)
        } else {
            mapBlock(places, decade: decade)
            FamilyPlaceList(decade: decade, people: places.people)
        }
        if !places.ocean.isEmpty {
            oceanSection(places)
        }
        if !places.journeys.isEmpty {
            FamilyJourneyList(journeys: places.journeys, people: places.people)
        }
        footnote(places)
    }

    // MARK: The map and its decade

    private func mapBlock(_ places: FHPlaces, decade: FHPlaceDecade) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            FamilyPlacesMap(points: FamilyMapPoint.points(places, decade),
                            routes: FamilyMapRoute.moves(places, decade),
                            camera: $camera,
                            imagery: flight != nil)
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Map of the " + (decade.title ?? ""))
                .accessibilityValue(FamilyAccessRules.nonEmpty(decade.spoken) ?? decade.summary ?? "")
                .accessibilityHint("Swipe up or down for another decade.")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: step(1, say: false)
                    case .decrement: step(-1, say: false)
                    @unknown default: break
                    }
                }
            if let flight {
                flightBand(flight)
            }
            decadeControls(places, decade: decade)
        }
    }

    private func decadeControls(_ places: FHPlaces, decade: FHPlaceDecade) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    step(-1, say: true)
                } label: {
                    Label("Previous decade", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(index <= 0)
                .accessibilityLabel("Previous decade")
                Text(decade.title ?? "")
                    .font(.largeTitle.bold())
                    .frame(maxWidth: .infinity)
                Button {
                    step(1, say: true)
                } label: {
                    Label("Next decade", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .disabled(index >= places.decades.count - 1)
                .accessibilityLabel("Next decade")
            }
            .accessibilityHidden(voiceOverOn)
            if let summary = FamilyAccessRules.nonEmpty(decade.summary) {
                Text(summary)
                    .font(.headline)
                    .accessibilityHidden(voiceOverOn)
            }
            Button {
                togglePlay(places)
            } label: {
                Label(playing ? "Pause" : "Play the decades", systemImage: playing ? "pause.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint(playing ? "Stops on this decade." : "Moves through the decades by itself, one every few seconds.")
        }
    }

    private func togglePlay(_ places: FHPlaces) {
        if playing {
            playing = false
            return
        }
        endFlight()
        if index >= places.decades.count - 1 {
            move(to: 0, in: places, say: true)
        }
        playing = true
    }

    private func step(_ by: Int, say: Bool) {
        guard let places else { return }
        let target: Int = min(max(0, index + by), places.decades.count - 1)
        guard target != index else { return }
        move(to: target, in: places, say: say)
    }

    private func move(to target: Int, in places: FHPlaces, say: Bool) {
        let region: MKCoordinateRegion? = Self.region(places, places.decades[target])
        let glide: Animation? = motionAllowed ? Animation.easeInOut(duration: 0.8) : nil
        withAnimation(glide) {
            index = target
            if let region, flight == nil {
                camera = .region(region)
            }
        }
        if say {
            let decade: FHPlaceDecade = places.decades[target]
            if voiceOverOn { speaking = true }
            FamilyAnnounce.say(FamilyAccessRules.nonEmpty(decade.spoken) ?? decade.title ?? "")
        }
    }

    /// Every place with people that decade, or every place when none had.
    static func region(_ places: FHPlaces, _ decade: FHPlaceDecade) -> MKCoordinateRegion? {
        let busy: [FHPlace] = places.places.filter { (decade.counts[$0.id] ?? 0) > 0 }
        let shown: [FHPlace] = busy.isEmpty ? places.places : busy
        let lats: [Double] = shown.compactMap { $0.lat }
        let lons: [Double] = shown.compactMap { $0.lon }
        guard let fit = FamilyGeometry.mapFit(latitudes: lats, longitudes: lons) else { return nil }
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: fit.lat, longitude: fit.lon),
                                  span: MKCoordinateSpan(latitudeDelta: fit.latDelta, longitudeDelta: fit.lonDelta))
    }

    /// 2.5 seconds a decade; with VoiceOver, at least 4 seconds and never
    /// before the last decade's words have been said.
    @MainActor
    private func runPlay() async {
        guard playing else { return }
        while playing, !Task.isCancelled {
            let pause: UInt64 = voiceOverOn ? 4_000_000_000 : 2_500_000_000
            do {
                try await Task.sleep(nanoseconds: pause)
            } catch {
                return
            }
            var waited = 0
            while voiceOverOn, speaking, waited < 40 {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
                waited += 1
            }
            guard playing, let places else { return }
            if index >= places.decades.count - 1 {
                playing = false
                return
            }
            move(to: index + 1, in: places, say: true)
        }
    }

    // MARK: Across the ocean

    private func oceanSection(_ places: FHPlaces) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            FamilyHeading(text: "Across the ocean", level: .h2)
            ForEach(Array(places.ocean.enumerated()), id: \.offset) { pair in
                oceanCard(pair.element)
            }
        }
    }

    private func oceanCard(_ crossing: FHOceanCrossing) -> some View {
        let words: String = crossing.text ?? ""
        let canFly: Bool = crossing.from?.lat != nil && crossing.from?.lon != nil
            && crossing.to?.lat != nil && crossing.to?.lon != nil
        return VStack(alignment: .leading, spacing: 8) {
            Text(words)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(FamilyAccessRules.nonEmpty(crossing.spoken) ?? words)
            if canFly {
                Button {
                    fly(crossing)
                } label: {
                    Label("Fly across the ocean", systemImage: "airplane")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Shows the crossing on the map above, and says it.")
            }
        }
        .familyCard()
    }

    /// The sentence on a solid band while the flight shows, and the way back.
    private func flightBand(_ crossing: FHOceanCrossing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(crossing.text ?? "")
                .font(.headline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            Button("Back to the map") {
                endFlight()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black))
    }

    private func fly(_ crossing: FHOceanCrossing) {
        guard let fromLat = crossing.from?.lat, let fromLon = crossing.from?.lon,
              let toLat = crossing.to?.lat, let toLon = crossing.to?.lon else { return }
        playing = false
        flightTask?.cancel()
        flight = crossing
        FamilyAnnounce.say(FamilyAccessRules.nonEmpty(crossing.spoken) ?? crossing.text ?? "")
        let start = CLLocationCoordinate2D(latitude: fromLat, longitude: fromLon)
        let end = CLLocationCoordinate2D(latitude: toLat, longitude: toLon)
        let middle = CLLocationCoordinate2D(latitude: (fromLat + toLat) / 2, longitude: (fromLon + toLon) / 2)
        let heading: Double = FamilyGeometry.bearing(fromLat: fromLat, fromLon: fromLon, toLat: toLat, toLon: toLon)
        guard motionAllowed else {
            camera = .camera(MapCamera(centerCoordinate: end, distance: 1_200_000, heading: 0, pitch: 0))
            return
        }
        flightTask = Task { @MainActor in
            camera = .camera(MapCamera(centerCoordinate: start, distance: 14_000_000, heading: 0, pitch: 0))
            do {
                try await Task.sleep(nanoseconds: 900_000_000)
                withAnimation(.easeInOut(duration: 3)) {
                    camera = .camera(MapCamera(centerCoordinate: middle, distance: 9_000_000, heading: heading, pitch: 45))
                }
                try await Task.sleep(nanoseconds: 3_000_000_000)
                withAnimation(.easeInOut(duration: 3)) {
                    camera = .camera(MapCamera(centerCoordinate: end, distance: 700_000, heading: heading, pitch: 60))
                }
            } catch {
                return
            }
        }
    }

    private func endFlight() {
        flightTask?.cancel()
        flightTask = nil
        guard flight != nil else { return }
        flight = nil
        guard let places, places.decades.indices.contains(index),
              let region = Self.region(places, places.decades[index]) else { return }
        let glide: Animation? = motionAllowed ? Animation.easeInOut(duration: 1) : nil
        withAnimation(glide) {
            camera = .region(region)
        }
    }

    // MARK: The footnote

    @ViewBuilder
    private func footnote(_ places: FHPlaces) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let unplaced = FamilyAccessRules.nonEmpty(places.unplaced) {
                Text(unplaced)
            }
            if let note = FamilyAccessRules.nonEmpty(places.note) {
                Text(note)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Loading

    @MainActor
    private func load() async {
        guard ready != false else { return }
        let asked: String = scope
        if let cached = FamilyHistoryService.shared.cachedPlaces(scope: asked) {
            show(cached)
            return
        }
        do {
            let fresh = try await FamilyHistoryService.shared.places(scope: asked)
            guard asked == scope else { return }
            show(fresh)
        } catch {
            if LibraryLoad.cancelled(error) { return }
            if case .missing(_)? = error as? FamilyFailure {
                comingSoon = "The map is coming soon."
                return
            }
            let message: String = (error as? FamilyFailure)?.message ?? FamilyFailure.offline.message
            if places == nil {
                failure = message
            } else {
                FamilyAnnounce.say(message)
            }
        }
    }

    /// Opens on the richest decade, the camera over its places.
    private func show(_ fresh: FHPlaces) {
        places = fresh
        failure = nil
        comingSoon = nil
        guard !fresh.decades.isEmpty else { return }
        let start: Int = fresh.startIndex
        index = start
        if let region = Self.region(fresh, fresh.decades[start]) {
            camera = .region(region)
        }
    }
}
