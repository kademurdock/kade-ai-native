import SwiftUI

/// The Conversation Hall — native port of the web `/conversation-hall`
/// page: shared "greatest hits" from anyone's Debate Room. Read-only by
/// construction; see `RoomService.loadHall()` for the server contract.
/// Each `HallItem` already carries its own capped (200-line) transcript
/// snapshot directly in the list response, so opening one item needs no
/// extra network call — deliberately simple, matching how little this
/// screen actually does.
struct ConversationHallView: View {
    @StateObject private var service: RoomService

    init(apiClient: KadeAPIClient) {
        _service = StateObject(wrappedValue: RoomService(client: apiClient))
    }

    @State private var items: [HallItem] = []
    @State private var hasLoaded = false
    @State private var openedItem: HallItem?

    private enum Focus: Hashable { case status }
    @AccessibilityFocusState private var a11yFocus: Focus?

    var body: some View {
        Group {
            if let error = service.loadError, items.isEmpty {
                errorState(error)
            } else if service.isLoading && !hasLoaded {
                ProgressView("Loading the Conversation Hall…")
                    .accessibilityLabel("Loading the Conversation Hall")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                Text("Nothing's been shared here yet. Share a room from its own screen to add it.")
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .navigationTitle("Conversation Hall")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !hasLoaded else { return }
            items = await service.loadHall()
            hasLoaded = true
            if service.loadError != nil { a11yFocus = .status }
        }
        .refreshable { items = await service.loadHall() }
        .navigationDestination(item: $openedItem) { item in
            HallItemDetailView(item: item)
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .multilineTextAlignment(.center)
                .accessibilityFocused($a11yFocus, equals: .status)
            Button("Try again") {
                Task { items = await service.loadHall() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(items) { item in
                Button {
                    openedItem = item
                } label: {
                    row(for: item)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibleLabel(for: item))
                .accessibilityHint("Reads this shared room.")
            }
        }
        .listStyle(.plain)
    }

    private func row(for item: HallItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.body)
            Text("With \(item.cast.joined(separator: ", ")) — shared by \(item.by)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func accessibleLabel(for item: HallItem) -> String {
        "\(item.title). With \(item.cast.joined(separator: ", ")). Shared by \(item.by)."
    }
}

/// One shared room's read-only transcript. `HallItem.transcript` is
/// already in hand from the list call — no additional fetch, no say/
/// continue controls, nothing to mutate.
private struct HallItemDetailView: View {
    let item: HallItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.topic)
                    .font(.body)
                    .foregroundStyle(.secondary)
                ForEach(Array(item.transcript.enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
            .padding()
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func lineView(_ line: HallItem.HallLine) -> some View {
        let label = "\(line.name). \(line.text)"
        return VStack(alignment: .leading, spacing: 2) {
            Text(line.name)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(line.text)
                .font(.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
