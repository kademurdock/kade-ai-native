import SwiftUI

/// One live Debate & Roleplay Room. See `RoomService` for the server
/// contract. Session 35 part 3 — her ask: "finish the debait room": voice
/// clips now play AUTOMATICALLY as lines land (each character in their own
/// cast voice), the cast can change mid-room (add/remove, Narrator lines
/// mark the comings and goings), turns can auto-advance in supervised
/// stretches, and any turn can run Deep Think.
///
/// Core loop, matching the web page's own design: say something (optional
/// — you can also just watch/listen), then either "Continue" (round-robin)
/// or pick a specific cast member to jump in out of turn.
///
/// LISTENING DESIGN (the point of this rework, VoiceOver-first):
/// - New lines SPEAK THEMSELVES when Voices is on (default on): the cast
///   snapshot already carries each character's voiceId + rate, so playback
///   needs no per-line resolve. Pacing is real: auto-advance waits for the
///   clip to FINISH before the next turn generates, so a debate listens
///   like a radio play, not a pile-up.
/// - Catch-up is explicit, never automatic: opening an old room does NOT
///   read 100 lines at you. Every line carries rotor actions "Play this
///   line" and "Play from here" (also in a long-press menu for sighted
///   hands).
/// - Auto-advance runs in stretches of 12 then pauses and says so — a
///   debate that runs while the phone sits on the counter should still ask
///   permission to keep spending money. Errors and the server's own caps
///   (out of budget / 300-a-day / room full) stop it immediately, spoken.
///
/// VoiceOver notes: every new line moves accessibility focus to itself the
/// moment it lands (same contract as chat). Each transcript line is one
/// combined element (`.ignore` + explicit label). Lines have no server id,
/// so the `ForEach` keys off `.enumerated()`/`\.offset` (standing pattern).
struct RoomDetailView: View {
    @StateObject private var service: RoomService
    @StateObject private var voiceService: VoiceService
    @State private var room: DebateRoom

    init(apiClient: KadeAPIClient, room: DebateRoom) {
        _service = StateObject(wrappedValue: RoomService(client: apiClient))
        _voiceService = StateObject(wrappedValue: VoiceService(client: apiClient))
        _room = State(initialValue: room)
        _voicesOn = State(initialValue: UserDefaults.standard.object(forKey: "kade.room.voicesOn") as? Bool ?? true)
        _deepThinkOn = State(initialValue: UserDefaults.standard.bool(forKey: "kade.room.deepThink.\(room.id)"))
    }

    @State private var hasLoaded = false
    @State private var loadError: String?
    @State private var draftText = ""
    @State private var isSending = false
    @State private var isGeneratingTurn = false
    @State private var actionError: String?
    @State private var showingShareSheet = false
    @State private var showingCastSheet = false

    // Session 35 part 3 — the listening controls.
    @State private var voicesOn: Bool
    @State private var deepThinkOn: Bool
    @State private var autoAdvanceOn = false
    @State private var autoTask: Task<Void, Never>?
    /// Auto-advance stretch counter; pauses (and says so) at this many.
    private static let autoBatchLimit = 12

    @AccessibilityFocusState private var focusedLineIndex: Int?
    /// Session 35 part 6: sighted-scroll WITHOUT VoiceOver focus. On voiced
    /// turns the clip IS the delivery — grabbing VO focus made VoiceOver
    /// read the row OVER the cast voice (her report: "talked over and
    /// fucked over Sylvia"). This target scrolls the transcript for eyes
    /// while ears get exactly one voice.
    @State private var scrollTarget: Int?
    private enum Focus: Hashable { case status }
    @AccessibilityFocusState private var a11yFocus: Focus?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var motionAllowed: Bool {
        !(systemReduceMotion || FeedbackPrefs.shared.forceReduceMotion)
    }

    private var transcript: [RoomLine] { room.transcript ?? [] }

    private var nextSpeakerName: String? {
        guard !room.agents.isEmpty else { return nil }
        let idx = ((room.nextIdx % room.agents.count) + room.agents.count) % room.agents.count
        return room.agents[idx].name
    }

    /// The cast snapshot for a transcript line's speaker, when it's an
    /// agent (user and Narrator lines return nil — the default voice
    /// covers Narrator, and her own lines are never read back at her).
    private func castMember(for line: RoomLine) -> RoomCastMember? {
        room.agents.first(where: { $0.agentId == line.speaker })
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
                                lineView(line, index: index)
                                    .id(index)
                                    .accessibilityFocused($focusedLineIndex, equals: index)
                                    .transition(motionAllowed
                                        ? .opacity.combined(with: .move(edge: .bottom))
                                        : .identity)
                            }
                            if let actionError {
                                Text(actionError)
                                    .foregroundStyle(.red)
                                    .accessibilityFocused($a11yFocus, equals: .status)
                            }
                        }
                        .padding()
                        .animation(motionAllowed ? .spring(response: 0.35, dampingFraction: 0.8) : nil,
                                   value: transcript.count)
                    }
                    .onChange(of: focusedLineIndex) { _, newValue in
                        guard let newValue else { return }
                        withAnimation { proxy.scrollTo(newValue, anchor: .bottom) }
                    }
                    .onChange(of: scrollTarget) { _, newValue in
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
                    showingCastSheet = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
                .accessibilityLabel("Manage the cast")
                .accessibilityHint("Add or remove characters mid-debate.")
            }
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
        .onDisappear {
            // Leaving the room stops the machinery cold: no auto turns
            // spending money offscreen, no voice talking to an empty hall.
            autoAdvanceOn = false
            autoTask?.cancel()
            autoTask = nil
            voiceService.stopSpeaking()
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareRoomSheet(service: service, room: room) { updated in
                room = updated
            }
        }
        .sheet(isPresented: $showingCastSheet) {
            ManageCastSheet(service: service, room: room) { updated in
                let before = Set(room.agents.map(\.agentId))
                let after = Set(updated.agents.map(\.agentId))
                room = updated
                let joined = updated.agents.filter { !before.contains($0.agentId) }.map(\.name)
                let leftCount = before.subtracting(after).count
                var parts: [String] = []
                if !joined.isEmpty { parts.append("\(joined.joined(separator: ", ")) joined") }
                if leftCount > 0 { parts.append("\(leftCount) left") }
                if !parts.isEmpty {
                    UIAccessibility.post(notification: .announcement,
                                         argument: "Cast updated: \(parts.joined(separator: "; ")).")
                }
                focusedLineIndex = transcript.indices.last
            }
        }
    }

    private func lineView(_ line: RoomLine, index: Int) -> some View {
        let isNarrator = line.speaker == "narrator"
        let label = "\(line.name). \(line.text)"
        return VStack(alignment: .leading, spacing: 2) {
            Text(line.name)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(line.text)
                .font(isNarrator ? .callout.italic() : .body)
                .foregroundStyle(isNarrator ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        // Session 35 part 3: explicit catch-up listening. Rotor for
        // VoiceOver, long-press for sighted hands — the same two actions.
        .accessibilityActions {
            Button("Play this line") { playLine(at: index) }
            Button("Play from here") { playFrom(index: index) }
        }
        .contextMenu {
            Button {
                playLine(at: index)
            } label: {
                Label("Play This Line", systemImage: "play.circle")
            }
            Button {
                playFrom(index: index)
            } label: {
                Label("Play From Here", systemImage: "play.circle.fill")
            }
        }
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
                if isGeneratingTurn {
                    KadePulseDot(color: .accentColor, diameter: 8, active: true, haptic: true)
                }
                Button {
                    Task { _ = await advance(forcedAgentId: nil) }
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
                            Task { _ = await advance(forcedAgentId: member.agentId) }
                        }
                    }
                } label: {
                    Text("Choose who's next")
                }
                .disabled(isGeneratingTurn)
                .accessibilityHint("Pick a specific character to jump in out of turn.")
            }
            // The listening controls. Real Toggles — visible state, one
            // swipe stop each, spoken hints that say what they cost.
            HStack(spacing: 16) {
                Toggle(isOn: $voicesOn) {
                    Image(systemName: voicesOn ? "speaker.wave.2.fill" : "speaker.slash")
                        .accessibilityHidden(true)
                }
                .toggleStyle(.button)
                .accessibilityLabel("Voices")
                .accessibilityValue(voicesOn ? "on" : "off")
                .accessibilityHint("Speaks each new line in that character's own voice.")
                .onChange(of: voicesOn) { _, on in
                    UserDefaults.standard.set(on, forKey: "kade.room.voicesOn")
                    if !on { voiceService.stopSpeaking() }
                }

                Toggle(isOn: $deepThinkOn) {
                    Image(systemName: "brain")
                        .accessibilityHidden(true)
                }
                .toggleStyle(.button)
                .accessibilityLabel("Deep Think debate")
                .accessibilityValue(deepThinkOn ? "on" : "off")
                .accessibilityHint("Every turn reasons hard before speaking. Slower, deeper arguments, costs a little more.")
                .onChange(of: deepThinkOn) { _, on in
                    UserDefaults.standard.set(on, forKey: "kade.room.deepThink.\(room.id)")
                    UIAccessibility.post(notification: .announcement,
                                         argument: on ? "Deep Think on. Turns will take longer." : "Deep Think off.")
                }

                Toggle(isOn: $autoAdvanceOn) {
                    Image(systemName: autoAdvanceOn ? "forward.fill" : "forward")
                        .accessibilityHidden(true)
                }
                .toggleStyle(.button)
                .accessibilityLabel("Keep it going")
                .accessibilityValue(autoAdvanceOn ? "on" : "off")
                .accessibilityHint("Turns keep coming on their own, twelve at a stretch, then it pauses and says so. Turn off any time to take the wheel.")
                .onChange(of: autoAdvanceOn) { _, on in
                    if on {
                        startAutoAdvance()
                    } else {
                        autoTask?.cancel()
                        autoTask = nil
                    }
                }
            }
            .padding(.top, 2)
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

    // MARK: - Listening

    /// Speak one existing transcript line in its speaker's cast voice.
    private func playLine(at index: Int) {
        guard transcript.indices.contains(index) else { return }
        let line = transcript[index]
        voiceService.stopSpeaking()
        let member = castMember(for: line)
        Task {
            await voiceService.speakLine(
                text: clipText(for: line),
                voiceId: member?.voiceId,
                rate: member?.rate
            )
        }
    }

    /// Catch-up listening: play every line from `index` to the end, each
    /// in its own voice, names announced so a multi-character stretch
    /// never turns into an anonymous wall of sound.
    private func playFrom(index: Int) {
        guard transcript.indices.contains(index) else { return }
        voiceService.stopSpeaking()
        let lines = Array(transcript[index...])
        let members = lines.map { castMember(for: $0) }
        let texts = lines.map { clipText(for: $0) }
        Task {
            for (i, member) in members.enumerated() {
                if Task.isCancelled { return }
                await voiceService.speakLine(
                    text: texts[i],
                    voiceId: member?.voiceId,
                    rate: member?.rate
                )
            }
        }
    }

    /// Session 35 part 6, HER RULE, verbatim intent: "vo doesn't say names,
    /// it should, but speech voice clip should not." So: transcript ROWS
    /// keep "Name. text" as their VoiceOver label (browsing always
    /// attributes), and CLIPS are pure dialogue — no name prefix, ever, no
    /// clever exceptions. (An earlier draft kept names when two cast
    /// members share a voice; her call overrides — if a cast is ambiguous
    /// by ear, the rows and Play-this-line carry the who.) Narrator lines
    /// are self-attributing text anyway.
    private func clipText(for line: RoomLine) -> String {
        line.text
    }

    /// Speak a line that JUST landed (autoplay path). Her own lines and
    /// empty lines never read back.
    private func autoplaySpeak(_ line: RoomLine) async {
        guard voicesOn, line.speaker != "user" else { return }
        let member = castMember(for: line)
        await voiceService.speakLine(
            text: clipText(for: line),
            voiceId: member?.voiceId,
            rate: member?.rate
        )
    }

    // MARK: - Auto-advance

    private func startAutoAdvance() {
        autoTask?.cancel()
        UIAccessibility.post(notification: .announcement, argument: "Keeping it going.")
        autoTask = Task {
            var turnsThisStretch = 0
            while !Task.isCancelled && autoAdvanceOn {
                if turnsThisStretch >= Self.autoBatchLimit {
                    autoAdvanceOn = false
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: "Paused after \(Self.autoBatchLimit) turns. Tap Keep it going to continue."
                    )
                    break
                }
                let succeeded = await advance(forcedAgentId: nil)
                if !succeeded {
                    autoAdvanceOn = false
                    break
                }
                turnsThisStretch += 1
                // A breath between speakers; longer when there's no voice
                // so VoiceOver users have time to hear the focused line.
                let beat: UInt64 = voicesOn ? 900_000_000 : 3_500_000_000
                try? await Task.sleep(nanoseconds: beat)
            }
        }
    }

    // MARK: - Actions

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
            Earcons.shared.play(.messageSent)
            KadeHaptics.tap()
        } catch {
            actionError = (error as? RoomService.RoomError)?.message ?? "Couldn't post your message. Try again."
            Earcons.shared.play(.error)
            KadeHaptics.error()
        }
    }

    /// One agent turn. Returns whether it landed — auto-advance stops on
    /// the first failure (including the server's own budget/day caps,
    /// whose messages are already plain language).
    @discardableResult
    private func advance(forcedAgentId: String?) async -> Bool {
        guard !isGeneratingTurn else { return false }
        isGeneratingTurn = true
        actionError = nil
        defer { isGeneratingTurn = false }
        do {
            let result = try await service.nextTurn(
                roomId: room.id,
                forcedAgentId: forcedAgentId,
                deepThink: deepThinkOn
            )
            await reload()
            Earcons.shared.play(.messageReceived)
            KadeHaptics.success()
            if voicesOn && result.line.speaker != "user" {
                // Session 35 part 6: the clip is the ONLY voice. No VO
                // focus grab (that made VoiceOver read the row over the
                // cast voice); eyes get a silent scroll instead, and the
                // row is right there when she browses. The clip plays to
                // the END before this returns, so auto-advance paces
                // itself on real listening.
                scrollTarget = transcript.indices.last
                await autoplaySpeak(result.line)
            } else {
                focusedLineIndex = transcript.indices.last
            }
            return true
        } catch {
            actionError = (error as? RoomService.RoomError)?.message ?? "That turn failed — give it another try."
            Earcons.shared.play(.error)
            KadeHaptics.error()
            return false
        }
    }
}

/// Add or remove characters mid-room (session 35 part 3). Removals keep
/// the room at two or more; additions cap at six; the server writes
/// Narrator lines into the transcript so the change is part of the story.
private struct ManageCastSheet: View {
    let service: RoomService
    let room: DebateRoom
    let onUpdated: (DebateRoom) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var roster: [RoomCastAgent] = []
    @State private var isLoadingRoster = true
    @State private var isWorking = false
    @State private var error: String?

    private var seatedIds: Set<String> { Set(room.agents.map(\.agentId)) }
    private var addable: [RoomCastAgent] { roster.filter { !seatedIds.contains($0.id) } }

    var body: some View {
        NavigationStack {
            List {
                Section("In the room now") {
                    ForEach(room.agents, id: \.agentId) { member in
                        HStack {
                            Text(member.name)
                            Spacer()
                            Button(role: .destructive) {
                                Task { await change(add: [], remove: [member.agentId]) }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .disabled(isWorking || room.agents.count <= 2)
                            .accessibilityLabel("Remove \(member.name)")
                            .accessibilityHint(room.agents.count <= 2
                                ? "A room needs at least two characters, so nobody can leave right now."
                                : "Takes \(member.name) out of the debate. The transcript keeps everything they said.")
                        }
                    }
                }
                Section(room.agents.count >= 6 ? "Room is full (six seats)" : "Add a character") {
                    if isLoadingRoster {
                        ProgressView("Loading characters")
                    } else if addable.isEmpty {
                        Text("Everyone castable is already in the room.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(addable) { agent in
                            Button {
                                Task { await change(add: [agent.id], remove: []) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.name)
                                    if !agent.description.isEmpty {
                                        Text(agent.description)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            .disabled(isWorking || room.agents.count >= 6)
                            .accessibilityHint("Seats \(agent.name) in the debate. They'll speak when their turn comes.")
                        }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Manage the cast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                roster = await service.loadCastableAgents()
                isLoadingRoster = false
            }
        }
    }

    private func change(add: [String], remove: [String]) async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let updated = try await service.editCast(roomId: room.id, add: add, remove: remove)
            KadeHaptics.success()
            onUpdated(updated)
            dismiss()
        } catch {
            self.error = (error as? RoomService.RoomError)?.message ?? "Couldn't change the cast. Try again."
            KadeHaptics.error()
        }
    }
}

/// The share/unshare sheet — a title (required only when sharing) plus a
/// single toggle-shaped action, matching the web page's own share flow
/// (`POST .../share {share, title}`).
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
