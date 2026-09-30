import MapKit
import SwiftUI
import UIKit

// MARK: - Family history: the map's pieces (Sep 29 2026)
//
// DESIGN 1.6 and 4.6. The app's first MapKit screen, kept plain:
// - A fixed set of places for the whole map (at most 80, merged by county):
//   every place is always there, and a decade only changes each dot's size
//   and opacity (MapKit on iOS 17 does not animate annotations in or out,
//   so nothing is inserted or removed). The decade's top five places carry
//   their names. A place known only to its state or country also gets a
//   soft circle. Moves are plain solid lines.
// - One ForEach per kind of map content, over arrays built first.
// - The standard map with no points of interest; satellite only for the
//   flight across the ocean.
// - The map is hidden inside ONE element (FamilyMapSection gives it its
//   words), and the text version below names every place and person.

/// One place on the map for the chosen decade.
struct FamilyMapPoint: Identifiable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let count: Int
    /// Its name, when it is one of the decade's top five.
    let label: String?
    /// Known only to a state or country: a soft circle too.
    let wide: Bool
    /// Metres.
    let radius: Double

    static func points(_ places: FHPlaces, _ decade: FHPlaceDecade) -> [FamilyMapPoint] {
        var out: [FamilyMapPoint] = []
        for place in places.places {
            guard let lat = place.lat, let lon = place.lon, !place.id.isEmpty else { continue }
            let precision: String = place.precision ?? "county"
            let wide: Bool = precision == "state" || precision == "country"
            let labelled: Bool = decade.labels.contains(place.id)
            let name: String = place.short ?? place.id
            out.append(FamilyMapPoint(id: place.id,
                                      name: name,
                                      coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                      count: decade.counts[place.id] ?? 0,
                                      label: labelled ? name : nil,
                                      wide: wide,
                                      radius: precision == "country" ? 350_000 : 160_000))
        }
        return out
    }
}

/// One move, as a line from one place to another.
struct FamilyMapRoute: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]

    static func moves(_ places: FHPlaces, _ decade: FHPlaceDecade) -> [FamilyMapRoute] {
        var byId: [String: CLLocationCoordinate2D] = [:]
        for place in places.places {
            if let lat = place.lat, let lon = place.lon {
                byId[place.id] = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        var out: [FamilyMapRoute] = []
        for (i, move) in decade.moves.enumerated() {
            guard let from = byId[move.from ?? ""], let to = byId[move.to ?? ""] else { continue }
            out.append(FamilyMapRoute(id: "move-\(i)", coordinates: [from, to]))
        }
        return out
    }
}

/// The map itself: circles, lines, then the dots on top.
struct FamilyPlacesMap: View {
    let points: [FamilyMapPoint]
    let routes: [FamilyMapRoute]
    @Binding var camera: MapCameraPosition
    /// Satellite, for the flight across the ocean.
    let imagery: Bool

    @KadeContrastPolicy private var highContrast: Bool
    @KadeMotionPolicy private var motionAllowed: Bool

    private var areas: [FamilyMapPoint] { points.filter { $0.wide } }

    private var most: Int { max(1, points.map { $0.count }.max() ?? 1) }

    private var style: MapStyle {
        if imagery {
            return MapStyle.imagery(elevation: .realistic)
        }
        return MapStyle.standard(elevation: .flat, pointsOfInterest: .excludingAll)
    }

    var body: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            ForEach(areas) { area in
                MapCircle(center: area.coordinate, radius: area.radius)
                    .foregroundStyle(Color.orange.opacity(area.count > 0 ? 0.14 : 0))
                    .stroke(Color.orange.opacity(area.count > 0 ? 0.8 : 0), lineWidth: 1)
            }
            ForEach(routes) { route in
                MapPolyline(coordinates: route.coordinates)
                    .stroke(Color.purple, lineWidth: 2)
            }
            ForEach(points) { point in
                Annotation(point.name, coordinate: point.coordinate, anchor: .center) {
                    FamilyMapDot(count: point.count, most: most, label: point.label,
                                 contrast: highContrast, animated: motionAllowed)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(style)
    }
}

/// A place's dot: bigger and stronger with more people there that decade,
/// faded out when nobody was. Its name shows for the top five places.
struct FamilyMapDot: View {
    let count: Int
    let most: Int
    let label: String?
    let contrast: Bool
    let animated: Bool

    var body: some View {
        let dot: (size: Double, opacity: Double) = FamilyGeometry.mapDot(count: count, maxCount: most)
        ZStack {
            Circle()
                .fill(Color.orange)
                .overlay(Circle().strokeBorder(contrast ? Color.black : Color.white, lineWidth: contrast ? 2 : 1))
                .frame(width: dot.size, height: dot.size)
            if let label, count > 0 {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(.systemBackground).opacity(0.9)))
                    .fixedSize()
                    .offset(y: dot.size / 2 + 12)
            }
        }
        .opacity(dot.opacity)
        .animation(animated ? .easeInOut(duration: 0.8) : nil, value: count)
        .accessibilityHidden(true)
    }
}

// MARK: - The text version

/// "In the 1880s", grouped by state or country, each place with its people
/// as links: everything the map shows, in words.
struct FamilyPlaceList: View {
    let decade: FHPlaceDecade
    let people: [String: FHPerson]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FamilyHeading(text: "In the " + (decade.title ?? ""), level: .h2)
            if decade.list.isEmpty {
                Text("No places are known for this decade.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(decade.list.enumerated()), id: \.offset) { pair in
                group(pair.element)
            }
        }
    }

    private func group(_ group: FHPlaceGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let heading = FamilyAccessRules.nonEmpty(group.heading) {
                FamilyHeading(text: heading, level: .h3)
            }
            ForEach(Array(group.rows.enumerated()), id: \.offset) { pair in
                row(pair.element)
            }
        }
    }

    private func row(_ row: FHPlaceRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.text ?? "")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(row.people.enumerated()), id: \.offset) { pair in
                if let person = people[pair.element] {
                    FamilyPersonRow(person: person)
                        .padding(.leading, 12)
                }
            }
        }
    }
}

/// "Your 3rd great-grandfather: born in {state} in 1821, in {county} by
/// 1850, ..." Each opens the person.
struct FamilyJourneyList: View {
    let journeys: [FHJourney]
    let people: [String: FHPerson]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FamilyHeading(text: "Journeys", level: .h2)
            ForEach(Array(journeys.enumerated()), id: \.offset) { pair in
                journey(pair.element)
            }
        }
    }

    @ViewBuilder
    private func journey(_ journey: FHJourney) -> some View {
        let words: String = journey.text ?? ""
        let said: String = FamilyAccessRules.nonEmpty(journey.spoken) ?? words
        if let id = FamilyAccessRules.nonEmpty(journey.personId) {
            NavigationLink(value: HomeRoute.library(.family(.person(FamilyPersonRoute(id: id, name: people[id]?.shownName ?? ""))))) {
                Text(words)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(said)
            .accessibilityHint("Opens their page.")
        } else {
            Text(words)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(said)
        }
    }
}
