import Foundation
import SwiftUI
import UIKit

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
    /// Preselects who answers a brand-new conversation's first message --
    /// used by `MatchmakerView`'s "Start talking to X" (session 17/18) so
    /// picking a match doesn't dead-end at the ordinary agent-picker sheet
    /// a plain new conversation shows. `nil` (every pre-existing call
    /// site) is the ordinary, unchanged behavior. A plain stored `let`
    /// with a default, not `@State` -- extends the same compiler-
    /// synthesized memberwise init this file already relies on for
    /// `conversation`, so it needs none of the hand-written-init care the
    /// "no custom init" note on `selectedAgentId` below warns about.
    /// Deliberately `var`, not `let`: a `let` WITH a default value is
    /// excluded from the synthesized memberwise init entirely (it's
    /// already initialized and immutable, so the init cannot set it) --
    /// which made `ConversationDetailView(conversation:, initialAgentId:)`
    /// fail to compile with "extra argument." A `var` with a default is
    /// included as a defaulted parameter, which is exactly what's wanted:
    /// every existing call site omits it (gets nil), Matchmaker passes it.
    /// Never actually mutated after init.
    var initialAgentId: String? = nil
    /// True only for the ONE call site below that presents a fresh
    /// instance of this very view as the ROOT of its own sheet-hosted
    /// `NavigationStack` (the post-call transcript handoff). That instance
    /// has nothing beneath it on its stack, so SwiftUI shows no back
    /// chevron at all -- and with no other dismiss control, a VoiceOver
    /// user lands on a screen with a title, then straight into message
    /// content, with no way out except an undiscoverable two-finger
    /// scrub gesture (Kade, session 17: "there's no way for voiceover to
    /// get out of that screen"). This flag adds an explicit, accessible
    /// "Close" button in that one case only; every other call site omits
    /// it (defaults to `false`) and keeps relying on the real back button
    /// a normal push provides. `var` with a default, not `let`, for the
    /// same memberwise-init reason documented on `initialAgentId` above.
    var isStandalonePresentation: Bool = false
    @State private var conversationId: String?
    @EnvironmentObject private var conversationsService: ConversationsService
    @EnvironmentObject private var messageSendingService: MessageSendingService
    @EnvironmentObject private var agentsService: AgentsService
    @EnvironmentObject private var voiceService: VoiceService
    @EnvironmentObject private var apiClient: KadeAPIClient
    /// Only actually dismisses anything when this view is the root of a
    /// sheet-presented `NavigationStack` (see `isStandalonePresentation`
    /// above) -- harmless to declare unconditionally otherwise.
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [KadeMessage] = []
    @State private var isLoading = true
    @State private var loadError: String?

    @State private var draftText: String = ""
    @State private var sendState: SendState = .idle
    /// The currently in-flight `send()`/`retry()`/`regenerate()` Task, if
    /// any -- session 17's Stop button cancels whichever one is actually
    /// running rather than needing three separate stop paths, since all
    /// three fund into the same `performSend` and set the same `sendState`.
    /// Never awaited directly; only ever cancelled or silently overwritten
    /// by the next send.
    @State private var sendTask: Task<Void, Never>?

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

    /// Non-nil only in the brief window between tapping "Edit and Resend"
    /// on the last user message (`MessageRow`'s actions menu) and the next
    /// `send()` call: overrides which message the new turn branches from
    /// (see `beginEdit(_:)`). `nil` is the normal case -- reply to
    /// whatever's currently last.
    @State private var sendParentOverride: String?
    // Session 13 ("calling and spotters"): real-time voice/Spotter call,
    // presented full-screen so an accidental swipe-down can't drop the
    // call the way dismissing a .sheet would.
    @State private var showingCall = false

    /// What a FAILED send was trying to do -- captured so "Retry" can
    /// resend the identical (text, parent) pair directly. Added this
    /// session fixing a real dead-button bug: Retry used to call `send()`,
    /// which reads `draftText` -- but `draftText` is deliberately cleared
    /// the INSTANT any send starts (the standard "message left the
    /// composer" optimistic feel), so by the time a failure ever showed
    /// the Retry button, `draftText` was already "". `send()`'s own
    /// `guard !trimmed.isEmpty` then made every tap of Retry return
    /// instantly and do nothing -- no error, no change, just silence,
    /// which is a particularly bad failure mode for someone navigating by
    /// ear with no visual cue that "nothing happened" is even what
    /// happened. See `retry()` below.
    private struct FailedAttempt {
        let text: String
        let parentId: String?
    }
    @State private var failedAttempt: FailedAttempt?

    /// Phase 5: when on, each new assistant reply is spoken aloud
    /// automatically after it lands (queued through `VoiceService`, same
    /// read-aloud concept as the web app's Spotter rooms). Off by default,
    /// same reasoning as the web app's own per-message TTS controls being
    /// opt-in rather than ambient -- a blind user shouldn't get surprise
    /// audio the first time they open a conversation.
    @State private var readAloudEnabled = false
    /// Session 23 (Kade: "no deepthink switch on native iOS. That's not
    /// good at all."): parity with the web composer's sticky Deep Think
    /// toggle (DeepThinkToggle.tsx). While armed, every FRESH send gets an
    /// invisible, freshly-timestamped "[DEEP THINK <ms>]" marker appended;
    /// reframe-proxy runs those turns at reasoning-effort high, and
    /// deliberately ignores STALE timestamps -- which is why the marker is
    /// stamped at send time and never re-sent from history (regenerate and
    /// edit-resend go through displayText, which MessageTextSanitizer
    /// already strips). Sticky for the app RUN via the static below,
    /// mirroring the web's per-tab stickiness rather than persisting
    /// across launches -- "why is she slow today" days later would be the
    /// wrong kind of surprise. Display side needs nothing new: the
    /// sanitizer has stripped [DEEP THINK] markers since the web feature
    /// shipped.
    @MainActor private static var deepThinkArmedGlobal = false
    @State private var deepThinkArmed = false

    // Session 14 additions. `ShareItem` wraps either plain text or a
    // prepared audio file so ONE share sheet serves both "Share Text" and
    // "Save Voice Message" -- the iOS share sheet is already the
    // system-standard, fully VoiceOver-navigable way to reach "Save to
    // Files", AirDrop, Messages and everything else, so building a bespoke
    // download UI on top of it would be strictly worse and less familiar.
    /// ONE sheet binding for this screen, not several. Chaining multiple
    /// `.sheet` modifiers at the same level in the hierarchy is unreliable
    /// in SwiftUI -- a later one can simply win and the earlier ones never
    /// present -- and this view now has two things it may want to show
    /// (a share sheet, and the transcript of a call that just ended). An
    /// enum with a single binding is the standard, provably-unambiguous
    /// shape, and it makes "what can this screen present?" answerable by
    /// reading one type.
    @State private var activeSheet: DetailSheet?
    @State private var voiceOverride = ""
    @State private var preparingVoiceMessageId: String?
    @State private var deletingMessage: KadeMessage?
    @State private var showingSpeedPicker = false

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
        .toolbar {
            // Session 17 VoiceOver-trap fix: the post-call transcript sheet
            // (see `isStandalonePresentation` above) is the root of its own
            // NavigationStack, so there is no back chevron to fall back on
            // here -- this button is the ONLY accessible way out of that
            // specific presentation. Every other call site leaves the flag
            // `false` and this item simply never appears, so the ordinary
            // pushed screens are unchanged.
            if isStandalonePresentation {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                        .accessibilityHint("Closes this transcript and returns to your call.")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                // Session 21g: change the voice THIS agent speaks in, per the
                // "agent maker sets it, user changes it once they get it"
                // model. The pick is saved per-user, per-agent, so it follows
                // the account everywhere -- read-aloud here, and calls.
                Button {
                    activeSheet = .voicePicker
                    if let id = selectedAgentId {
                        Task { voiceOverride = (await voiceService.voiceOverride(forAgent: id)) ?? "" }
                    }
                } label: {
                    Image(systemName: "waveform")
                }
                .disabled(selectedAgentId == nil)
                .accessibilityLabel("Voice")
                .accessibilityHint("Browse, preview, and change the voice \(agentDisplayLabel) speaks in. Your pick follows this companion.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCall = true
                } label: {
                    Image(systemName: "phone.fill")
                }
                .disabled(selectedAgentId == nil)
                .accessibilityLabel("Call \(agentDisplayLabel)")
                .accessibilityHint("Starts a real-time voice call. You can bring in your Spotter once connected.")
            }
        }
        .task {
            // Session 17 (Kade: "a native way to access settings like
            // speech and whatnot"): seed this view's own "Voice messages"
            // toggle from the persisted app-wide default the FIRST time
            // this instance appears -- every ConversationDetailView
            // instance started this at a hardcoded `false` before this,
            // so there is no existing per-conversation choice this could
            // ever clobber; it only changes what the starting point is.
            readAloudEnabled = voiceService.defaultReadAloudOn
            deepThinkArmed = Self.deepThinkArmedGlobal
            // Seed the agent switcher from the conversation's own agent_id
            // the first time this view appears (not a custom init — see
            // "no custom init" note on `selectedAgentId`'s declaration).
            // A brand-new conversation has no agent_id to inherit -- leave
            // it nil and steer straight to the picker instead, since the
            // composer has nobody to send to otherwise.
            if selectedAgentId == nil {
                selectedAgentId = conversation?.agentId ?? initialAgentId
            }
            if conversationId == nil {
                conversationId = conversation?.conversationId
            }
            if conversation != nil {
                await load()
            } else {
                isLoading = false
                if selectedAgentId == nil {
                    activeSheet = .agentPicker
                }
            }
            await agentsService.loadIfNeeded()
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
            // Session 20: haptics gated through the app-wide Haptics switch.
            if case .idle = old, case .sending = new { return FeedbackPrefs.gate(.impact(weight: .light)) }
            if case .sending = old, case .idle = new { return FeedbackPrefs.gate(.success) }
            if case .failed = new { return FeedbackPrefs.gate(.error) }
            return nil
        }
        // Session 20 earcons: the same three send moments get a short,
        // gentle non-speech sound (honouring the Sound effects switch),
        // COMPLEMENTING -- never replacing -- VoiceOver's own spoken cue.
        .onChange(of: sendState) { old, new in
            if case .idle = old, case .sending = new { Earcons.shared.play(.messageSent) }
            else if case .sending = old, case .idle = new { Earcons.shared.play(.messageReceived) }
            else if case .failed = new { Earcons.shared.play(.error) }
        }
        // Same Phase B ask, "recording start/stop" -- driven directly by
        // VoiceService's own published `isRecording` so this can never drift
        // from the mic button's own visual state. See VoiceService.
        // startRecording()'s setAllowHapticsAndSystemSoundsDuringRecording
        // fix, added alongside this -- without it, these two haptics
        // specifically are the ones most likely to have silently gone
        // physically dead once `.playAndRecord` took over the audio session.
        .sensoryFeedback(trigger: voiceService.isRecording) { _, isNowRecording in
            FeedbackPrefs.gate(isNowRecording ? .start : .stop)
        }
        .fullScreenCover(isPresented: $showingCall) {
            CallView(
                agentId: selectedAgentId,
                agentName: agentDisplayLabel,
                apiClient: apiClient,
                onOpenTranscript: { convo in
                    activeSheet = .transcript(ChatTranscriptHandoff(conversation: convo))
                }
            )
        }
        // Post-call handoff (Kade, session 14: "It doesn't drop you into
        // your current voice conversation via text after the call"). The
        // call screen resolves the minted conversation before it dismisses;
        // this is what actually puts her in it.
        //
        // PRESENTED AS A SHEET, NOT PUSHED, AND THAT IS THE WHOLE POINT.
        // This is the fix for the regression Kade hit on build 121 ("once
        // again, it's not letting me click on conversations").
        // `.navigationDestination(item:)` registers its destination by the
        // item's TYPE for the entire enclosing NavigationStack, and build
        // 121 shipped three of them all bound to `KadeConversation?` -- this
        // one, ContentView's Spotter handoff, and the conversation list's
        // own row selection. SwiftUI honoured one and silently ignored the
        // rest; the list's row taps were the casualty.
        //
        // ContentView's handoff is now its own type and stays a push (it is
        // declared exactly once, at the root). THIS one can't safely be a
        // push at any type, because `ConversationDetailView` is RECURSIVE --
        // opening a transcript from a chat means a second instance of this
        // very view in the same stack, re-declaring the same destination and
        // re-creating the collision one level down. A sheet has no
        // type-keyed registration at all, so the problem cannot come back,
        // and it reads better anyway: the call transcript opens over the
        // conversation you were in, and dismissing returns you exactly where
        // you were rather than deeper in a stack you have to climb out of.
        // The ONE sheet this screen presents. The agent picker used to have
        // its own chained `.sheet` alongside this; folding it in is not
        // tidiness for its own sake -- two `.sheet` modifiers at the same
        // level in a SwiftUI hierarchy is genuinely unreliable, one can
        // simply win and the other never present, and the picker is far too
        // important to leave exposed to that.
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .agentPicker:
                AgentPickerView(currentAgentId: selectedAgentId) { agent in
                    selectedAgentId = agent.id
                    a11yFocus = .agentButton
                }
                .environmentObject(agentsService)
            case .transcript(let handoff):
                NavigationStack {
                    ConversationDetailView(
                        conversation: handoff.conversation,
                        isStandalonePresentation: true
                    )
                }
            case .share(let item):
                ShareSheet(item: item)
            case .voicePicker:
                VoicePickerView(apiClient: apiClient, selection: $voiceOverride)
            }
        }
        // Save the user's voice pick for the current agent whenever it
        // changes in the picker. Idempotent: setUserVoiceOverride no-ops if
        // the value hasn't actually changed (e.g. the seed on open).
        .onChange(of: voiceOverride) { _, v in
            guard let id = selectedAgentId else { return }
            Task {
                await voiceService.setUserVoiceOverride(agentId: id, voice: v.isEmpty ? nil : v)
                if !v.isEmpty {
                    UIAccessibility.post(notification: .announcement, argument: "\(agentDisplayLabel) will now speak in \(v).")
                }
            }
        }
        .alert(
            "Delete this message?",
            isPresented: Binding(
                get: { deletingMessage != nil },
                set: { if !$0 { deletingMessage = nil } }
            ),
            presenting: deletingMessage
        ) { message in
            Button("Delete", role: .destructive) {
                deletingMessage = nil
                Task { await deleteMessage(message) }
            }
            Button("Keep it", role: .cancel) { deletingMessage = nil }
        } message: { _ in
            Text("This removes the single message for good. Anything replying to it stays.")
        }
        .confirmationDialog(
            "Voice message speed",
            isPresented: $showingSpeedPicker,
            titleVisibility: .visible
        ) {
            ForEach(VoiceService.availableRates, id: \.self) { rate in
                Button(VoiceService.rateSpokenLabel(rate)) {
                    voiceService.playbackRate = rate
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: "Voice message speed \(VoiceService.rateSpokenLabel(rate))."
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: conversationsService.actionMessage) { _, message in
            guard let message else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
            conversationsService.actionMessage = nil
        }
    }

    // MARK: - Session 14 actions

    /// Delete is offered only on the last two messages. See
    /// `ConversationsService.deleteMessage`'s doc comment: this client
    /// renders the flat chronological line, so deleting from the middle
    /// would strand a reply answering a question that no longer exists.
    private func canDelete(_ message: KadeMessage) -> Bool {
        guard !isSending else { return false }
        return messages.suffix(2).contains { $0.id == message.id }
    }

    private func deleteMessage(_ message: KadeMessage) async {
        guard let conversationId else { return }
        let ok = await conversationsService.deleteMessage(
            conversationId: conversationId, messageId: message.messageId
        )
        if ok {
            messages.removeAll { $0.id == message.id }
        }
    }

    /// Synthesizes the message in its own agent's voice, writes it to a real
    /// file, and hands it to the system share sheet -- which is where "Save
    /// to Files" lives, along with AirDrop, Messages and everything else.
    /// Announces progress at both ends because synthesis takes a beat and a
    /// silent wait is indistinguishable from a dead button.
    private func saveVoiceMessage(_ message: KadeMessage) async {
        guard preparingVoiceMessageId == nil else { return }
        preparingVoiceMessageId = message.id
        UIAccessibility.post(notification: .announcement, argument: "Preparing the voice message.")
        defer { preparingVoiceMessageId = nil }
        let url = await voiceService.voiceMessageFile(
            text: message.displayText,
            agentId: message.agentId ?? selectedAgentId,
            agentName: message.speakerLabel
        )
        guard let url else {
            UIAccessibility.post(
                notification: .announcement,
                argument: "Couldn't prepare that voice message. Try again."
            )
            return
        }
        activeSheet = .share(ShareItem(fileURL: url))
    }

    // MARK: - History

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { message in
                        MessageRow(
                            message: message,
                            canEdit: canEdit(message),
                            canRegenerate: canRegenerate(message),
                            onReadAloud: { readAloud(message) },
                            onEdit: { beginEdit(message) },
                            onRegenerate: { sendTask = Task { await regenerate(message) } },
                            onSaveVoiceMessage: { Task { await saveVoiceMessage(message) } },
                            onShare: { activeSheet = .share(ShareItem(text: message.readableText)) },
                            onDelete: canDelete(message) ? { deletingMessage = message } : nil,
                            isPreparingVoiceMessage: preparingVoiceMessageId == message.id
                        )
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
            // Session 20 visual flair: a soft pulsing dot while a reply is in
            // flight. Purely decorative -- KadePulseDot is accessibilityHidden
            // and collapses to a static dot under Reduce Motion, so VoiceOver
            // and motion-sensitive users are untouched.
            KadePulseDot(color: .accentColor, diameter: 8, active: true, haptic: true)
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
        let preview = message.readableText.isEmpty ? "…" : message.readableText
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
            activeSheet = .agentPicker
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
        // Session 22 LIVE BUG (Amber A, first-day tester: "can't get the
        // voice message auto play button to toggle with voiceover"): this
        // row used to be ONE Button whose label CONTAINED the speed button,
        // flattened with .accessibilityElement(children: .ignore). Replacing
        // a Button's own element that way costs it DIRECT VoiceOver
        // activation -- double-tap falls back to a synthesized tap at the
        // element's activation point, and where that point lands shifts
        // with text size and with the progress spinner appearing. On Kade's
        // phone it hit the toggle; on Amber's it didn't. Restructured: the
        // toggle is a plain Button carrying its own accessibility (a Button
        // flattens its label natively and keeps direct, layout-independent
        // activation -- no children:.ignore needed or wanted), and the
        // speed control is a true SIBLING element instead of living inside
        // the toggle's flattened shadow. The session-11 name-vs-state
        // pattern (label "Voice messages", value On/Off) is unchanged.
        HStack(spacing: 6) {
            Button {
                readAloudEnabled.toggle()
                if !readAloudEnabled {
                    voiceService.stopSpeaking()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: readAloudEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                    Text(readAloudEnabled ? "Voice messages: On" : "Voice messages: Off")
                        .font(.footnote)
                    if voiceService.isSpeaking {
                        ProgressView().scaleEffect(0.7)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Voice messages")
            .accessibilityValue(readAloudEnabled ? "On" : "Off")
            .accessibilityHint(
                readAloudEnabled
                    ? "Turns off automatic voice messages."
                    : "Turns on automatic voice messages. Each new reply from \(conversationTitleForCopy) will play as a voice message in its own voice."
            )
            .accessibilityAddTraits(.isToggle)
            .sensoryFeedback(trigger: readAloudEnabled) { _, _ in
                FeedbackPrefs.gate(.selection)
            }

            Spacer()

            speedButton
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    /// Playback-speed control, sitting beside the voice-messages toggle
    /// because that is where someone already is when they decide a voice is
    /// too slow. Its own sibling accessibility element, never combined into
    /// the toggle (same house rule as everywhere else here), and it reads
    /// its current value rather than burying it in the label -- the exact
    /// fix session 11 made to the toggle itself.
    ///
    /// Applied client-side via `AVAudioPlayer.rate`, NOT by asking the TTS
    /// service to synthesize faster: re-synthesizing would re-bill every
    /// clip and would change the voice's actual prosody rather than just
    /// how fast it plays.
    private var speedButton: some View {
        Button {
            showingSpeedPicker = true
        } label: {
            Text(VoiceService.rateLabel(voiceService.playbackRate))
                .font(.footnote.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.5)))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voice message speed")
        .accessibilityValue(VoiceService.rateSpokenLabel(voiceService.playbackRate))
        .accessibilityHint("Double-tap to change how fast voice messages play.")
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
                    Button("Retry") { sendTask = Task { await retry() } }
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
                deepThinkButton
                TextField("Message", text: $draftText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .disabled(isSending || voiceService.isRecording || voiceService.isTranscribing)
                    .accessibilityLabel("Message")
                    .accessibilityFocused($a11yFocus, equals: .composerField)
                micButton
                // Session 17: one button, two jobs, matching how `isSending`
                // already gates it -- Send while idle, Stop while a reply is
                // generating (`POST /api/agents/chat/abort` had sat
                // "source-confirmed, not yet wired into the app" in
                // docs/ENDPOINTS.md since Phase 3; see `stopGenerating()`
                // and `MessageSendingService.abortActive()`). Recording/
                // transcribing/empty-draft still block a SEND, but never
                // block a STOP -- those three conditions describe whether
                // there's anything sendABLE, which is irrelevant once
                // something is already sending.
                Button {
                    if isSending {
                        stopGenerating()
                    } else {
                        sendTask = Task { await send() }
                    }
                } label: {
                    Image(systemName: isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(
                    !isSending
                        && (voiceService.isRecording || voiceService.isTranscribing
                            || draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                )
                .accessibilityLabel(isSending ? "Stop" : "Send message")
                .accessibilityHint(isSending ? "Stops the reply that's currently generating." : "Sends your message to \(conversationTitleForCopy).")
            }
        }
        .padding()
        .background(.bar)
    }

    /// Session 23: the Deep Think toggle. Built to the Amber rule from
    /// this same session: a plain Button carrying its OWN accessibility --
    /// no children:.ignore, nothing interactive nested inside -- so
    /// VoiceOver activation is direct and layout-independent at any text
    /// size. Announces its flip like the web toggle does (aria-live there,
    /// an announcement here), because the visual state change is silent.
    private var deepThinkButton: some View {
        Button {
            deepThinkArmed.toggle()
            Self.deepThinkArmedGlobal = deepThinkArmed
            UIAccessibility.post(
                notification: .announcement,
                argument: deepThinkArmed ? "Deep think on." : "Deep think off."
            )
        } label: {
            Image(systemName: "brain.head.profile")
                .font(.title3)
                .foregroundStyle(deepThinkArmed ? Color.accentColor : Color.secondary)
                .padding(6)
                .background(
                    Circle().strokeBorder(
                        deepThinkArmed ? Color.accentColor : Color.secondary.opacity(0.4),
                        lineWidth: deepThinkArmed ? 2 : 1
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(isSending)
        .accessibilityLabel("Deep think")
        .accessibilityValue(deepThinkArmed ? "On" : "Off")
        .accessibilityHint("Slower, more careful answers for hard questions. Stays on for every message until you turn it off.")
        .accessibilityAddTraits(.isToggle)
        .sensoryFeedback(trigger: deepThinkArmed) { _, _ in
            FeedbackPrefs.gate(.selection)
        }
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
            activeSheet = .agentPicker
            return
        }

        // `sendParentOverride` (see its own doc comment) redirects a normal
        // Send tap into branching from an EARLIER message instead of
        // `messages.last` -- set by `beginEdit(_:)` when this send is
        // really "edit and resend" for the last user message. Consumed
        // exactly once: a plain Send after that always goes back to
        // replying to whatever's now last, same as before this feature
        // existed.
        let parentId = sendParentOverride ?? messages.last?.messageId
        sendParentOverride = nil
        draftText = ""
        // Session 23: while Deep Think is armed, stamp this send with a
        // FRESH epoch-ms marker -- the exact string the web composer
        // appends (useSubmitMessage: `[DEEP THINK ${Date.now()}]`).
        // reframe-proxy only honors a fresh timestamp, so nothing replayed
        // from history can re-trigger deep reasoning by accident. Applies
        // to plain sends and edit-and-resend alike (both are human-authored
        // composer sends); regenerate deliberately not -- it reuses the
        // already-stripped displayText of an old message.
        let stamped = deepThinkArmed
            ? trimmed + " [DEEP THINK \(Int(Date().timeIntervalSince1970 * 1000))]"
            : trimmed
        await performSend(text: stamped, parentId: parentId)
    }

    /// Session 17. Stops whatever `performSend` currently has in flight --
    /// a plain send, a Retry, or a Regenerate, doesn't matter which,
    /// they're indistinguishable once running. Order matters here: tell the
    /// SERVER to stop first (`abortActive()`, which is what actually halts
    /// the (metered) generation and persists whatever partial reply exists
    /// per `docs/ENDPOINTS.md`), THEN cancel the local `sendTask` -- doing
    /// it the other way round would let `performSend`'s catch-and-refetch
    /// race ahead of the abort actually landing server-side, and she'd see
    /// whatever was there a moment before her partial reply got saved
    /// rather than the real thing. `performSend`'s `URLError(.cancelled)`
    /// catch clause (not `CancellationError` -- confirmed via research,
    /// URLSession's async APIs throw the former on Task cancellation, not
    /// the latter) is what turns the resulting cancellation into a calm
    /// "Stopped." instead of the ordinary failure/Retry path.
    private func stopGenerating() {
        guard isSending else { return }
        UIAccessibility.post(notification: .announcement, argument: "Stopping.")
        Task {
            await messageSendingService.abortActive()
            sendTask?.cancel()
        }
    }

    // MARK: - Message actions (Copy / Read Aloud / Edit / Regenerate)
    //
    // Added July 19 2026 after Kade asked for message actions instead of
    // only the Phase 7 VoiceOver rotor for moving between messages -- the
    // rotor is kept (it does a genuinely different, complementary job:
    // fast navigation across many turns) alongside this, which is for
    // ACTING on one already-focused message. See `MessageRow`'s own doc
    // comment for the accessible-button-plus-Menu design and why a rotor
    // and a menu aren't redundant.
    //
    // Edit and Regenerate both work by resending a brand-new sibling
    // message that reuses an EARLIER message's own `parentMessageId`,
    // exactly the same request shape `send()` already used before this
    // feature existed -- verified live 2026-07-19 against a disposable
    // test conversation (sent, then branched a sibling reusing the first
    // message's parentMessageId: a clean new user turn plus a clean new
    // reply appeared, nothing else touched). Deliberately NOT using the
    // server's `isRegenerate`/`overrideParentMessageId`/`responseMessageId`
    // fields, even though `api/server/controllers/agents/request.js` really
    // does accept them: the same live test tried that combination FIRST
    // and it silently corrupted the target message (rewrote it in place as
    // a mislabeled, content-losing user message rather than adding a clean
    // new reply) -- see docs/ENDPOINTS.md for the full writeup. This
    // simpler approach costs a repeated question in the transcript on
    // Regenerate (no way around that without the tree-reconstruction this
    // client deliberately doesn't do -- see `fetchMessages`'s own "known
    // simplification" doc comment) but is honest and uses only the
    // already-proven request shape.
    //
    // Both actions are offered ONLY on the single most recent turn (the
    // last user message for Edit, the last assistant message for
    // Regenerate) on purpose: since this client always renders the flat
    // chronological line rather than reconstructing the active branch,
    // resending from somewhere in the MIDDLE of a long conversation would
    // append the new branch at the bottom, far from the message it
    // logically replaces -- confusing by eye and by ear. Restricting both
    // to the most recent turn keeps the appended branch immediately
    // adjacent to what it's replying to, which reads cleanly either way.

    /// The most recent message the user sent, regardless of whether it's
    /// been replied to yet -- the only message "Edit and Resend" is ever
    /// offered on.
    private var lastUserMessageId: String? {
        messages.last(where: { $0.isCreatedByUser })?.id
    }

    private func canEdit(_ message: KadeMessage) -> Bool {
        !isSending && message.isCreatedByUser && message.id == lastUserMessageId
    }

    /// Only true when the assistant's reply is the very last thing in the
    /// conversation -- see this section's doc comment for why an older
    /// exchange doesn't get a Regenerate action.
    private func canRegenerate(_ message: KadeMessage) -> Bool {
        guard !isSending, !message.isCreatedByUser, let last = messages.last else { return false }
        return !last.isCreatedByUser && message.id == last.id
    }

    private func readAloud(_ message: KadeMessage) {
        // Raw `displayText`, not `readableText` -- same reasoning as the
        // auto-read-aloud call in `performSend` below: this is the actual
        // TTS request, which needs any "%%%" steering tag intact. Prefers
        // the voice this SPECIFIC message actually used (`message.agentId`,
        // decoded from the API's "model" field) over whichever agent is
        // currently picked for the next message, so reading back an older
        // reply never plays it in the wrong character's voice.
        voiceService.enqueueSpeak(
            text: message.displayText,
            agentId: message.agentId ?? selectedAgentId,
            agentName: message.speakerLabel
        )
    }

    /// Prefills the composer with the last user message's own text and
    /// arms `sendParentOverride` so the next Send branches a corrected
    /// sibling from that message's own parent instead of replying to
    /// whatever's last. Moves VoiceOver focus straight to the composer
    /// field so the prefilled text is announced immediately, matching how
    /// a transcribed voice message already lands in the composer
    /// (`finishRecording`, below).
    private func beginEdit(_ message: KadeMessage) {
        guard canEdit(message) else { return }
        draftText = message.displayText
        sendParentOverride = message.parentMessageId
        a11yFocus = .composerField
    }

    /// Resends the ORIGINAL prompting user message's own text, branched
    /// from ITS OWN parent -- see this section's top doc comment for why
    /// this (not the server's isRegenerate/overrideParentMessageId fields)
    /// is the safe way to ask for another attempt at the same question.
    private func regenerate(_ assistantMessage: KadeMessage) async {
        guard canRegenerate(assistantMessage),
              let parentId = assistantMessage.parentMessageId,
              let promptingUser = messages.first(where: { $0.messageId == parentId }) else {
            return
        }
        await performSend(text: promptingUser.displayText, parentId: promptingUser.parentMessageId)
    }

    /// The shared guts of every send -- a plain Send tap (via `send()`
    /// above), "Edit and Resend," and "Regenerate" all fund here,
    /// differing only in which text and which parent they pass.
    private func performSend(text: String, parentId: String?) async {
        failedAttempt = nil
        let optimisticMessage = KadeMessage(
            messageId: "pending-\(UUID().uuidString)",
            conversationId: conversationId ?? "pending",
            createdAt: KadeDateFormatting.isoNow(),
            isCreatedByUser: true,
            sender: "User",
            text: text,
            content: nil,
            parentMessageId: parentId,
            agentId: nil
        )
        messages.append(optimisticMessage)
        sendState = .sending

        do {
            let wasNewConversation = conversationId == nil
            let resolvedConversationId = try await messageSendingService.send(
                text: text,
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
                // FIX (session 21, Kade: "Whit replies still come back as
                // Kiana"). Attribute the spoken reply to whoever ACTUALLY
                // authored it (`reply.agentId` / `reply.speakerLabel`), not to
                // whichever agent is currently selected -- matching the
                // per-message Read Aloud path above. `agentName` was hardcoded
                // to `agentDisplayLabel` (the selected agent), so when the
                // agent id was absent the voice fell back to the WRONG
                // character's name-hash: a reply from Whit read out in Kiana's
                // voice. `speakerLabel` is the server's own `sender` for that
                // message, so this can never drift from the visible bubble.
                voiceService.enqueueSpeak(
                    text: reply.displayText,
                    agentId: reply.agentId ?? selectedAgentId,
                    agentName: reply.speakerLabel
                )
            }
            if wasNewConversation {
                // The conversation list (one screen back) doesn't know this
                // conversation exists yet -- refresh it in the background so
                // it's already there by the time the user navigates back,
                // instead of requiring a manual pull-to-refresh.
                Task { await conversationsService.loadFirstPage() }
            }
        } catch let urlError as URLError where urlError.code == .cancelled {
            // A deliberate Stop (`stopGenerating()`), not a failure -- no
            // red text, no Retry button, that's not what this is. By the
            // time this fires, `abortActive()` has already told the server
            // to stop AND persist whatever partial reply existed (see
            // `stopGenerating()`'s doc comment for why that ordering
            // matters), so a plain authoritative refetch picks it up the
            // same way a normal completed turn would -- there may be a
            // real, if short, assistant reply sitting right there.
            sendState = .idle
            if let resolvedId = conversationId {
                messages = (try? await conversationsService.fetchMessages(conversationId: resolvedId)) ?? messages
            }
            // Same focus move the normal-completion path makes (jump to the
            // newest message) -- if a partial reply made it through before
            // the stop landed, she should hear it the same way she'd hear
            // any other new reply, not have to go hunting for it.
            a11yFocus = messages.last.map { .message($0.id) }
            UIAccessibility.post(notification: .announcement, argument: "Stopped.")
        } catch let error as MessageSendingService.SendError {
            if case .streamError(let message) = error {
                sendState = .failed(message)
            } else {
                sendState = .failed("Didn't get a reply. Check your connection and try again.")
            }
            failedAttempt = FailedAttempt(text: text, parentId: parentId)
            a11yFocus = .composerError
        } catch {
            // The optimistic message stays visible on purpose: it really was
            // sent from the user's point of view, only the "did the reply
            // come back" half failed.
            sendState = .failed("Didn't get a reply. Check your connection and try again.")
            failedAttempt = FailedAttempt(text: text, parentId: parentId)
            a11yFocus = .composerError
        }
    }

    /// Resends the EXACT (text, parent) pair a failed send was trying to
    /// deliver -- see `failedAttempt`'s own doc comment for the dead-button
    /// bug this replaces. Accepts a small, deliberate trade-off: if the
    /// original attempt actually reached the server and only the
    /// confirm-the-reply half failed (a real possibility --
    /// `MessageSendingService`'s own type doc describes exactly this
    /// class of failure), this creates a genuine duplicate turn rather
    /// than silently recovering the original. That's judged the better
    /// failure mode -- a visible, easy-to-ignore duplicate beats a Retry
    /// button that does nothing and leaves no path forward except backing
    /// out of the screen. A safer "just re-fetch and see if it already
    /// landed" alternative was considered and rejected for now: with no
    /// compiler and no reliable way to simulate a genuinely dropped
    /// connection against the live server this session, a fetch-first
    /// retry risks a worse bug -- silently REPLACING `messages` with the
    /// server's list and dropping the still-visible optimistic bubble if
    /// the original send in fact never went through at all.
    private func retry() async {
        guard let attempt = failedAttempt else { return }
        failedAttempt = nil
        await performSend(text: attempt.text, parentId: attempt.parentId)
    }

    // MARK: - Voice input (Phase 5)

    private func toggleRecording() async {
        if voiceService.isRecording {
            await finishRecording()
            return
        }
        voiceInputError = nil
        // Session 23 (Kade's call): NO hard length cap -- "I don't think I
        // want an auto stop if you mean a limit to how long you can
        // record." The only auto-stop is silence-based: ten quiet seconds
        // means the mic was abandoned (the exact accident the old 60s cap
        // guarded against), while a long real thought keeps recording as
        // long as she keeps talking.
        let started = await voiceService.startRecording(silenceStopAfter: 10) {
            KadeHaptics.warning()
            UIAccessibility.post(
                notification: .announcement,
                argument: "Recording stopped after a long silence. Turning what you said into text."
            )
            Task { await finishRecording() }
        }
        guard started else {
            voiceInputError = voiceService.recordError ?? "Couldn't start recording. Try again."
            a11yFocus = .voiceError
            return
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
/// happen to be in. A separate "Message actions" button sits right below
/// as its OWN sibling accessibility element (never combined into the
/// element above -- same house rule every other interactive control in
/// this app follows: a plain Button/Menu + `.accessibilityElement(children:
/// .ignore)` + an explicit `.accessibilityLabel`, never `.combine`) so
/// VoiceOver reaches it with one more swipe after hearing the message, and
/// double-tapping it opens a native, fully accessible `Menu` rather than
/// requiring a long-press or a rotor gesture to discover it.
///
/// Added July 19 2026, replacing "the only way to interact with an older
/// message is the VoiceOver rotor" -- the rotor (see `messageList`'s
/// `accessibilityRotor`s) is kept alongside this on purpose, it does a
/// different job (fast navigation across many turns) than this (acting on
/// one already-focused message).
private struct MessageRow: View {
    // Session 17: message text is this app's single highest-value reading
    // surface -- see AppearancePreferences.swift's own doc comment for why
    // the easy-read font/line-spacing choices apply HERE specifically
    // rather than everywhere. Available via the environment (injected once
    // at the app root in KadeAIApp.swift), not passed in as a parameter --
    // one more property on every call site for a cross-cutting display
    // preference would be pure noise.
    @EnvironmentObject private var appearance: AppearancePreferences
    let message: KadeMessage
    /// Only the last user message gets an Edit action; see
    /// `ConversationDetailView.canEdit(_:)`.
    let canEdit: Bool
    /// Only the last assistant message gets a Regenerate action; see
    /// `ConversationDetailView.canRegenerate(_:)`.
    let canRegenerate: Bool
    let onReadAloud: () -> Void
    let onEdit: () -> Void
    let onRegenerate: () -> Void
    /// Session 14 (Kade: "needs to be a download voice clip button, needs to
    /// be called a voice message in the first place considering that one
    /// button is called send voice message"). She's right, and the fix is
    /// naming, not just a new button: the app called the SAME artefact two
    /// different things depending on direction -- "Send voice message" going
    /// out, "Read Aloud" coming back. One noun now, both directions: a voice
    /// message. Everything user-visible in this file follows that.
    let onSaveVoiceMessage: () -> Void
    let onShare: () -> Void
    let onDelete: (() -> Void)?
    let isPreparingVoiceMessage: Bool

    private var timeLabel: String {
        KadeDateFormatting.time(from: message.createdAt) ?? ""
    }

    /// `readableText`, not `displayText` -- this is a surface a human
    /// reads/VoiceOver speaks, so any "%%%" TTS steering tag or Game
    /// Parlor token must already be stripped. See `KadeMessage`'s own doc
    /// comments for why the two properties stay separate.
    private var bodyText: String {
        message.readableText.isEmpty ? "…" : message.readableText
    }

    var body: some View {
        VStack(alignment: message.isCreatedByUser ? .trailing : .leading, spacing: 6) {
            VStack(alignment: message.isCreatedByUser ? .trailing : .leading, spacing: 4) {
                Text(message.speakerLabel)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(bodyText)
                    .font(appearance.messageFont())
                    .lineSpacing(appearance.lineSpacing.extraPoints)
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
            // Kade, build 121: "there are action buttons by every message,
            // which would be fine, but there are already actions in the
            // rotor that do the same thing, so unless they're a visual
            // thing, they should probably go. I like the actions."
            //
            // So: the actions now hang off the MESSAGE ITSELF as real,
            // explicitly-declared VoiceOver actions (reachable with the
            // Actions rotor on the message she's already focused on), and
            // the separate button below is hidden from VoiceOver entirely
            // -- it stays on screen because it IS a visual thing, the only
            // way a sighted user reaches any of this. Net effect by ear:
            // one swipe stop per message instead of two, with every action
            // still one rotor flick away.
            //
            // `accessibilityActions` (the ViewBuilder form) rather than
            // repeated `accessibilityAction(named:)` specifically because it
            // supports `if` -- Edit/Regenerate/Delete are conditional, and
            // VoiceOver must never announce an action this message can't
            // actually perform.
            .accessibilityActions {
                Button("Copy text") {
                    UIPasteboard.general.string = message.readableText
                    UIAccessibility.post(notification: .announcement, argument: "Copied to clipboard.")
                }
                Button("Play as voice message") { onReadAloud() }
                Button("Save voice message") { onSaveVoiceMessage() }
                Button("Share text") { onShare() }
                if canEdit {
                    Button("Edit and resend") { onEdit() }
                }
                if canRegenerate {
                    Button("Regenerate reply") { onRegenerate() }
                }
                if let onDelete {
                    Button("Delete message") { onDelete() }
                }
            }

            actionsButton
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: message.isCreatedByUser ? .trailing : .leading)
    }

    private var accessibleLabel: String {
        let who = message.isCreatedByUser ? "You said" : "\(message.speakerLabel) said"
        let time = timeLabel.isEmpty ? "" : ", \(timeLabel)"
        return "\(who)\(time): \(bodyText)"
    }

    // MARK: - Actions menu

    private var actionsButton: some View {
        Menu {
            Button {
                UIPasteboard.general.string = message.readableText
                UIAccessibility.post(notification: .announcement, argument: "Copied to clipboard.")
            } label: {
                Label("Copy Text", systemImage: "doc.on.doc")
            }
            Button {
                onReadAloud()
            } label: {
                Label("Play as Voice Message", systemImage: "speaker.wave.2")
            }
            Button {
                onSaveVoiceMessage()
            } label: {
                Label(
                    isPreparingVoiceMessage ? "Preparing Voice Message" : "Save Voice Message",
                    systemImage: "square.and.arrow.down"
                )
            }
            .disabled(isPreparingVoiceMessage)
            Button {
                onShare()
            } label: {
                Label("Share Text", systemImage: "square.and.arrow.up")
            }
            if canEdit {
                Button {
                    onEdit()
                } label: {
                    Label("Edit and Resend", systemImage: "pencil")
                }
            }
            if canRegenerate {
                Button {
                    onRegenerate()
                } label: {
                    Label("Regenerate Reply", systemImage: "arrow.clockwise")
                }
            }
            if let onDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Message", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Message actions")
        .accessibilityHint(actionsHint)
    }

    /// Built dynamically so VoiceOver only ever promises what THIS
    /// specific message can actually do right now -- Edit and Regenerate
    /// only ever appear on the single most recent turn (see
    /// `ConversationDetailView`'s "Message actions" doc comment).
    private var actionsHint: String {
        var options = ["copy the text", "play it as a voice message", "save the voice message", "share the text"]
        if canEdit { options.append("edit and resend it") }
        if canRegenerate { options.append("regenerate this reply") }
        if onDelete != nil { options.append("delete it") }
        return "Shows options to \(naturalJoin(options))."
    }

    private func naturalJoin(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        if items.count == 1 { return last }
        if items.count == 2 { return "\(items[0]) or \(last)" }
        return items.dropLast().joined(separator: ", ") + ", or \(last)"
    }
}

/// One thing to hand to the system share sheet — either the plain text of a
/// message ("Share Text") or a prepared audio file ("Save Voice Message").
///
/// Session 14. Kade asked for "a download voice clip button"; the system
/// share sheet IS the download button on iOS — "Save to Files" lives inside
/// it, alongside AirDrop, Messages, Mail and everything else she might
/// actually want to do with a clip. Building a bespoke download flow on top
/// would be less capable AND less familiar to VoiceOver, which already
/// knows how to navigate this sheet.
struct ShareItem: Identifiable {
    let id = UUID()
    let text: String?
    let fileURL: URL?

    init(text: String) {
        self.text = text
        self.fileURL = nil
    }

    init(fileURL: URL) {
        self.text = nil
        self.fileURL = fileURL
    }

    var activityItems: [Any] {
        if let fileURL { return [fileURL] }
        if let text { return [text] }
        return []
    }
}

/// Minimal bridge to `UIActivityViewController`. SwiftUI's own `ShareLink`
/// would be tidier, but it needs its payload to exist at the moment the
/// button is built — and a voice message doesn't exist until it has been
/// synthesized, which is an async round-trip that happens only after the
/// user asks for it. Presenting the sheet from prepared state is the
/// correct shape for that.
struct ShareSheet: UIViewControllerRepresentable {
    let item: ShareItem

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: item.activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Wrapper so the post-call transcript push has its OWN destination type.
///
/// `.navigationDestination(item:)` registers by the item's TYPE across the
/// entire enclosing `NavigationStack`. Build 121 shipped three of them all
/// bound to `KadeConversation?` -- the conversation list's row selection,
/// ContentView's Spotter-call handoff, and this one -- and SwiftUI resolved
/// the ambiguity by honouring one and silently ignoring the rest. The
/// visible symptom was Kade's: conversation rows stopped opening. Giving
/// each non-list handoff its own single-purpose type makes the collision
/// impossible to reintroduce by accident, and makes the reason legible at
/// the declaration site rather than only in a commit message.
///
/// `KadeConversation` keeps sole ownership of the plain-list destination.
struct ChatTranscriptHandoff: Identifiable, Hashable {
    let conversation: KadeConversation
    var id: String { conversation.conversationId }
}

/// Everything `ConversationDetailView` can present modally, behind one
/// binding. See `activeSheet`'s doc comment for why this is an enum rather
/// than several separate `.sheet` modifiers.
enum DetailSheet: Identifiable {
    case agentPicker
    case share(ShareItem)
    case transcript(ChatTranscriptHandoff)
    case voicePicker

    var id: String {
        switch self {
        case .agentPicker: return "agent-picker"
        case .share(let item): return "share-\(item.id.uuidString)"
        case .transcript(let handoff): return "transcript-\(handoff.id)"
        case .voicePicker: return "voice-picker"
        }
    }
}
