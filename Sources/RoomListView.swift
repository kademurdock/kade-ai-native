import SwiftUI

/// Your Debate & Roleplay Rooms — see `RoomService` for the server
/// contract. This screen: list what you've already started, start a new
/// one (topic, optional goals, 2-6 cast members), or jump to the
/// Conversation Hall to read what's been shared. VoiceOver notes mirror
/// `ConversationListView`'s proven row pattern exactly: a plain Button
/// driving local selection state (not `NavigationLink`, not `.combine`),
/// with Delete as both a rotor action and a visual swipe action.
struct RoomListView: View {
    @StateObject private var service: RoomService
    private let apiClient: KadeAPIClient

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        _service = StateObject(wrappedValue: RoomService(client: apiClient))
    }

    @State private var rooms: [DebateRoom] = []
    @State private var hasLoaded = false
    @State private var showingNewRoom = false
    @State private var openedRoom: DebateRoom?
    @State private var deletingRoom: DebateRoom?
    @State private var isDeleting = false
    @State private var openingHall = false

    private enum Focus: Hashable { case status }
    @AccessibilityFocusState private var a11yFocus: Focus?

    var body: some View {
        Group {
            if let error = service.loadError, rooms.isEmpty {
                errorState(error)
            } else if service.isLoading && !hasLoaded {
                ProgressView("Loading your rooms…")
                    .accessibilityLabel("Loading your rooms")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rooms.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Debate Room")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    openingHall = true
                } label: {
                    Text("Hall")
                }
                .accessibilityLabel("Conversation Hall")
                .accessibilityHint("Rooms other people in the family have shared.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewRoom = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New room")
                .accessibilityHint("Set a topic, pick who's in it, and start a new room.")
            }
        }
        .task {
            guard !hasLoaded else { return }
            rooms = await service.loadRooms()
            hasLoaded = true
        }
        .refreshable {
            rooms = await service.loadRooms()
        }
        .sheet(isPresented: $showingNewRoom) {
            NewRoomSheet(apiClient: apiClient) { created in
                rooms.insert(created, at: 0)
                openedRoom = created
            }
        }
        .navigationDestination(item: $openedRoom) { room in
            RoomDetailView(apiClient: apiClient, room: room)
        }
        .navigationDestination(isPresented: $openingHall) {
            ConversationHallView(apiClient: apiClient)
        }
        .alert(
            "Delete this room?",
            isPresented: Binding(
                get: { deletingRoom != nil },
                set: { if !$0 { deletingRoom = nil } }
            ),
            presenting: deletingRoom
        ) { room in
            Button("Delete", role: .destructive) {
                Task { await confirmDelete(room) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { room in
            Text("Deletes \"\(room.topic)\" and everything said in it. This can't be undone.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No rooms yet.")
                .font(.headline)
            Text("Pick a topic and 2 to 6 characters, and they'll go back and forth — you can jump in any time.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New room") { showingNewRoom = true }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .multilineTextAlignment(.center)
                .accessibilityFocused($a11yFocus, equals: .status)
            Button("Try again") {
                Task {
                    rooms = await service.loadRooms()
                    hasLoaded = true
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { a11yFocus = .status }
    }

    private var list: some View {
        List {
            ForEach(rooms) { room in
                Button {
                    openedRoom = room
                } label: {
                    row(for: room)
                }
                .buttonStyle(.plain)
                // Session 26, the Amber rule (build 139 / df915e2): no
                // children:.ignore on a Button. Label + hint stay.
                .accessibilityLabel(accessibleLabel(for: room))
                .accessibilityHint("Opens this room.")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deletingRoom = room
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func row(for room: DebateRoom) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(room.topic)
                .font(.body)
            Text(room.castNames)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func accessibleLabel(for room: DebateRoom) -> String {
        let turnWord = room.turnCount == 1 ? "line" : "lines"
        return "\(room.topic). With \(room.castNames). \(room.turnCount) \(turnWord) so far."
    }

    private func confirmDelete(_ room: DebateRoom) async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await service.deleteRoom(id: room.id)
            rooms.removeAll { $0.id == room.id }
        } catch {
            // Fail-soft: the row simply stays. She can try the swipe/rotor
            // action again; no separate error surface for a delete miss.
        }
        deletingRoom = nil
    }
}

/// The "start a new room" sheet: topic, optional goals, and a 2-6 person
/// cast picked from the room-specific roster. Its own file-local view
/// (not a separate top-level file) -- same nesting precedent as
/// `DescribeView`'s `PickedMovie`/`DescribeSheet`.
private struct NewRoomSheet: View {
    let apiClient: KadeAPIClient
    let onCreated: (DebateRoom) -> Void

    @StateObject private var service: RoomService
    @Environment(\.dismiss) private var dismiss

    init(apiClient: KadeAPIClient, onCreated: @escaping (DebateRoom) -> Void) {
        self.apiClient = apiClient
        self.onCreated = onCreated
        _service = StateObject(wrappedValue: RoomService(client: apiClient))
    }

    @State private var roster: [RoomCastAgent] = []
    @State private var hasLoadedRoster = false
    @State private var topic = ""
    @State private var goals = ""
    @State private var selected: Set<String> = []
    @State private var isCreating = false
    @State private var createError: String?

    private var canCreate: Bool {
        !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selected.count >= 2 && selected.count <= 6 && !isCreating
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Topic or scene") {
                    TextField("What's this room about?", text: $topic, axis: .vertical)
                        .accessibilityLabel("Topic or scene")
                }
                Section("Ground rules (optional)") {
                    TextField("Anything they should keep in mind", text: $goals, axis: .vertical)
                        .accessibilityLabel("Ground rules, optional")
                }
                Section {
                    if service.isLoading && !hasLoadedRoster {
                        ProgressView("Loading characters…")
                            .accessibilityLabel("Loading characters")
                    } else if let error = service.loadError, roster.isEmpty {
                        Text(error).foregroundStyle(.red)
                    } else {
                        ForEach(roster) { agent in
                            castRow(agent)
                        }
                    }
                } header: {
                    Text("Cast (pick 2 to 6)")
                } footer: {
                    Text("\(selected.count) picked.")
                }
                if let createError {
                    Section {
                        Text(createError).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Creating…" : "Create") {
                        Task { await create() }
                    }
                    .disabled(!canCreate)
                }
            }
            .task {
                guard !hasLoadedRoster else { return }
                roster = await service.loadCastableAgents()
                hasLoadedRoster = true
            }
        }
    }

    private func castRow(_ agent: RoomCastAgent) -> some View {
        let isSelected = selected.contains(agent.id)
        return Button {
            if isSelected {
                selected.remove(agent.id)
            } else if selected.count < 6 {
                selected.insert(agent.id)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                    if !agent.description.isEmpty {
                        Text(agent.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Session 26, the Amber rule — same as the room row above.
        .accessibilityLabel(agent.description.isEmpty ? agent.name : "\(agent.name). \(agent.description)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint("Toggles this character in the cast.")
    }

    private func create() async {
        guard canCreate else { return }
        isCreating = true
        createError = nil
        defer { isCreating = false }
        do {
            let room = try await service.createRoom(
                topic: topic.trimmingCharacters(in: .whitespacesAndNewlines),
                goals: goals.trimmingCharacters(in: .whitespacesAndNewlines),
                agentIds: Array(selected)
            )
            dismiss()
            onCreated(room)
        } catch {
            createError = (error as? RoomService.RoomError)?.message ?? "Couldn't create the room. Try again."
        }
    }
}
