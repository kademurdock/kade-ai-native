import SwiftUI

/// Phase 2: reads one conversation's history. Messages render in the order
/// the server returns them (verified chronological / parent-chain-consistent
/// against a real thread) — top-to-bottom oldest-to-newest, which is both
/// the natural VoiceOver swipe order and the natural reading order.
struct ConversationDetailView: View {
    let conversation: KadeConversation
    @EnvironmentObject private var conversationsService: ConversationsService

    @State private var messages: [KadeMessage] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading messages…")
                    .accessibilityLabel("Loading messages")
            } else if let loadError {
                errorState(loadError)
            } else if messages.isEmpty {
                Text("No messages in this conversation.")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                messageList
            }
        }
        .navigationTitle(conversation.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onAppear {
                // Land where a chat app normally lands: the most recent
                // message. VoiceOver users can freely swipe backward through
                // the full history from here — nothing is hidden, this only
                // affects initial scroll position. Deferred a tick because
                // scrollTo called synchronously in onAppear can silently
                // no-op before LazyVStack has laid out the last row.
                guard let lastId = messages.last?.id else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
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
