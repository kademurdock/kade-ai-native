import SwiftUI

/// Phase 2 reads history; Phase 3 adds sending a follow-up and waiting for
/// the agent's reply; Phase 4 adds switching which agent answers the next
/// message (see `AgentPickerView` for why that's purely client-side state).
/// Messages render in the order the server returns them (verified
/// chronological / parent-chain-consistent against a real thread) —
/// top-to-bottom oldest-to-newest, which is both the natural VoiceOver
/// swipe order and the natural reading order.
struct ConversationDetailView: View {
    let conversation: KadeConversation
    @EnvironmentObject private var conversationsService: ConversationsService
    @EnvironmentObject private var messageSendingService: MessageSendingService
    @EnvironmentObject private var agentsService: AgentsService

    @State private var messages: [KadeMessage] = []
    @State private var isLoading = true
    @State private var loadError: String?

    @State private var draftText: String = ""
    @State private var sendState: SendState = .idle

    /// Which agent answers the NEXT send. Seeded from the conversation's
    /// own `agent_id` (Phase 2 data) in `body`'s `.task` — not a custom
    /// init, deliberately: this file has no compiler available to verify a
    /// hand-written init assigns every `@State` property correctly (several
    /// have inline defaults like `= []` that a custom init would silently
    /// need to preserve), so seeding via a plain bare-Optional `@State` +
    /// a `.task`-time assignment (same bare-Optional style already used by
    /// `loadError` above) avoids that whole class of risk for one extra
    /// `if` check. Tracked as local UI state from here on — the server has
    /// no per-conversation "current agent" concept to sync back against; it
    /// just reads whatever `agent_id` each send request carries (see
    /// `AgentPickerView`'s doc comment).
    @State private var selectedAgentId: String?
    @State private var showingAgentPicker = false

    private enum SendState: Equatable {
        case idle
        case sending
        case failed(String)
    }

    /// VoiceOver focus targets. On a successful send, focus jumps to the
    /// new reply so the user hears it without hunting for it; on a failed
    /// send, focus jumps to the error instead; after switching agents,
    /// focus returns to the agent button so the new selection is announced.
    private enum A11yFocus: Hashable {
        case message(String)
        case composerError
        case agentButton
    }
    @AccessibilityFocusState private var a11yFocus: A11yFocus?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isLoading {
                    ProgressView("Loading messages…")
                        .accessibilityLabel("Loading messages")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    errorState(loadError)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if messages.isEmpty {
                    Text("No messages in this conversation.")
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    messageList
                }
            }
            if !isLoading && loadError == nil {
                agentSection
                composer
            }
        }
        .navigationTitle(conversation.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Seed the agent switcher from the conversation's own agent_id
            // the first time this view appears (not a custom init — see
            // "no custom init" note on `selectedAgentId`'s declaration).
            if selectedAgentId == nil {
                selectedAgentId = conversation.agentId
            }
            await load()
            await agentsService.loadIfNeeded()
        }
        .sheet(isPresented: $showingAgentPicker) {
            AgentPickerView(currentAgentId: selectedAgentId) { agent in
                selectedAgentId = agent.id
                a11yFocus = .agentButton
            }
            .environmentObject(agentsService)
        }
    }

    // MARK: - History

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                            .accessibilityFocused($a11yFocus, equals: .message(message.id))
                    }
                    if case .sending = sendState {
                        replyingRow.id(Self.replyingRowId)
                    }
                }
                .padding()
            }
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: sendState) { _, _ in scrollToBottom(proxy) }
        }
    }

    private static let replyingRowId = "replying-indicator"

    private var replyingRow: some View {
        let who = messages.last(where: { !$0.isCreatedByUser })?.speakerLabel ?? "The assistant"
        return HStack(spacing: 8) {
            ProgressView()
            Text("\(who) is replying…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(who) is replying")
    }

    /// Deferred a tick because `scrollTo` called synchronously can silently
    /// no-op before LazyVStack has laid out the newest row — same reasoning
    /// as Phase 2's original onAppear scroll.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let target: String? = {
            if case .sending = sendState { return Self.replyingRowId }
            return messages.last?.id
        }()
        guard let target else { return }
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message).multilineTextAlignment(.center)
            Button("Try again") { Task { await load() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            messages = try await conversationsService.fetchMessages(
                conversationId: conversation.conversationId
            )
        } catch {
            loadError = "Couldn't load this conversation. Check your connection and try again."
        }
        isLoading = false
    }

    // MARK: - Agent switcher (Phase 4)

    /// A single row above the composer showing who will answer next, with a
    /// tap target to open `AgentPickerView`. Disabled while a send is in
    /// flight — switching mid-wait wouldn't affect the reply already
    /// requested, only the confusion of tapping something that visibly does
    /// nothing to it.
    private var agentSection: some View {
        Button {
            showingAgentPicker = true
        } label: {
            HStack {
                Text(agentDisplayLabel)
                    .font(.footnote)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(isSending)
        .padding(.horizontal)
        .padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Talking to \(agentDisplayLabel)")
        .accessibilityHint("Opens the list of agents to switch who answers your next message.")
        .accessibilityFocused($a11yFocus, equals: .agentButton)
    }

    private var agentDisplayLabel: String {
        if let selectedAgentId, let name = agentsService.name(for: selectedAgentId) {
            return name
        }
        if agentsService.isLoading { return "Loading…" }
        return selectedAgentId == nil ? "No agent selected" : "Current agent"
    }

    // MARK: - Composer (Phase 3)

    private var isSending: Bool {
        if case .sending = sendState { return true }
        return false
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .failed(let message) = sendState {
                HStack(alignment: .top) {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Retry") { Task { await send() } }
                        .font(.footnote.bold())
                }
                .accessibilityElement(children: .combine)
                .accessibilityFocused($a11yFocus, equals: .composerError)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draftText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .disabled(isSending)
                    .accessibilityLabel("Message")
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(isSending || draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(isSending ? "Sending" : "Send message")
                .accessibilityHint(isSending ? "" : "Sends your message to \(conversation.displayTitle).")
            }
        }
        .padding()
        .background(.bar)
    }

    private func send() async {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }

        let parentId = messages.last?.messageId
        let optimisticMessage = KadeMessage(
            messageId: "pending-\(UUID().uuidString)",
            conversationId: conversation.conversationId,
            createdAt: KadeDateFormatting.isoNow(),
            isCreatedByUser: true,
            sender: "User",
            text: trimmed,
            content: nil
        )
        messages.append(optimisticMessage)
        draftText = ""
        sendState = .sending

        do {
            try await messageSendingService.send(
                text: trimmed,
                conversationId: conversation.conversationId,
                parentMessageId: parentId,
                agentId: selectedAgentId
            )
            // Authoritative reload: replaces the optimistic placeholder with
            // whatever the server actually persisted (real ids, real content
            // shape) rather than trusting the SSE payload's exact field set
            // — see MessageSendingService's type doc for why.
            messages = try await conversationsService.fetchMessages(
                conversationId: conversation.conversationId
            )
            sendState = .idle
            a11yFocus = messages.last.map { .message($0.id) }
        } catch let error as MessageSendingService.SendError {
            if case .streamError(let message) = error {
                sendState = .failed(message)
            } else {
                sendState = .failed("Didn't get a reply. Check your connection and try again.")
            }
            a11yFocus = .composerError
        } catch {
            // The optimistic message stays visible on purpose: it really was
            // sent from the user's point of view, only the "did the reply
            // come back" half failed.
            sendState = .failed("Didn't get a reply. Check your connection and try again.")
            a11yFocus = .composerError
        }
    }
}

/// One message. VoiceOver reads speaker + time + body as a single element
/// with deliberate phrasing ("You said: …" / "Kiana said: …") rather than
/// letting auto-combination stitch together whatever order the subviews
/// happen to be in.
private struct MessageRow: View {
    let message: KadeMessage

    private var timeLabel: String {
        KadeDateFormatting.time(from: message.createdAt) ?? ""
    }

    private var bodyText: String {
        message.displayText.isEmpty ? "…" : message.displayText
    }

    var body: some View {
        VStack(alignment: message.isCreatedByUser ? .trailing : .leading, spacing: 4) {
            Text(message.speakerLabel)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(bodyText)
                .font(.body)
                .multilineTextAlignment(message.isCreatedByUser ? .trailing : .leading)
            if !timeLabel.isEmpty {
                Text(timeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isCreatedByUser ? .trailing : .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleLabel)
    }

    private var accessibleLabel: String {
        let who = message.isCreatedByUser ? "You said" : "\(message.speakerLabel) said"
        let time = timeLabel.isEmpty ? "" : ", \(timeLabel)"
        return "\(who)\(time): \(bodyText)"
    }
}
