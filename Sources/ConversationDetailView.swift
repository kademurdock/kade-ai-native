import SwiftUI

/// Phase 2 reads history; Phase 3 adds sending a follow-up and waiting for
/// the agent's reply; Phase 4 adds switching which agent answers the next
/// message (see `AgentPickerView` for why that's purely client-side state).
/// Messages render in the order the server returns them (verified
/// chronological / parent-chain-consistent against a real thread) —
/// top-to-bottom oldest-to-newest, which is both the natural VoiceOver
/// swipe order and the natural reading order.
///
/// Session 11: `conversation` is now OPTIONAL -- `nil` means "brand new,
/// nothing sent yet" (Kade: "I don't see a way to make a new
/// conversation"). Rather than build a second, parallel screen that
/// duplicates all of this file's composer/voice/agent-picker machinery,
/// this same view now handles both cases: a nil conversation starts with
/// no history, no agent seeded (the picker is presented immediately since
/// there's no existing `agent_id` to inherit), and `conversationId`
/// (tracked separately from `conversation` itself) stays nil until the
/// FIRST send resolves one from the server -- see `MessageSendingService`'s
/// "NEW CONVERSATIONS" doc section for the exact server contract.
struct ConversationDetailView: View {
    let conversation: KadeConversation?
    @State private var conversationId: String?
    @EnvironmentObject private var conversationsService: ConversationsService
    @EnvironmentObject private var messageSendingService: MessageSendingService
    @EnvironmentObject private var agentsService: AgentsService
    @EnvironmentObject private var voiceService: VoiceService

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

    /// Phase 5: when on, each new assistant reply is spoken aloud
    /// automatically after it lands (queued through `VoiceService`, same
    /// read-aloud concept as the web app's Spotter rooms). Off by default,
    /// same reasoning as the web app's own per-message TTS controls being
    /// opt-in rather than ambient -- a blind user shouldn't get surprise
    /// audio the first time they open a conversation.
    @State private var readAloudEnabled = false
    @State private var voiceInputError: String?

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
        case composerField
        case voiceError
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
                    Text(conversationId == nil
                         ? "Pick an agent below, then send your first message to start chatting."
                         : "No messages in this conversation.")
                        .foregroundStyle(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    messageList
                }
            }
            if !isLoading && loadError == nil {
                agentSection
                readAloudToggle
                composer
            }
        }
        .navigationTitle(conversation?.displayTitle ?? "New conversation")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Seed the agent switcher from the conversation's own agent_id
            // the first time this view appears (not a custom init — see
            // "no custom init" note on `selectedAgentId`'s declaration).
            // A brand-new conversation has no agent_id to inherit -- leave
            // it nil and steer straight to the picker instead, since the
            // composer has nobody to send to otherwise.
            if selectedAgentId == nil {
                selectedAgentId = conversation?.agentId
            }
            if conversationId == nil {
                conversationId = conversation?.conversationId
            }
            if conversation != nil {
                await load()
            } else {
                isLoading = false
                showingAgentPicker = true
            }
            await agentsService.loadIfNeeded()
        }
        .sheet(isPresented: $showingAgentPicker) {
            AgentPickerView(currentAgentId: selectedAgentId) { agent in
                selectedAgentId = agent.id
                a11yFocus = .agentButton
            }
            .environmentObject(agentsService)
        }
        // Phase 7 (accessibility polish -- haptics, KADE_AI_iOS_ROADMAP_2026-
        // 07-15.md Phase B item 6: "a light haptic on key moments -- send,
        // recording start/stop, a reply landing"). One trigger (`sendState`,
        // already Equatable) covers all three send-related moments in one
        // place: a light tap-confirmation the instant Send is recognized, a
        // stronger one when a reply actually lands, and a distinct one on
        // failure -- non-visual, physical confirmation at each moment
        // instead of only a visual/audio cue. `old`/`new` discrimination
        // (rather than firing on every change) avoids a spurious buzz on,
        // say, idle -> sending firing twice or landing double-counting.
        .sensoryFeedback(trigger: sendState) { old, new in
            if case .idle = old, case .sending = new { return .impact(weight: .light) }
            if case .sending = old, case .idle = new { return .success }
            if case .failed = new { return .error }
            return nil
        }
        // Same Phase B ask, "recording start/stop" -- driven directly by
        // VoiceService's own published `isRecording` so this can never drift
        // from the mic button's own visual state. See VoiceService.
        // startRecording()'s setAllowHapticsAndSystemSoundsDuringRecording
        // fix, added alongside this -- without it, these two haptics
        // specifically are the ones most likely to have silently gone
        // physically dead once `.playAndRecord` took over the audio session.
        .sensoryFeedback(trigger: voiceService.isRecording) { _, isNowRecording in
            isNowRecording ? .start : .stop
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
            // Phase 7 (accessibility polish): two custom VoiceOver rotors so
            // a long back-and-forth can be crossed by sender instead of
            // swiping every row one at a time -- a genuinely useful shortcut
            // once a conversation has many turns, per
            // IOS_NATIVE_ADVANCED_TECHNIQUES_2026-07-19.md's
            // accessibilityRotor writeup (which cites Apple's own docs +
            // Swift with Majid's walkthrough). Each entry's `id` matches the
            // SAME `message.id` the ForEach above already uses -- the
            // documented-safe pattern that needs no separate Namespace /
            // accessibilityRotorEntry wiring, since SwiftUI matches rotor
            // entries to on-screen elements by that shared id.
            .accessibilityRotor("Your messages") {
                ForEach(messages.filter { $0.isCreatedByUser }) { message in
                    AccessibilityRotorEntry(rotorLabel(for: message), id: message.id)
                }
            }
            .accessibilityRotor("Replies") {
                ForEach(messages.filter { !$0.isCreatedByUser }) { message in
                    AccessibilityRotorEntry(rotorLabel(for: message), id: message.id)
                }
            }
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

    /// Short label for a custom-rotor entry (see `messageList`'s two
    /// `accessibilityRotor`s) -- deliberately terser than `MessageRow`'s own
    /// full accessibility label: the rotor you're already in ("Your
    /// messages" vs "Replies") tells VoiceOver which voice it's about to
    /// land on, so repeating "You said" / "X said" on every entry would
    /// just be noise while dialing through the rotor.
    private func rotorLabel(for message: KadeMessage) -> String {
        let time = KadeDateFormatting.time(from: message.createdAt) ?? ""
        let preview = message.displayText.isEmpty ? "…" : message.displayText
        let truncated = preview.count > 60 ? String(preview.prefix(60)) + "…" : preview
        return time.isEmpty ? truncated : "\(time): \(truncated)"
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
        // Only ever called with a real conversationId in hand (see .task
        // and errorState's Retry button) -- a brand-new conversation skips
        // load() entirely (nothing to fetch yet), so this guard is a
        // belt-and-suspenders no-op, not a path expected to actually fire.
        guard let conversationId else { return }
        isLoading = true
        loadError = nil
        do {
            messages = try await conversationsService.fetchMessages(
                conversationId: conversationId
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

    /// `conversation?.displayTitle` reads oddly before a new conversation
    /// has a real title yet ("Sends your message to New conversation."
    /// sounds like a typo) -- fall back to naming whoever's picked instead,
    /// which is the more useful thing to say in that moment anyway.
    private var conversationTitleForCopy: String {
        conversation?.displayTitle ?? agentDisplayLabel
    }

    // MARK: - Read aloud (Phase 5)

    /// A single toggle button (not a SwiftUI `Toggle`, to match this app's
    /// existing plain-`Button` accessibility pattern rather than mixing
    /// control styles) that turns automatic spoken replies on/off for this
    /// conversation. Turning it off mid-speech stops whatever's currently
    /// playing and drops anything still queued -- see
    /// `VoiceService.stopSpeaking()`.
    private var readAloudToggle: some View {
        Button {
            readAloudEnabled.toggle()
            if !readAloudEnabled {
                voiceService.stopSpeaking()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: readAloudEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                Text(readAloudEnabled ? "Read aloud: On" : "Read aloud: Off")
                    .font(.footnote)
                if voiceService.isSpeaking {
                    ProgressView().scaleEffect(0.7)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        // Session 11 (Kade: "it says off button on or on button off...
        // when you toggle it you can't tell if it's off or on"): baking
        // "on"/"off" INTO the label text while also carrying the
        // `.isToggle` trait is the bug -- VoiceOver expects a toggle's
        // current state in `.accessibilityValue`, separate from its name,
        // and announces both together ("Read aloud, on, switch button" for
        // example). With the state word living inside the label instead,
        // VoiceOver's own toggle narration and the hand-written label text
        // talked over each other. Fixed by giving the label just the NAME
        // and the state its own `.accessibilityValue` -- the standard,
        // unambiguous pattern every native iOS Settings toggle uses.
        .accessibilityLabel("Read aloud")
        .accessibilityValue(readAloudEnabled ? "On" : "Off")
        .accessibilityHint(
            readAloudEnabled
                ? "Turns off automatic spoken replies."
                : "Turns on automatic spoken replies. Each new reply from \(conversationTitleForCopy) will be read aloud in its own voice."
        )
        .accessibilityAddTraits(.isToggle)
    }

    // MARK: - Composer (Phase 3)

    private var isSending: Bool {
        if case .sending = sendState { return true }
        return false
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .failed(let message) = sendState {
                // Focus targets the Text directly (its own natural
                // accessibility element -- no wrapping needed, same
                // pattern as ContentView's sign-in error) rather than an
                // .accessibilityElement(children: .combine) around the
                // whole row: combining would have swallowed Retry's own
                // tap action, the same bug fixed in ConversationListView's
                // row/loadMoreRow/errorState this same session.
                HStack(alignment: .top) {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityFocused($a11yFocus, equals: .composerError)
                    Spacer()
                    Button("Retry") { Task { await send() } }
                        .font(.footnote.bold())
                }
            }
            if let voiceInputError {
                // Same pattern as the send-failure row above -- the Text
                // owns its own accessibility element and focus target so
                // nothing swallows a sibling control's tap action.
                Text(voiceInputError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityFocused($a11yFocus, equals: .voiceError)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draftText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .disabled(isSending || voiceService.isRecording || voiceService.isTranscribing)
                    .accessibilityLabel("Message")
                    .accessibilityFocused($a11yFocus, equals: .composerField)
                micButton
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(
                    isSending || voiceService.isRecording || voiceService.isTranscribing
                        || draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityLabel(isSending ? "Sending" : "Send message")
                .accessibilityHint(isSending ? "" : "Sends your message to \(conversationTitleForCopy).")
            }
        }
        .padding()
        .background(.bar)
    }

    /// Phase 5: tap to start recording, tap again to stop -- deliberately
    /// NOT a press-and-hold push-to-talk gesture. VoiceOver users activate
    /// controls with a double-tap, and a screen-reader user can't easily
    /// "hold down" a control the way a sighted user holds a button under
    /// their finger; a plain tap-to-toggle is the reliable, predictable
    /// interaction for this audience, matching every other control in this
    /// app. Recording auto-stops after 60 seconds as a safety net against
    /// an accidental open-ended recording nobody remembers to stop.
    private var micButton: some View {
        Button {
            Task { await toggleRecording() }
        } label: {
            Group {
                if voiceService.isTranscribing {
                    ProgressView()
                } else if voiceService.isRecording {
                    Image(systemName: "stop.circle.fill")
                } else {
                    Image(systemName: "mic.circle.fill")
                }
            }
            .font(.title)
            .foregroundStyle(voiceService.isRecording ? .red : .accentColor)
        }
        .disabled(isSending || voiceService.isTranscribing)
        .accessibilityLabel(micAccessibilityLabel)
        .accessibilityHint(
            voiceService.isRecording
                ? "Stops recording and fills your message with what you said."
                : "Records your voice and turns it into a message you can review before sending."
        )
    }

    private var micAccessibilityLabel: String {
        if voiceService.isTranscribing { return "Transcribing your recording" }
        if voiceService.isRecording { return "Stop recording" }
        return "Record a voice message"
    }

    private func send() async {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        // A brand-new conversation has no agent_id for the server to fall
        // back on (an EXISTING conversation's turns can omit it and the
        // server still knows who's answering, per its own stored history --
        // unchanged behavior, still passes `selectedAgentId` as-is below,
        // nil or not). A new one genuinely has nobody picked yet the very
        // first time through, so require it instead of sending into the
        // void.
        if conversation == nil, selectedAgentId == nil {
            showingAgentPicker = true
            return
        }

        let parentId = messages.last?.messageId
        let optimisticMessage = KadeMessage(
            messageId: "pending-\(UUID().uuidString)",
            conversationId: conversationId ?? "pending",
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
            let wasNewConversation = conversationId == nil
            let resolvedConversationId = try await messageSendingService.send(
                text: trimmed,
                conversationId: conversationId,
                parentMessageId: parentId,
                agentId: selectedAgentId
            )
            conversationId = resolvedConversationId
            // Authoritative reload: replaces the optimistic placeholder with
            // whatever the server actually persisted (real ids, real content
            // shape) rather than trusting the SSE payload's exact field set
            // — see MessageSendingService's type doc for why.
            messages = try await conversationsService.fetchMessages(
                conversationId: resolvedConversationId
            )
            sendState = .idle
            a11yFocus = messages.last.map { .message($0.id) }
            if readAloudEnabled, let reply = messages.last, !reply.isCreatedByUser {
                voiceService.enqueueSpeak(text: reply.displayText, agentId: selectedAgentId, agentName: agentDisplayLabel)
            }
            if wasNewConversation {
                // The conversation list (one screen back) doesn't know this
                // conversation exists yet -- refresh it in the background so
                // it's already there by the time the user navigates back,
                // instead of requiring a manual pull-to-refresh.
                Task { await conversationsService.loadFirstPage() }
            }
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

    // MARK: - Voice input (Phase 5)

    private func toggleRecording() async {
        if voiceService.isRecording {
            await finishRecording()
            return
        }
        voiceInputError = nil
        let started = await voiceService.startRecording()
        guard started else {
            voiceInputError = voiceService.recordError ?? "Couldn't start recording. Try again."
            a11yFocus = .voiceError
            return
        }
        // Safety net: auto-stop after 60s so an accidental open-ended
        // recording (VoiceOver focus moving elsewhere before a second tap
        // lands, a call coming in, etc.) doesn't run forever.
        // `VoiceService.stopRecording()` guards on `isRecording` itself, so
        // this can never double-finish a recording the user already
        // stopped manually -- calling it again here is always safe.
        Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if voiceService.isRecording {
                await finishRecording()
            }
        }
    }

    private func finishRecording() async {
        guard let url = voiceService.stopRecording() else { return }
        do {
            let text = try await voiceService.transcribe(fileURL: url)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                voiceInputError = "Didn't catch that. Try recording again."
                a11yFocus = .voiceError
                return
            }
            // Lands in the composer for review rather than auto-sending --
            // STT is not perfect (a live test this session mis-heard
            // "Keighty" as "Katie"), so the user always gets a chance to
            // hear/read what was transcribed and fix or confirm it before
            // it goes anywhere, exactly like iOS's own built-in dictation.
            draftText = text
            voiceInputError = nil
            a11yFocus = .composerField
        } catch let error as VoiceService.VoiceError {
            voiceInputError = error.message
            a11yFocus = .voiceError
        } catch {
            voiceInputError = "Couldn't understand that. Try again."
            a11yFocus = .voiceError
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
