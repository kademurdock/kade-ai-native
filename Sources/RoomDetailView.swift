import SwiftUI

/// One live Debate & Roleplay Room. See `RoomService` for the server
/// contract. Core loop, matching the web page's own design: say something
/// (optional — you can also just watch), then either "Continue" (round-
/// robin, whoever's turn it is) or pick a specific cast member to jump in
/// out of turn — the web page calls this "interject between any two
/// turns," and this is the same capability, not a native invention.
///
/// VoiceOver notes: every new line (hers or a character's) moves
/// accessibility focus to itself the moment it lands, same "hear what just
/// happened without hunting for it" contract `ConversationDetailView` uses
/// for new messages. Each transcript line is one combined element
/// (`.ignore` + explicit label), never `.combine` (this app's standing
/// rule — see `HelpView`'s doc comment for why). Lines have no server-
/// side id (see `RoomLine`'s doc comment), so the transcript `ForEach`
/// keys off `.enumerated()`/`\.offset`, matching `GameRoomView`.
struct RoomDetailView: View {
    @StateObject private var service: RoomService
    @State private var room: DebateRoom

    init(apiClient: KadeAPIClient, room: DebateRoom) {
        _service = StateObject(wrappedValue: RoomService(client: apiClient))
        _room = State(initialValue: room)
    }

    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var draftText = ""
    @State private var isSending = false
    @State private var isGeneratingTurn = false
    @State private var actionError: String?
    @State private var showingShareSheet = false

    @AccessibilityFocusState private var focusedLineIndex: Int?
    private enum Focus: Hashable { case status }
    @AccessibilityFocusState private var a11yFocus: Focus?

    private var transcript: [RoomLine] { room.transcript ?? [] }

    private var nextSpeakerName: String? {
        guard !room.agents.isEmpty else { return nil }
        let idx = ((room.nextIdx % room.agents.count) + room.agents.count) % room.agents.count
        return room.agents[idx].name
    }

    var body: some View {
        VStack(spacing: 0) {
            if let loadError, transcript.isEmpty {
                errorState(loadError)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if !room.goals.isEmpty {
                                Text("Ground rules: \(room.goals)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(Array(transcript.enumerated()), id: \.offset) { index, line in
                                lineView(line)
                                    .id(index)
                                    .accessibilityFocused($focusedLineIndex, equals: index)
                            }
                            if let actionError {
                                Text(actionError)
                                    .foregroundStyle(.red)
                                    .accessibilityFocused($a11yFocus, equals: .status)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: focusedLineIndex) { _, newValue in
                        guard let newValue else { return }
                        withAnimation { proxy.scrollTo(newValue, anchor: .bottom) }
                    }
                }
                turnControls
                composer
            }
        }
        .navigationTitle(room.topic)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingShareSheet = true
                } label: {
                    Image(systemName: room.shared ? "person.2.fill" : "person.2")
                }
                .accessibilityLabel(room.shared ? "Shared to Conversation Hall" : "Share to Conversation Hall")
                .accessibilityHint("Opens sharing options for this room.")
            }
        }
        .task {
            guard !hasLoaded else { return }
            await reload()
            hasLoaded = true
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareRoomSheet(service: service, room: room) { updated in
                room = updated
            }
        }
    }

    private func lineView(_ line: RoomLine) -> some View {
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

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .multilineTextAlignment(.center)
                .accessibilityFocused($a11yFocus, equals: .status)
            Button("Try again") { Task { await reload() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { a11yFocus = .status }
    }

    private var turnControls: some View {
        VStack(spacing: 8) {
            if let nextSpeakerName {
                Text("Next up: \(nextSpeakerName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    Task { await advance(forcedAgentId: nil) }
                } label: {
                    if isGeneratingTurn {
                        ProgressView()
                    } else {
                        Text("Continue")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGeneratingTurn)
                .accessibilityLabel(isGeneratingTurn ? "Generating the next line" : "Continue")
                .accessibilityHint("Lets whoever's turn it is speak next.")

                Menu {
                    ForEach(room.agents, id: \.agentId) { member in
                        Button(member.name) {
                            Task { await advance(forcedAgentId: member.agentId) }
                        }
                    }
                } label: {
                    Text("Choose who's next")
                }
                .disabled(isGeneratingTurn)
                .accessibilityHint("Pick a specific character to jump in out of turn.")
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private var composer: some View {
        HStack {
            TextField("Say something in the room…", text: $draftText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Say something in the room")
            Button {
                Task { await sendSay() }
            } label: {
                if isSending {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
            }
            .disabled(isSending || draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding()
    }

    private func reload() async {
        do {
            room = try await service.loadRoom(id: room.id)
            loadError = nil
        } catch {
            loadError = (error as? RoomService.RoomError)?.message ?? "Couldn't load that room."
        }
    }

    private func sendSay() async {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        actionError = nil
        defer { isSending = false }
        do {
            _ = try await service.say(roomId: room.id, text: text)
            draftText = ""
            await reload()
            focusedLineIndex = transcript.indices.last
        } catch {
            actionError = (error as? RoomService.RoomError)?.message ?? "Couldn't post your message. Try again."
        }
    }

    private func advance(forcedAgentId: String?) async {
        guard !isGeneratingTurn else { return }
        isGeneratingTurn = true
        actionError = nil
        defer { isGeneratingTurn = false }
        do {
            _ = try await service.nextTurn(roomId: room.id, forcedAgentId: forcedAgentId)
            await reload()
            focusedLineIndex = transcript.indices.last
        } catch {
            actionError = (error as? RoomService.RoomError)?.message ?? "That turn failed — give it another try."
        }
    }
}

/// The share/unshare sheet — a title (required only when sharing) plus a
/// single toggle-shaped action, matching the web page's own share flow
/// (`POST .../share {share, title}`). Its own file-local view, same
/// nesting precedent as `NewRoomSheet` in `RoomListView.swift`.
private struct ShareRoomSheet: View {
    let service: RoomService
    let room: DebateRoom
    let onUpdated: (DebateRoom) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var isWorking = false
    @State private var error: String?

    init(service: RoomService, room: DebateRoom, onUpdated: @escaping (DebateRoom) -> Void) {
        self.service = service
        self.room = room
        self.onUpdated = onUpdated
        _title = State(initialValue: room.sharedTitle.isEmpty ? room.topic : room.sharedTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                if room.shared {
                    Section {
                        Text("This room is shared to the Conversation Hall.")
                    }
                    Section {
                        Button("Stop sharing", role: .destructive) {
                            Task { await setShared(false) }
                        }
                    }
                } else {
                    Section("Title for the Hall") {
                        TextField("A short title", text: $title)
                            .accessibilityLabel("Title for the Conversation Hall")
                    }
                    Section {
                        Button(isWorking ? "Sharing…" : "Share to Conversation Hall") {
                            Task { await setShared(true) }
                        }
                        .disabled(isWorking || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Share room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func setShared(_ share: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let shared = try await service.setShared(
                roomId: room.id,
                share: share,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let updated = DebateRoom(
                id: room.id,
                topic: room.topic,
                goals: room.goals,
                agents: room.agents,
                shared: shared,
                sharedTitle: shared ? title.trimmingCharacters(in: .whitespacesAndNewlines) : "",
                nextIdx: room.nextIdx,
                turnCount: room.turnCount,
                createdAt: room.createdAt,
                updatedAt: room.updatedAt,
                transcript: room.transcript,
                lines: room.lines
            )
            onUpdated(updated)
            dismiss()
        } catch {
            self.error = (error as? RoomService.RoomError)?.message ?? "Couldn't update sharing. Try again."
        }
    }
}
