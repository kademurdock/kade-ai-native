#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Oct 16 2026: DEBUG simulator gallery of the bundled sample bodies, for CI
/// screenshots (dev/puppet-gallery.sh). Launch with -KadePuppetGallery and
/// optionally -KadePuppetGalleryPage 0 to 7 (3 to 7 are the Body editor,
/// offline). Never reachable in a release build, and the sample files are
/// excluded from Release in project.yml.
struct PuppetGalleryView: View {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-KadePuppetGallery") }
    static var requestedPage: Int {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-KadePuppetGalleryPage"), index + 1 < arguments.count,
              let page = Int(arguments[index + 1]) else { return 0 }
        return min(7, max(0, page))
    }

    /// The same states as the web reference sheet (gen-samples.mjs).
    static let states: [String: [String: Double]] = [
        "neutral": ["mouth.smile": 0.12],
        "happy": ["mouth.smile": 0.7, "cheek.raise": 0.6, "eye.squint": 0.25, "brow.raise": 0.15],
        "talking": ["mouth.open": 0.7, "mouth.wide": 0.4, "brow.raise": 0.3, "mouth.smile": 0.12],
        "surprised": ["brow.raise": 1, "eye.wide": 1, "mouth.open": 0.5, "mouth.round": 0.6, "head.pitch": -0.2],
        "blink": ["eye.blink": 1, "mouth.smile": 0.12],
        "turned": ["head.yaw": 0.8, "head.roll": -0.4, "gaze.x": 0.6, "hair.swing": -0.5, "mouth.smile": 0.12],
        "sad": ["brow.sad": 1, "mouth.smile": -0.7, "gaze.y": 0.45, "head.pitch": 0.35],
        "angry": ["brow.furrow": 1, "mouth.press": 0.6, "mouth.smile": -0.45, "eye.squint": 0.35],
    ]

    private struct Tile: Identifiable {
        let id: Int
        let sample: Int
        let state: String
    }
    private struct SampleFile: Decodable { let scenes: [PuppetScene] }

    private let page = PuppetGalleryView.requestedPage
    @State private var renderers: [PuppetRenderer?] = []
    @State private var report = "Loading samples"

    private var tiles: [Tile] {
        let plan: [(Int, String)]
        switch page {
        case 1:
            plan = [(0, "blink"), (0, "turned"), (1, "blink"), (1, "turned"),
                    (2, "blink"), (2, "turned"), (3, "blink"), (3, "turned")]
        case 2:
            plan = [(4, "neutral"), (4, "happy"), (4, "talking"), (4, "surprised"),
                    (5, "neutral"), (5, "sad"), (5, "talking"), (5, "angry")]
        default:
            plan = [(0, "neutral"), (1, "happy"), (2, "talking"), (3, "surprised"),
                    (4, "sad"), (5, "angry"), (0, "live"), (3, "live")]
        }
        return plan.enumerated().map { Tile(id: $0.offset, sample: $0.element.0, state: $0.element.1) }
    }

    var body: some View {
        if page >= 3 {
            PuppetBuilderGallery(page: page)
        } else {
            // Scrolls so the grid starts below the status bar on every phone size.
            ScrollView {
                gallery
            }
            .task { await load() }
        }
    }

    private var gallery: some View {
        VStack(spacing: 6) {
            Text("Puppet gallery, page \(page + 1). \(report)")
                .font(.caption2)
                .lineLimit(2)
            LazyVGrid(columns: [GridItem(.fixed(168), spacing: 10), GridItem(.fixed(168), spacing: 10)], spacing: 8) {
                ForEach(tiles) { tile in
                    VStack(spacing: 2) {
                        tileView(tile)
                            .frame(width: 168, height: 168)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        Text("\(tile.sample + 1) \(tile.state)")
                            .font(.caption2)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private func tileView(_ tile: Tile) -> some View {
        if tile.sample < renderers.count, let renderer = renderers[tile.sample] {
            if tile.state == "live" {
                PuppetStageView(renderer: renderer, agentID: "gallery-\(tile.sample)", playing: true,
                    level: { 0.06 + 0.05 * sin(Date().timeIntervalSinceReferenceDate * 9) },
                    presentation: { CharacterPresentation(activity: .speaking, expression: .warm) })
            } else {
                PuppetCanvas(renderer: renderer, channels: PuppetChannel.values(Self.states[tile.state] ?? [:]))
            }
        } else {
            Color.gray.opacity(0.2)
        }
    }

    private func load() async {
        guard renderers.isEmpty else { return }
        let result = await Task.detached(priority: .userInitiated) { () -> ([PuppetRenderer?], String) in
            guard let url = Bundle.main.url(forResource: "PuppetSamples", withExtension: "json"),
                  let data = try? Data(contentsOf: url) else { return ([], "No PuppetSamples.json in the bundle.") }
            do {
                let file = try JSONDecoder().decode(SampleFile.self, from: data)
                var notes: [String] = []
                let built = file.scenes.enumerated().map { (index, scene) -> PuppetRenderer? in
                    let problems = scene.problems()
                    if !problems.isEmpty { notes.append("\(index + 1): \(problems.prefix(2).joined(separator: ", "))") }
                    return PuppetPreparedScene(scene: scene).map(PuppetRenderer.init)
                }
                let good = built.compactMap { $0 }.count
                return (built, notes.isEmpty ? "\(good) of \(built.count) samples drawn."
                    : "Problems: " + notes.joined(separator: "; "))
            } catch {
                return ([], "Samples did not decode: \(error)")
            }
        }.value
        renderers = result.0
        report = result.1
    }
}

/// Pages 3 to 7: the Body editor on the bundled sample catalog and body
/// (PuppetBuilderSample.json, written by the kit): the editor's top, the hair
/// colour list, the editor at an accessibility text size, then scrolled to
/// the quick looks and to the eye controls.
private struct PuppetBuilderGallery: View {
    let page: Int
    @EnvironmentObject private var client: KadeAPIClient

    var body: some View {
        if let sample = PuppetBuilderSample.load() {
            PuppetBuilderGalleryStack(page: page, client: client, sample: sample)
        } else {
            Text("No PuppetBuilderSample.json in the bundle.")
        }
    }
}

private struct PuppetBuilderGalleryStack: View {
    let page: Int
    @StateObject private var model: PuppetBuilderModel

    init(page: Int, client: KadeAPIClient, sample: PuppetBuilderSample) {
        self.page = page
        _model = StateObject(wrappedValue: PuppetBuilderModel.gallery(client: client, sample: sample))
    }

    var body: some View {
        NavigationStack {
            if page == 4 {
                Group {
                    if let control = model.catalog?.sections.flatMap(\.controls).first(where: { $0.path == "hair.color" }) {
                        PuppetOptionList(control: control, model: model)
                    } else {
                        ProgressView()
                    }
                }
                .task { await model.load() }
            } else {
                PuppetBuilderView(model: model, agentId: model.agentId, agentName: "Sample",
                    scrollTarget: page == 6 ? "actions" : page == 7 ? "eyes.color" : nil)
            }
        }
        .environment(\.dynamicTypeSize, page == 5 ? .accessibility2 : .large)
    }
}
#endif
