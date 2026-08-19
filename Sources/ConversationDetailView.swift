import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    /// Session 26 (chat-first launch, her pick via AskUserQuestion:
    /// "Chat-first + Spotter in toolbar"): only the LAUNCH-opened instance
    /// of this screen shows a Spotter button in its toolbar — the app's
    /// opening screen must keep Spotter one tap away (her standing rule),
    /// while ordinary pushed chats keep the deliberately calm two-icon bar
    /// (see the session-25 note on the toolbar). Defaulted so every
    /// existing call site is untouched (same memberwise-init reasoning as
    /// `initialAgentId` above).
    var showSpotterShortcut: Bool = false
    /// Session 33 (the Prompt Library, leftovers item 5): a prompt chosen
    /// in PromptsView arrives here as pre-typed composer text. Seeded ONCE
    /// in `.task` and only when the composer is empty, so it can never
    /// stomp something the user already started typing. Same defaulted-
    /// `var` memberwise-init reasoning as `initialAgentId` above.
    var initialDraft: String? = nil
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
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @EnvironmentObject private var apiClient: KadeAPIClient
    /// Only actually dismisses anything when this view is the root of a
    /// sheet-presented `NavigationStack` (see `isStandalonePresentation`
    /// above) -- harmless to declare unconditionally otherwise.
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [KadeMessage] = []
    @State private var isLoading = true
    @State private var loadError: String?
    /// The server-generated name of a conversation BORN in this view
    /// (`conversation == nil` case), once the background pickup in
    /// `performSend` retrieves it -- lets the nav title stop saying
    /// "New conversation" the moment the server has named the chat.
    @State private var generatedTitle: String?

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
    // Session 25 ("a reading view for native like we do on web"): which
    // reply is open in the full-screen reader, plus where VoiceOver focus
    // returns when it closes (the item binding is already nil by the time
    // onDismiss runs, so the id is stashed separately at open time).
    @State private var readingMessage: KadeMessage?
    @State private var readingReturnId: String?
    // Session 26 (leftovers item 1, in-chat attachments -- see
    // ChatAttachment.swift for the full wire contract). One attachment
    // rides the NEXT send; uploaded at pick time exactly like the web, so
    // Send itself stays instant. Kept across a FAILED send on purpose --
    // Retry re-spends the same file_id.
    @State private var pendingAttachment: ChatAttachment?
    // Session 35 encore — the LIVE THINKING BUBBLE (her ask: "see the
    // thoughts populate as they stream"). Fills from on_reasoning_delta
    // frames during a send; cleared when the real message (with its own
    // permanent think part) replaces it at final.
    @State private var liveThink = ""
    /// Aug 5 2026 crash hardening: raw think chunks accumulate here and get
    /// sanitized + published to `liveThink` at most every 250ms. Deep thinks
    /// stream ~34 chunks/second; sanitizing and re-laying-out a growing Text
    /// on every chunk is watchdog bait. Coalescing cuts that to 4/second —
    /// visually still "live," mechanically calm.
    @State private var liveThinkExpanded = false
    /// Aug 4 2026 (her pick): gentle spoken progress during LONG deep
    /// thinks, about every 20 seconds -- "Still thinking, about 900
    /// characters so far." Announcement-only (VoiceOver speech, never TTS:
    /// her explicit rule is that thoughts are never read out loud by the
    /// voice). Togglable under Settings > Speech.
    @AppStorage("kade.thinkingProgress.spoken") private var spokenThinkingProgress = true
    // Aug 7 2026 (her "deep think off but still seems like she's thinking"):
    // LIVE REPLY STREAMING. The reply text was always on the wire; native
    // just waited for final. Now it grows on screen as she writes — and for
    // the ear, an optional low-priority "still writing" line about every 20
    // seconds (same toggle and manners as spoken thinking progress). The
    // live view itself is VoiceOver-HIDDEN on purpose: live-mutating text is
    // exactly the churn that kept cutting readouts off; the finished
    // message announces and auto-reads exactly as before.
    @State private var liveReply = ""

    /// Aug 13 2026 — THE PER-CHUNK STATE WRITE, and why the Aug 7 coalescing
    /// only got half the job. Seven of this view's `@State` properties were
    /// pure bookkeeping — accumulation buffers, two scheduled-flush guards,
    /// three announcement timers. NOTHING in any view builder reads a single
    /// one of them (verified by grep before this change). But they were
    /// written on the hot path: `replyRaw += chunk` fired on EVERY streamed
    /// chunk, and deep thinks arrive around 34 chunks a second. Every one of
    /// those writes is a `@State` write, which means a trip through
    /// AttributeGraph whether or not the body ever reads the value.
    ///
    /// The Aug 7 fix coalesced the SANITIZE to 4/second and correctly gated
    /// it on scene state. It never touched the WRITES underneath, so the
    /// graph churn stayed at chunk rate — and a crash-and-resubscribe replay
    /// burst (Amber caught 56 events in one go on Aug 13, then 43) lands that
    /// churn back-to-back in a single runloop turn.
    ///
    /// A plain class in `@State` is the fix and the whole fix: SwiftUI holds
    /// the reference, mutating the object's PROPERTIES never touches the
    /// `@State` storage, so the hot path costs a string append and nothing
    /// else. Deliberately NOT an ObservableObject — publishing is exactly the
    /// behaviour being removed here.
    @State private var live = LiveStreamBuffers()
    /* ⭐ BUILD 222 — the rotors come back, scoped so SwiftUI can match an
     * entry WITHOUT walking the LazyVStack. Pairs with
     * `.accessibilityRotorEntry(id:in:)` on each row below. */
    @Namespace private var transcriptRotorSpace
    @State private var userRotorItems: [RotorItem] = []
    @State private var replyRotorItems: [RotorItem] = []

    /// Aug 7 2026 — the 0x8BADF00D fix (two watchdog kills the same afternoon,
    /// receipts in the bridge diagnostics ring): every live-stream flush
    /// re-sanitizes and re-lays-out the ENTIRE accumulated text, and build 189
    /// ran that each 250ms with no regard for scene state. Backgrounding
    /// mid-stream left the main thread churning through a scene update until
    /// iOS's 10-second watchdog killed the app. Rules now: ZERO heavy work
    /// unless the app is actively on screen (a cheap 1-second retry loop
    /// otherwise — the catch-up flush lands right after return to foreground,
    /// and the loop dies with the stream), and the cadence stretches as the
    /// text grows so a streamed essay does bounded work per second.
    private func liveFlushDelay(forLength length: Int) -> TimeInterval {
        if length < 4000 { return 0.25 }
        if length < 16000 { return 0.6 }
        return 1.2
    }

    private func scheduleLiveReplyFlush(retry: Bool = false) {
        guard !live.replyFlushScheduled else { return }
        live.replyFlushScheduled = true
        let delay = retry ? 1.0 : liveFlushDelay(forLength: live.replyRaw.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            live.replyFlushScheduled = false
            guard case .sending = sendState else { return }
            guard UIApplication.shared.applicationState == .active else {
                // The Aug 7 scene-state gate, now with a receipt. Once per
                // turn: if a kill follows this crumb we know the app was off
                // screen with a stream still arriving, which is the shape
                // both her and Amber's watchdog kills have.
                if !live.crumbedFlushDeferred {
                    live.crumbedFlushDeferred = true
                    KadeBreadcrumbs.drop("live flush deferred — app not active")
                }
                scheduleLiveReplyFlush(retry: true)
                return
            }
            liveReply = MessageTextSanitizer.forDisplay(live.replyRaw)
        }
    }

    private func scheduleLiveThinkFlush(retry: Bool = false) {
        guard !live.thinkFlushScheduled else { return }
        live.thinkFlushScheduled = true
        let delay = retry ? 1.0 : liveFlushDelay(forLength: live.thinkRaw.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            live.thinkFlushScheduled = false
            guard case .sending = sendState else { return }
            guard UIApplication.shared.applicationState == .active else {
                scheduleLiveThinkFlush(retry: true)
                return
            }
            liveThink = MessageTextSanitizer.forDisplay(live.thinkRaw)
        }
    }
    /// Aug 4 2026 evening (her report: "the stupid flashing still thinking
    /// message interrupts the stream of thoughts being read out by
    /// voiceover"): while the bubble is OPEN, its spoken text is a frozen
    /// SNAPSHOT taken at the moment it opened -- live text that mutates
    /// under VoiceOver mid-read invalidates the element and cuts the
    /// readout off. Close and reopen for a fresh snapshot; the VISUAL text
    /// keeps pouring for sighted eyes either way.
    @State private var attachmentUploading = false
    @State private var showingAttachMenu = false
    @State private var showingAttachPhotos = false
    @State private var attachPhotoItem: PhotosPickerItem?
    @State private var showingAttachImporter = false
    // Session 24 (leftovers item 2): search WITHIN this conversation.
    // Client-side filter over the messages already in hand, same deliberate
    // choice (and same reasons) as the conversation list's search: instant,
    // network-free, degrades honestly. Filters on `readableText` so what
    // matches is exactly what VoiceOver reads -- steering tags and Deep
    // Think markers can never make an invisible match.
    @State private var messageSearchActive = false
    @State private var messageSearchText: String = ""

    /// Aug 14 2026 — THE TRANSCRIPT WINDOW, bought by Amber's build-202
    /// crash loop (bridge diagnostics ring, 15:38–16:35Z: launch → send →
    /// 0x8BADF00D scene-update watchdog, three relaunches in 17 minutes,
    /// same signature as her five 197-era kills). Build 202 already made
    /// each row CHEAP (the sanitizer memo + precomputed rotor arrays) —
    /// but every 250ms live-stream flush still re-evaluates this body and
    /// asks AttributeGraph to diff EVERY row of a 164-message thread, and
    /// launch's scroll-to-bottom materializes the lot. The cost that
    /// remained was O(all messages); this caps it. Only the newest
    /// `transcriptWindow` rows render; a clearly-labeled button above the
    /// transcript loads earlier history in steps. Search still sweeps the
    /// FULL thread on purpose (explicit intent, rare, and it renders only
    /// the matches). VoiceOver wins twice: fewer swipe stops by default in
    /// a giant thread, and the rotors now navigate exactly what is on
    /// screen.
    @State private var transcriptWindow = ConversationDetailView.transcriptWindowStep
    /* ⭐⭐⭐ BUILD 224 — THE WINDOW IS THE FREEZE, AND THIS IS THE EVIDENCE-BASED CUT.
     *
     * Every fix from 216→223 shaved a widget off the send commit (haptics,
     * earcons, the pulse dot, the rotors, the composer field) and the freeze
     * only MOVED — because the real cost was never a widget, it was the NUMBER
     * OF ROWS re-laid-out for VoiceOver when the transcript mutates on send.
     * Her 223 kill proves it: the main thread was busy in SwiftUICore layout /
     * AttributeGraph (no TextKit, no recursion), and it died on the OPTIMISTIC
     * APPEND itself — the moment her own message is added — before any widget
     * in the reply row even existed. "Simple transcript" (bare Text rows) also
     * froze because it still had all 60 rows in the container.
     *
     * The number is the whole story. A SEND lays out against THIS window; the
     * streaming thin-to-12 only kicks in AFTER `sendState` flips, so every send
     * paid for 60 rows. But the app STREAMS fine at 12 rows (build 209, live
     * for days). 60 froze, 12 did not. So the base window becomes 12 — a send
     * now re-lays-out the same bounded transcript that streaming already proved
     * tolerable, and the thin-to-12 becomes a no-op instead of a second
     * re-window on the same commit. "Show earlier messages" still loads the
     * rest on demand; nothing is lost but the freeze. */
    private static let transcriptWindowStep = 12

    /// Part 70.8 (Aug 16 2026 -- her three send-time freezes ON 208, all in
    /// one heavy conversation, stacks in the ring): the freezes fire at the
    /// send-moment transcript update, BEFORE any reply chunk exists, so
    /// 208's landed-reply chunking could not reach them. While a reply is
    /// streaming, the transcript renders only the newest few rows -- the
    /// send-moment insert+scroll and every live flush lay out a BOUNDED
    /// transcript no matter how heavy the conversation has grown. The full
    /// window returns the moment the stream ends. Tapping "Show earlier
    /// messages" mid-stream switches the thinning off for that stream: her
    /// explicit ask outranks the guard.
    private static let streamingWindowRows = 12
    @State private var streamThinDisabledByUser = false
    @FocusState private var messageSearchFocused: Bool

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
    /// Session 28 (Kade: "there is a silent gap between received and playing
    /// the voiceclip, if you have auto play on"): true from "reply landed and
    /// WILL be auto-spoken" until its clip actually starts (or provably
    /// won't). While true, the waiting ticks stay alive through the TTS
    /// fetch instead of dying at the received bloop. Set BEFORE sendState
    /// flips to .idle so the sendState watcher reads it race-free.
    @State private var awaitingSpokenReply = false
    /// Fail-safe for the flag above: if the clip never starts AND the queue
    /// never visibly drains (a hang, not a clean failure), stop ticking
    /// after 12s rather than forever.
    @State private var speechWaitWatchdog: Task<Void, Never>? = nil
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
    /// Build 204 — HER DESIGN, verbatim: "it auto decides between deepthink
    /// and instant for you... Everything on everybody should be auto by
    /// default, with choices for instant and deep if desired." The two-state
    /// Deep Think toggle grew into a three-mode thinking picker:
    ///   auto    -> send unmarked; the reframe proxy's router reads the
    ///              question and picks instant / quick-think / deep itself
    ///   deep    -> every send stamped [DEEP THINK <ms>] (exactly the old
    ///              armed behavior)
    ///   instant -> every send stamped [INSTANT <ms>] — the proxy's forced
    ///              fast lane (marker machinery shipped reframe-side first)
    /// Persistence splits on purpose: instant SURVIVES relaunch (a person
    /// who always wants the quick answer shouldn't re-pick it every day)
    /// but deep RESETS to auto on launch — the Session-23 rule that "why is
    /// she slow today, days later" is the wrong kind of surprise, kept.
    enum ThinkMode: String {
        case auto, deep, instant
        var spoken: String {
            switch self {
            case .auto: return "Thinking: automatic. She decides per question."
            case .deep: return "Thinking: deep. Always takes her time."
            case .instant: return "Thinking: instant. Always the quick answer."
            }
        }
    }
    private static let thinkModeKey = "kadeThinkMode"
    @MainActor private static var thinkModeGlobal: ThinkMode = {
        let raw = UserDefaults.standard.string(forKey: ConversationDetailView.thinkModeKey) ?? ThinkMode.auto.rawValue
        let stored = ThinkMode(rawValue: raw) ?? .auto
        return stored == .deep ? .auto : stored
    }()
    @State private var thinkMode: ThinkMode = .auto

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
    /// Session 26: launch-instance Spotter call — see `showSpotterShortcut`.
    @State private var showingSpotterCall = false
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
        /// Session 23 (Kade: VoiceOver "bounces your focus so you can't
        /// just double tap the button to be done recording"): an explicit
        /// anchor for the mic button so starting a recording PINS focus
        /// there — double-tap-again-to-stop always works.
        case micButton
        case voiceError
    }
    @AccessibilityFocusState private var a11yFocus: A11yFocus?
    /// Build 217: the replying row's decorative layer is skipped entirely
    /// under VoiceOver -- see `replyingRow`.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    /* ⭐ BUILD 217 -- THE BISECT SHE ASKED FOR, user-flippable, default OFF.
     * With this on, every transcript row renders as ONE plain Text with a
     * single accessibility label and nothing else: no custom accessibility
     * element tree, no per-row `.accessibilityActions`, no bubble chrome, no
     * timestamp, no attachment views, no chunking. If the freeze survives
     * build 217's cure and STOPS when she flips this, the stall lives in the
     * per-row view/accessibility machinery; if it freezes with this ON too,
     * every row is innocent and the wedge is the transcript container or the
     * replying row itself. It is deliberately a real setting rather than a
     * debug flag so she can answer the question herself, in one tap, without
     * waiting for another build. */
    @AppStorage("kade.chat.simpleTranscript") private var simpleTranscript = false
    /* ⭐ BUILD 218 bisect, default OFF. ON = the composer is a plain
     * SINGLE-LINE field: no vertical growth, no line-limit range, nothing for
     * the layout to negotiate. Freeze stops when she flips this and the
     * composer's text control is convicted outright; freeze survives and the
     * last text-measuring surface on the screen is cleared too, which would
     * leave the transcript CONTAINER (ScrollView/LazyVStack/ScrollViewReader)
     * as the only thing standing. Costs her the multi-line composer while it
     * is on -- long messages still type fine, they just scroll in one line. */
    @AppStorage("kade.chat.simpleComposer") private var simpleComposer = false

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
                    if messageSearchActive {
                        messageSearchBar
                    }
                    messageList
                }
            }
            .frame(maxHeight: .infinity)
        }
        /* ⭐⭐ BUILD 219 -- AIMED AT THE RECURSION ITSELF, NOT AT WHAT IT WAS
         * MEASURING.
         *
         * Her single-line-composer test is what made this readable. With the
         * multi-line box, every stack leafed in UIKit text measurement, so I
         * read the composer as the cause. With the single-line box, those
         * UIKit frames VANISHED from the leaf -- and the freeze did not. What
         * stayed, in all of them, is a 9-frame SwiftUICore layout cycle
         * repeating six and seven times (`+479532 → +517752 → +486812 →
         * +479324 → +482944 → +464312 → …`, 44 SwiftUICore frames in the
         * 22:05 kill, 10.039s of app CPU against a 10.00s allowance).
         *
         * So the text control was never the cause -- it was the thing being
         * re-measured by a layout that will not settle. Whatever text is at
         * the bottom of the tree shows up at the leaf; swap it and the leaf
         * changes and the loop does not.
         *
         * THE SHAPE THAT PRODUCES THAT LOOP IS RIGHT HERE. This was one
         * `VStack(spacing: 0)` holding a greedy `ScrollView` AND four
         * flexible-height siblings (agent picker, context meter, read-aloud
         * row, composer). A VStack resolves that by proposing sizes to its
         * children, taking their answers, and re-proposing -- and every
         * re-proposal cascades into both subtrees, each of which contains its
         * own nested flexible stacks and text. A transcript that wants all the
         * height and a composer that wants to grow to five lines are in the
         * same negotiation, arguing over the same points.
         *
         * `safeAreaInset` is the idiomatic answer for exactly this screen --
         * a scrolling transcript with a pinned input bar. The scroll view
         * simply takes the space; the inset is measured on its own, once, and
         * `fixedSize(vertical:)` makes it state one definite height instead of
         * negotiating for it. Nothing moves on screen and nothing changes for
         * VoiceOver: same content, same order, same pinned bar. It also gives
         * keyboard avoidance the shape Apple designed it for.
         *
         * ⚠️ Swing 13, and named as one. What is EVIDENCE here is that the
         * loop is a layout negotiation and not any single widget -- her two
         * toggles proved the rows and the text control are both innocent.
         * What is INFERENCE is that this particular VStack is the negotiation
         * that will not converge. */
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isLoading && loadError == nil {
                VStack(spacing: 0) {
                    agentSection
                    contextMeter
                    readAloudToggle
                    composer
                }
                /* ⭐ BUILD 220: 219's `.fixedSize(horizontal: false,
                 * vertical: true)` is GONE from here. It did help -- the
                 * 9-frame cycle 219 aimed at went from six and seven
                 * repetitions down to ONE in the newest kill -- but asking
                 * this cluster for its IDEAL height re-opens a measurement
                 * pass over a text control whose ideal height depends on its
                 * content, and a VoiceOver tree re-scan is exactly what
                 * triggers that pass. `safeAreaInset` already sizes its
                 * content to fit; it does not need to be told twice. */
            }
        }
        .navigationTitle(conversation?.displayTitle ?? generatedTitle ?? "New conversation")
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
            // Session 26 (chat-first launch): the launch-opened chat is now
            // the app's opening screen, and Kade's standing Spotter rule
            // ("keep it one-tap, always") travels with it — an eye button
            // in the bar, launch instance ONLY (`showSpotterShortcut`), so
            // ordinary pushed chats keep the calm two-icon bar the
            // session-25 pass established.
            if showSpotterShortcut {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        KadeHaptics.press()
                        showingSpotterCall = true
                    } label: {
                        Image(systemName: "eye")
                    }
                    .accessibilityLabel("Call your Spotter")
                    .accessibilityHint("Starts a live call with your visual companion straight away, without picking anyone first.")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if messageSearchActive {
                        endMessageSearch()
                    } else {
                        messageSearchActive = true
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .disabled(messages.isEmpty)
                .accessibilityLabel(messageSearchActive ? "Close search" : "Search this conversation")
                .accessibilityHint(messageSearchActive
                    ? "Clears the search and shows the whole conversation again."
                    : "Opens a search field that narrows the messages to ones whose text matches.")
            }
            // Session 25 (Kade approved the audit list, "All four"): the
            // Voice button used to be a THIRD icon crammed into this bar
            // (search, voice, call). It now lives on the agent row below --
            // voice belongs beside "Talking to X" conceptually (it IS that
            // agent's voice), and the bar is calmer at two icons. Same
            // label, same hint, same behavior -- see `agentSection`.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCall = true
                } label: {
                    Image(systemName: "phone.fill")
                }
                .disabled(selectedAgentId == nil)
                .accessibilityLabel("Call \(agentDisplayLabel)")
                .accessibilityHint("Starts a live voice call.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MessageSendingService.memoryArtifactNotification)) { note in
            // Aug 7 2026 — the memory-saved cue: spoken + felt the moment
            // the platform's memory keeper files or forgets a card
            // mid-conversation. Deletions read as "forgotten."
            let type = (note.userInfo?["type"] as? String) ?? ""
            guard type == "update" || type == "delete" else { return }
            KadeHaptics.success()
            UIAccessibility.post(
                notification: .announcement,
                argument: type == "delete" ? "A memory was forgotten." : "Memory saved."
            )
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
            thinkMode = Self.thinkModeGlobal
            // Prompt Library handoff: pre-type the chosen prompt. Empty
            // check = the never-clobber guarantee promised at the
            // declaration; a re-appear after a push-pop also lands here,
            // and by then draftText either still holds the prompt (no-op)
            // or holds the user's own edit (guarded).
            if let seed = initialDraft,
               draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draftText = seed
            }
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
                // Session 26 (her ask, verbatim: "They might not all vibe
                // with Kiana, but they at least have her to start with"):
                // a brand-new chat now starts pointed at the user's MAIN
                // agent instead of opening with an interrogation. The
                // stored pick wins instantly; otherwise Kiana by name once
                // the roster loads. The picker sheet remains only as the
                // true last resort (no stored pick AND no Kiana in the
                // roster — e.g. first run, offline). Switching who answers
                // stays one tap away on the "Talking to" row, unchanged.
                if selectedAgentId == nil {
                    if let stored = DefaultAgentStore.storedId {
                        selectedAgentId = stored
                    } else {
                        await agentsService.loadIfNeeded()
                        selectedAgentId = DefaultAgentStore.resolveId(in: agentsService.agents)
                    }
                }
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
            /* ⭐ BUILD 216: the idle->sending case is GONE from here. It fired
             * a light impact at the same instant the watcher below fired
             * `KadeHaptics.sentTick()` -- TWO haptics for one send, one of
             * them driven by SwiftUI from inside the state-change turn the
             * 215 crash died in. sentTick is the better of the two (her
             * tuned Taptic pattern, not a generic impact) and it now lands
             * on the next turn, so this line was pure duplicate cost in the
             * exact place we cannot afford it. The other two moments stay:
             * they fire on the reply LANDING and on failure, neither of
             * which is a wedged turn on any trail we have. */
            if case .sending = old, case .idle = new { return FeedbackPrefs.gate(.success) }
            if case .failed = new { return FeedbackPrefs.gate(.error) }
            return nil
        }
        // Session 20 earcons: the same three send moments get a short,
        // gentle non-speech sound (honouring the Sound effects switch),
        // COMPLEMENTING -- never replacing -- VoiceOver's own spoken cue.
        .onChange(of: sendState) { old, new in
            if case .idle = old, case .sending = new {
                Earcons.shared.play(.messageSent)
                KadeHaptics.sentTick() // Aug 6 2026: felt twin of the send bloop
                /* ⭐ BUILD 216 -- the bisect that survives this fix. Both calls
                 * above now only QUEUE their work (see KadeFeedback.swift), so
                 * this crumb proves the send turn got past them, and the
                 * queued one after it proves the audio/haptic work itself
                 * finished. If a freeze trail ever again ends at "optimistic
                 * row painted" with NEITHER of these, the wedge is the rest of
                 * the turn -- the replyingRow insert -- not feedback. If it
                 * ends at "send feedback queued", the hardware call is still
                 * blocking, just no longer inside the scene update. */
                KadeBreadcrumbs.drop("send feedback queued")
                // Build 218: the trail now says which composer was on screen,
                // so a freeze report is self-describing without asking her.
                KadeBreadcrumbs.drop(
                    "layout: safeAreaInset(220, no fixedSize), composer: \(simpleComposer ? "single-line (bisect ON)" : "multiline lineLimit(5)")"
                    + ", transcript: \(simpleTranscript ? "simple (bisect ON)" : "full")"
                )
                Task { @MainActor in KadeBreadcrumbs.drop("send feedback done") }
                // Session 23 (Kade: "the space between the send sound and
                // the thinking sound is huge"): the soft waiting ticks
                // start a breath after the send bloop and run until the
                // reply lands or the send fails — the whole generation
                // (and TTS fetch on voice messages) is audibly "alive"
                // now instead of dead air. Guarded on still-sending so a
                // fast reply never starts a loop after the fact.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    if case .sending = sendState { Earcons.shared.startWaitingLoop() }
                }
            }
            else if case .sending = old, case .idle = new {
                Earcons.shared.play(.messageReceived)
                // Aug 6 2026 (her "haptics to match visuals" ask): the reply
                // lands in the hand too — soft double-knock now, and any
                // Game Parlor sound cues in the reply fire their FELT twins
                // a breath later (the append needs a moment to land in
                // `messages`; 700ms matches the projection-refresh pattern
                // above and is imperceptible under the bloop + TTS start).
                KadeHaptics.replyLanded()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    if let raw = messages.last(where: { !$0.isCreatedByUser })?.displayText {
                        KadeHaptics.gameCues(from: raw)
                    }
                }
                // Context meter v2: re-project once the turn settles (a
                // breath after idle, letting the reply's own append land
                // first so the projection sees the branch tip it will
                // actually bill from).
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    await refreshContextProjection()
                }
                // Autoplay handoff (session 28): when this reply is about to
                // be read aloud, the ticks keep running underneath the
                // received bloop and through the TTS fetch -- the
                // isClipPlaying watcher below stops them the moment the
                // voice starts, the isSpeaking watcher stops them if TTS
                // fails (its error boop already sounded), and the watchdog
                // stops them if everything just hangs. No autoplay = stop
                // exactly as before.
                if awaitingSpokenReply {
                    // July 24 2026 (her report: the loop rode full-volume
                    // OVER the received bloop): duck it under the bloop,
                    // then ease back up for the TTS-fetch stretch. The
                    // stop is still owned by the watchers below.
                    Earcons.shared.duckWaitingLoop(resume: true)
                    speechWaitWatchdog?.cancel()
                    speechWaitWatchdog = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 12_000_000_000)
                        if !Task.isCancelled { endSpeechWait() }
                    }
                } else {
                    // No voice coming: fade out under the bloop instead of
                    // the old hard cut (same 120ms dip, no resume), then
                    // release the player.
                    Earcons.shared.duckWaitingLoop(resume: false)
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        Earcons.shared.stopWaitingLoop()
                    }
                }
            }
            else if case .failed = new {
                endSpeechWait()
                Earcons.shared.play(.error)
            }
        }
        // The two halves of the session-28 autoplay handoff (see the
        // sending->idle branch above). First: the clip actually started --
        // stop the ticks, the voice takes over seamlessly. Second: the speak
        // queue drained without a clip ever starting (isSpeaking true->false
        // while still waiting) -- TTS failed, VoiceService's own error boop
        // already said so audibly, stop the ticks now instead of letting the
        // watchdog drag them out.
        .onChange(of: voiceService.isClipPlaying) { _, playing in
            if playing, awaitingSpokenReply { endSpeechWait() }
        }
        .onChange(of: voiceService.isSpeaking) { was, speaking in
            if was, !speaking, awaitingSpokenReply { endSpeechWait() }
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
        .fullScreenCover(isPresented: $showingSpotterCall) {
            // Session 26: Spotter from the launch chat. Mirrors the home
            // screen's construction (agentId nil + spotterDirect) — but the
            // post-call transcript hands off through the SAME sheet enum the
            // phone button uses (`.transcript`), NOT a navigationDestination:
            // this screen sits pushed in the home stack, and a second
            // `SpotterTranscriptHandoff` destination declaration in one
            // stack is exactly the build-121 collision class the home
            // screen's doc comment warns about.
            CallView(
                agentId: nil,
                agentName: "Your Spotter",
                apiClient: apiClient,
                spotterDirect: true,
                onOpenTranscript: { convo in
                    activeSheet = .transcript(ChatTranscriptHandoff(conversation: convo))
                }
            )
        }
        .fullScreenCover(isPresented: $showingCall) {
            CallView(
                agentId: selectedAgentId,
                agentName: agentDisplayLabel,
                apiClient: apiClient,
                // Session 26 (call continuity, her spec): a call placed from
                // INSIDE this conversation continues it -- context seeded on
                // pickup, transcript appended here on hangup. A brand-new
                // not-yet-sent conversation has nil and gets a fresh call.
                conversationId: conversationId,
                onOpenTranscript: { convo in
                    if let current = conversationId, convo.conversationId == current {
                        // The call merged into THE CONVERSATION ALREADY OPEN
                        // behind this cover -- presenting a second copy of it
                        // as a sheet would stack the same screen twice. Just
                        // reload in place; the transcript is in the history
                        // the user lands back on.
                        Task {
                            if let fresh = try? await conversationsService.fetchMessages(conversationId: current) {
                                messages = fresh
                            }
                            UIAccessibility.post(
                                notification: .announcement,
                                argument: "Call added to this conversation."
                            )
                        }
                    } else {
                        activeSheet = .transcript(ChatTranscriptHandoff(conversation: convo))
                    }
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

    /// What the transcript ForEach (and both rotors) actually render:
    /// everything, unless an in-conversation search is narrowing things.
    private var visibleMessages: [KadeMessage] {
        let query = messageSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard messageSearchActive, !query.isEmpty else {
            // The window (see transcriptWindow's doc comment). suffix keeps
            // the NEWEST rows — the conversation's living end. During an
            // active stream the window narrows further (Part 70.8, see
            // streamingWindowRows) unless she asked for earlier rows.
            var effectiveWindow = transcriptWindow
            if case .sending = sendState, !streamThinDisabledByUser {
                effectiveWindow = min(effectiveWindow, Self.streamingWindowRows)
            }
            if messages.count > effectiveWindow {
                return Array(messages.suffix(effectiveWindow))
            }
            return messages
        }
        return messages.filter {
            $0.readableText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// How many older messages the window is hiding (0 while searching —
    /// search renders its matches, not the window).
    private var hiddenEarlierCount: Int {
        let query = messageSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if messageSearchActive && !query.isEmpty { return 0 }
        var effectiveWindow = transcriptWindow
        if case .sending = sendState, !streamThinDisabledByUser {
            effectiveWindow = min(effectiveWindow, Self.streamingWindowRows)
        }
        return max(0, messages.count - effectiveWindow)
    }

    private var messageSearchSummary: String {
        let count = visibleMessages.count
        if count == 0 {
            return "No messages match. Clear the search to see the whole conversation."
        }
        let noun = count == 1 ? "message matches" : "messages match"
        return "\(count) of \(messages.count) \(noun). The conversation below is narrowed to them."
    }

    /// Same hand-built field as the conversation list's search (same
    /// iOS 17 `.searchable` focus limitation, same look). Unlike that
    /// screen it DOES grab the keyboard on appear -- it only ever appears
    /// because the search button was explicitly activated, so the keyboard
    /// is the whole point, not a hijack.
    private var messageSearchBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search this conversation", text: $messageSearchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .focused($messageSearchFocused)
                    .accessibilityLabel("Search this conversation")
                    .accessibilityHint("Type to narrow the messages to ones whose text matches.")
                    .onAppear { messageSearchFocused = true }
                Button {
                    endMessageSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close search")
                .accessibilityHint("Clears the search and shows the whole conversation again.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            if !messageSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(messageSearchSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(messageSearchSummary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func endMessageSearch() {
        messageSearchText = ""
        messageSearchActive = false
        messageSearchFocused = false
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if hiddenEarlierCount > 0 {
                        showEarlierButton(proxy)
                    }
                    ForEach(visibleMessages) { message in
                        MessageRow(
                            message: message,
                            simpleMode: simpleTranscript,
                            canEdit: canEdit(message),
                            canRegenerate: canRegenerate(message),
                            voicePlayback: voiceService.nowPlayingKey == message.id
                                ? (voiceService.isPaused ? .paused : .playing)
                                : .idle,
                            onReadAloud: { readAloud(message) },
                            onPauseResume: {
                                if voiceService.isPaused {
                                    voiceService.resumeSpeaking()
                                    UIAccessibility.post(notification: .announcement, argument: "Playing.")
                                } else {
                                    voiceService.pauseSpeaking()
                                    UIAccessibility.post(notification: .announcement, argument: "Paused.")
                                }
                            },
                            onReadingView: message.isCreatedByUser ? nil : {
                                readingReturnId = message.id
                                readingMessage = message
                            },
                            onEdit: { beginEdit(message) },
                            onRegenerate: { sendTask = Task { await regenerate(message) } },
                            onSaveVoiceMessage: { Task { await saveVoiceMessage(message) } },
                            onShare: { activeSheet = .share(ShareItem(text: message.readableText)) },
                            onDelete: canDelete(message) ? { deletingMessage = message } : nil,
                            isPreparingVoiceMessage: preparingVoiceMessageId == message.id
                        )
                        .id(message.id)
                        .accessibilityFocused($a11yFocus, equals: .message(message.id))
                        // Build 222: registers this row in the rotor namespace.
                        // Scoped matching is the half of the restore that keeps
                        // SwiftUI from searching the whole stack for an entry.
                        .accessibilityRotorEntry(id: message.id, in: transcriptRotorSpace)
                    }
                    if !liveThink.isEmpty, case .sending = sendState {
                        liveThinkingBubble
                        answerNowButton
                    }
                    if !liveReply.isEmpty, case .sending = sendState {
                        liveReplyBubble
                    }
                    if case .sending = sendState {
                        replyingRow.id(Self.replyingRowId)
                    }
                }
                .padding()
            }
            .onAppear {
                scrollToBottom(proxy)
                rebuildRotorItems()
            }
            .fullScreenCover(item: $readingMessage, onDismiss: {
                // Hand VoiceOver focus back to the message the reader was
                // opened from -- the same focus-restoration promise the
                // web version makes with its openerRef.
                if let id = readingReturnId {
                    a11yFocus = .message(id)
                    readingReturnId = nil
                }
            }) { message in
                ReadingView(
                    speaker: message.speakerLabel,
                    text: message.readableText.isEmpty
                        ? "(No text in this reply — it looks like tool activity only.)"
                        : message.readableText
                )
            }
            .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: sendState) { _, _ in
                /* ⭐ BUILD 217: the `scrollToBottom(proxy)` that used to sit
                 * here is GONE. On a send BOTH of these hooks fire -- the
                 * optimistic row changes `messages.count` and the state
                 * change fires this one -- so every send paid for TWO forced
                 * LazyVStack position resolutions, the second one targeting
                 * `replyingRowId`, a row being inserted in that same commit.
                 * The count hook above already scrolls, and `scrollToBottom`
                 * reads `sendState` itself when it picks its target, so the
                 * newest row still gets the scroll. */
                // Covers the cases the cheap signature can't see on its own:
                // an edit or a regenerate rewrites a message IN PLACE, so the
                // count and the last id both stay put while the text changes.
                // Every one of those paths moves sendState, so rebuilding here
                // closes the staleness gap without watching message bodies.
                rebuildRotorItems()
            }
            .onChange(of: rotorSignature) { _, _ in rebuildRotorItems() }
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
            // Aug 13 2026 — these two used to be the most expensive thing on
            // the screen. Each one filtered the ENTIRE message array and
            // called rotorLabel -> readableText per message, and rotor bodies
            // rebuild on every view-body evaluation — which during a live
            // stream was every 250ms, on top of a sanitizer that cached
            // nothing. Now they read two precomputed arrays and do no work
            // beyond handing SwiftUI strings it already has. See
            // rebuildRotorItems for when those arrays refresh.
            /* ⭐⭐⭐ BUILD 214 — THE ACTUAL SEND-TIME FREEZE, FOUND Aug 18 2026
             * after six builds that each moved the symptom.
             *
             * These two custom `accessibilityRotor`s WERE the wedge. Removed.
             *
             * The proof is the database, not another guess. Her freezing
             * conversation ("Menstrual disc size choice") is SIX rows, biggest
             * rendered row 2,190 chars — tiny — and it still froze the main
             * thread 30+ seconds. Every earlier theory (giant text, the send
             * prologue commits, transcript row count, the chunker) was
             * cleared: build 211's crumbs cleared the row insert and the
             * re-window, 212's cleared the whole send prologue, and the DB
             * cleared text size. What was left is what every freeze had in
             * common and no build had touched: VoiceOver + a transcript
             * mutation.
             *
             * `AccessibilityRotorEntry(label, id:)` is not free the way the
             * Aug-13 note hoped. Making the rotor CONTENT cheap (precomputed
             * label strings) fixed the wrong half. The expensive half is
             * LOCATION RESOLUTION: to place each entry, SwiftUI must match its
             * id to an element in the LazyVStack and compute that element's
             * geometry — which forces those rows to lay out. With VoiceOver
             * active, every transcript change (a send appends a row and moves
             * sendState) makes SwiftUI re-resolve every entry across BOTH
             * rotors, laying out the whole transcript synchronously on the
             * main thread. That is exactly the MetricKit signature: dozens of
             * recursive SwiftUICore layout frames bottoming out in UIFoundation
             * text measurement, ~10s CPU, killed by the 10s scene-update
             * watchdog. It fires regardless of text size (6 modest rows do it)
             * and ONLY with VoiceOver — which is every freeze on record, all
             * tagged `vo`, and none reproducible by a sighted tester.
             *
             * The rows themselves are each still their own VoiceOver element,
             * so messages stay fully navigable by normal swipe. What is lost
             * is the "Your messages" / "Replies" rotor categories (jump by
             * sender). Worth losing to stop force-quits; can be reintroduced
             * later with the performant pattern (AccessibilityRotorEntry with
             * an explicit `prepare`/scroll closure, or a manual rotor that
             * doesn't force pre-layout). rebuildRotorItems + the two arrays are
             * left in place, dormant and cheap, so that restore is a small,
             * clean diff — nothing reads them now. */
            /* ⭐⭐ BUILD 222 — THE RESTORE, AND THE HONEST REASON IT IS SAFE.
             *
             * Build 214 removed these on the theory that they were the freeze.
             * THAT THEORY WAS DISPROVEN THE SAME DAY: 215, 216, 217, 218, 219
             * and 220 all froze with the rotors already gone, and the hunt
             * ended somewhere else entirely (a `@State` write inside the
             * `replyingRow` commit — see KadePulseDot / build 221). So jumping
             * by sender was taken away from her for a wrong guess, and giving
             * it back costs nothing that was ever proven.
             *
             * What DOES survive from 214's analysis is the Aug-13 finding that
             * these were expensive: `AccessibilityRotorEntry(label, id:)` makes
             * SwiftUI locate each entry by searching for a matching element and
             * computing its geometry, so under VoiceOver every transcript
             * mutation re-resolved every entry across both rotors. Expensive is
             * not the same as fatal — but it is not worth re-adding either.
             *
             * So the restore uses the pattern Apple documents for exactly this,
             * and it is a different shape in two ways:
             *
             *   1. `in: transcriptRotorSpace` — a `@Namespace` the rows opt into
             *      via `.accessibilityRotorEntry(id:in:)`. SwiftUI matches
             *      inside that namespace instead of searching the stack.
             *   2. a `prepare` closure that scrolls the row into view. This is
             *      the part that removes the eager work: an entry no longer has
             *      to be laid out for the rotor to KNOW about it. It is
             *      resolved on demand, when she actually dials to it.
             *
             * The item arrays are still precomputed by `rebuildRotorItems`, so
             * the Aug-13 content fix is kept too — labels are built once per
             * transcript change, never per body evaluation.
             *
             * ⚠️ NOTE FOR WHOEVER SHIPS THIS: it goes out WITH the heartbeat
             * restore as one build, deliberately, after 221 has had a few days
             * of silence. Two feature restores in one build keeps the freeze
             * clock clean; shipping either one alone would have reset it twice. */
            .accessibilityRotor("Your messages") {
                ForEach(userRotorItems) { item in
                    AccessibilityRotorEntry(item.label, item.id, in: transcriptRotorSpace) {
                        proxy.scrollTo(item.id, anchor: .center)
                    }
                }
            }
            .accessibilityRotor("Replies") {
                ForEach(replyRotorItems) { item in
                    AccessibilityRotorEntry(item.label, item.id, in: transcriptRotorSpace) {
                        proxy.scrollTo(item.id, anchor: .center)
                    }
                }
            }
        }
    }

    private static let replyingRowId = "replying-indicator"

    /// Session 35 encore: the LIVE thinking bubble. Collapsed by default —
    /// one tap (or VoiceOver double-tap) opens it and the thoughts pour in
    /// as they stream. VoiceOver manners: ONE announcement when thinking
    /// starts (in performSend), then silence — the group's value reads a
    /// running length on focus instead of narrating every token, and the
    /// streaming text never grabs focus. Cleared at final, when the real
    /// message's own expandable think part takes over.
    /// The reply, growing live as the character writes it — the sighted twin
    /// of hearing somebody talk instead of waiting for the letter to arrive.
    /// Sanitized every flush (forDisplay), VoiceOver-hidden (see the state
    /// block note), replaced by the real saved message the moment final lands.
    private var liveReplyBubble: some View {
        // Part 70.8: this used to be ONE growing Text -- the exact unbounded
        // TextKit job the landed path stopped doing in 208, still alive on
        // the streaming row. Chunked the same way now: early chunks are
        // stable strings SwiftUI never re-lays-out, so each flush pays for
        // the tail chunk only. Short streams keep the single-Text path
        // inside chunkLongText (below threshold it returns [text]).
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(MessageRow.chunkLongText(liveReply).enumerated()), id: \.offset) { piece in
                    Text(piece.element)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    private var liveThinkingBubble: some View {
        DisclosureGroup(isExpanded: $liveThinkExpanded) {
            // Aug 5 2026 (her call: "just be closed and then if you open,
            // you can view the thoughts as they come in like you would a
            // message"): the frozen-snapshot label is GONE. This Text is a
            // plain live element — it grows append-only, never announces,
            // never grabs focus; a screen reader reads whatever is there
            // when she lands on it and can come back for more, exactly
            // like reading a streaming message. The close/reopen dance is
            // dead. (Progress lines still speak only while CLOSED.)
            // Part 70.8: chunked like the live reply (one growing Text was
            // the unbounded-layout shape; freeze #3 hit six seconds after
            // "first think chunk"). VoiceOver reads the chunks in order on
            // focus -- same read-at-will behavior, now in bounded pieces.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(MessageRow.chunkLongText(liveThink).enumerated()), id: \.offset) { piece in
                    Text(piece.element)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } label: {
            // Aug 4: the brain gently pulses while thoughts pour in -- the
            // sighted twin of the bubbling sound. Double-gated on system
            // Reduce Motion AND the in-app motion override, decorative
            // only (the symbol change is invisible to VoiceOver).
            Label("Thinking it through…", systemImage: "brain")
                .font(.footnote.bold())
                .foregroundStyle(.secondary)
                .symbolEffect(
                    .pulse,
                    options: .repeating,
                    isActive: !(systemReduceMotion || UserDefaults.standard.bool(forKey: "kade.feedback.reduceMotion"))
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Color(uiColor: .secondarySystemBackground).opacity(0.6),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        // Aug 4 evening: while OPEN the value is a stable "Open." (a value
        // that churns every chunk chatters over the readout); while closed
        // the running count rounds to hundreds so it only ticks
        // occasionally.
        .accessibilityValue(
            liveThinkExpanded
                ? "Open."
                : "Closed. About \(max((liveThink.count / 100) * 100, 100)) characters of thought so far."
        )
        .accessibilityHint(liveThinkExpanded ? "Double-tap to close the thoughts." : "Double-tap to open and read the thoughts as they arrive.")
    }

    /* ⭐ BUILD 217 -- FINISHING WHAT BUILD 205 STARTED AND LEFT HALF DONE.
     *
     * 205 measured that `KadeThinkingBubbles`' TimelineView was THIRTY
     * view-graph rebuilds a second inside the transcript for the whole
     * generation window, called it "main-thread cost that its user cannot
     * perceive by any means," and gated it under VoiceOver. It cured nothing
     * -- because the two decorations sitting RIGHT BESIDE it were never
     * gated: `ProgressView()`'s indeterminate spinner, and `KadePulseDot`'s
     * `.repeatForever` animation whose `pulsing` flag is set from `onAppear`
     * DURING the very commit that inserts this row.
     *
     * And the numbers say churn is exactly what this is. Every crash in this
     * hunt reports ~10.0s of application CPU (208: 9.973 · 211: 10.156 ·
     * 212: 10.082 · 215: 9.999 · 216: 9.923) against a 10.00s watchdog
     * allowance -- ONE CORE PEGGED FOR THE WHOLE ALLOWANCE. The "17% CPU"
     * beside it is that same 10s spread across a ~60s reporting window, and
     * reading it as "blocked, not busy" (build 211's comment, and the two
     * ground-truth lines that repeated it) was wrong. It is busy.
     *
     * So under VoiceOver this row is now TEXT ONLY. She loses nothing she
     * can perceive: every decoration here is `accessibilityHidden`, and the
     * row's own label ("X is replying") plus the waiting-tick earcons carry
     * the whole non-visual story. `KadePulseDot` stays in the tree with its
     * visual stilled by its own new gate -- that is what keeps her opt-in
     * haptic heartbeat beating while the animation stops. */
    private var replyingRow: some View {
        let who = messages.last(where: { !$0.isCreatedByUser })?.speakerLabel ?? "The assistant"
        return HStack(spacing: 8) {
            if !voiceOverOn { ProgressView() }
            // Session 20 visual flair: a soft pulsing dot while a reply is in
            // flight. Purely decorative -- KadePulseDot is accessibilityHidden
            // and collapses to a static dot under Reduce Motion, so VoiceOver
            // and motion-sensitive users are untouched.
            /* ⭐⭐ BUILD 221 -- HER CALL: BELT AND BRACES, THE DOT LEAVES THE
             * TREE ENTIRELY UNDER VOICEOVER.
             *
             * 220's crumbs cleared the composer teardown, the row insert and
             * the focus move, and pinned the wedge inside the `sendState =
             * .sending` commit. Under VoiceOver `ProgressView` and
             * `KadeThinkingBubbles` were already gated out, which left this
             * row as `Text` plus one view with a lifecycle -- and
             * `KadePulseDot.onAppear` ran `beat?.cancel(); beat = nil`, an
             * unconditional `@State` write INSIDE that commit, ahead of every
             * guard, so no switch could stop it.
             *
             * KadePulseDot's own internals are fixed too (the state is gone,
             * the heartbeat moved to `.task(id:)`), so every other place it
             * is used is safe. Offered her that fix alone; she took the
             * stronger version, and she is right to while a freeze is still
             * live -- under VoiceOver this commit now installs NOTHING with a
             * lifecycle at all.
             *
             * ⚠️ THE COST, STATED PLAINLY: her opt-in haptic heartbeat does
             * not beat during a reply while VoiceOver is on. She asked for
             * that beat in session 21 and build 217 kept this dot in the tree
             * specifically to preserve it. RESTORE = delete this gate (the
             * `.task` version is safe to insert here), and it should be
             * restored the moment 221 proves the freeze dead. */
            /* ⭐⭐⭐ BUILD 223 — THE GATE IS BACK, AND THE VERDICT IS IN.
             *
             * Build 222 removed this gate to give her the heartbeat under
             * VoiceOver. It CRASHED on the first send — her words, "no send
             * sound," and the ring agrees exactly: 06:13:53 trail runs
             * `send feedback queued` -> `replying row appeared` -> then
             * MAIN THREAD UNRESPONSIVE, with `send feedback done` and
             * `sending state painted` never firing and the queued earcon
             * never playing. The wedge is in the commit that installs THIS
             * row, and the only thing 222 added to that commit is this dot.
             *
             * Verdict, earned empirically over 221->222->223: 221's
             * `.task(id:)` refactor was necessary but NOT sufficient. A
             * `KadePulseDot` present in the `replyingRow` commit UNDER
             * VoiceOver reintroduces the freeze regardless -- its mere
             * installation forces work into that already-expensive commit.
             * This gate is not belt-and-braces; it is load-bearing, and it
             * stays.
             *
             * The rotors (222's other half) are UNTOUCHED and stay: the ring
             * puts the wedge in the send commit, which the rotors never enter
             * (outer ScrollView, on-demand `prepare` resolution), and 215-220
             * all froze without them. 223 keeps them, which makes it the clean
             * bisect -- if 223 holds, the rotors are cleared for good.
             *
             * ⚠️ THE HEARTBEAT UNDER VOICEOVER IS A DEAD END BY THIS PATH.
             * Giving it back means driving the beat from the SEND LOGIC (a
             * timer keyed on `sendState`), NOT from a SwiftUI view living in
             * the commit -- a real change for a calm day, not a fix to ship
             * while she is asleep. */
            if !voiceOverOn {
                KadePulseDot(color: .accentColor, diameter: 8, active: true, haptic: true)
            }
            Text("\(who) is replying…")
                .foregroundStyle(.secondary)
            // Aug 4 2026: her hypnotic bubbles, native -- only in the pure
            // waiting beat. The moment thoughts start pouring into the live
            // bubble, that takes the visual job and these step aside (same
            // rule as the web: never fight the streaming content).
            if liveThink.isEmpty, !voiceOverOn {
                KadeThinkingBubbles()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        /* Build 221: the bisect continues one layer in. This crumb can only
         * fire once the commit that inserts this row has COMPLETED. If a
         * future trail still stops after `send feedback queued` and this is
         * absent, the row insert is still the wedge and KadePulseDot was not
         * the whole of it. If it is present and the freeze is gone, done.
         * Dropping a crumb is a file write on a utility queue -- it writes no
         * state and cannot itself schedule an update. */
        .onAppear { KadeBreadcrumbs.drop("replying row appeared") }
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
    /// One VoiceOver rotor entry, precomputed. `label` is built ONCE per
    /// transcript change rather than per view-body evaluation — see the
    /// accessibilityRotor pair in `messageList` for what that replaced.
    struct RotorItem: Identifiable {
        let id: String
        let label: String
    }

    /// Cheap change-detector for the transcript. Deliberately O(1): a count,
    /// the last id, and the search text. It cannot see an in-place edit of an
    /// older message — that gap is covered by the sendState hook instead, and
    /// the two together are still far cheaper than walking every message on
    /// every body evaluation.
    private var rotorSignature: String {
        let search = messageSearchActive ? messageSearchText : ""
        return "\(messages.count)|\(messages.last?.id ?? "")|\(search)|\(transcriptWindow)"
    }

    private func rebuildRotorItems() {
        let source = visibleMessages
        userRotorItems = source
            .filter { $0.isCreatedByUser }
            .map { RotorItem(id: $0.id, label: rotorLabel(for: $0)) }
        replyRotorItems = source
            .filter { !$0.isCreatedByUser }
            .map { RotorItem(id: $0.id, label: rotorLabel(for: $0)) }
    }

    private func rotorLabel(for message: KadeMessage) -> String {
        let time = KadeDateFormatting.time(from: message.createdAt) ?? ""
        let preview = message.readableText.isEmpty ? "…" : message.readableText
        let truncated = preview.count > 60 ? String(preview.prefix(60)) + "…" : preview
        return time.isEmpty ? truncated : "\(time): \(truncated)"
    }

    /// The window's one control: a single, clearly-labeled button above the
    /// transcript. Expanding keeps the reader's place (the previously-oldest
    /// visible row is re-anchored to the top) and tells VoiceOver what
    /// happened in plain words.
    private func showEarlierButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            // Part 70.8: asking for earlier rows mid-stream turns stream
            // thinning off for this stream -- the guard never overrules her.
            if case .sending = sendState { streamThinDisabledByUser = true }
            let anchorId = visibleMessages.first?.id
            transcriptWindow += Self.transcriptWindowStep * 2
            rebuildRotorItems()
            if let anchorId {
                DispatchQueue.main.async { proxy.scrollTo(anchorId, anchor: .top) }
            }
            let remaining = max(0, messages.count - transcriptWindow)
            UIAccessibility.post(
                notification: .announcement,
                argument: remaining > 0
                    ? "Loaded earlier messages. \(remaining) older messages still folded away."
                    : "Loaded the whole conversation."
            )
        } label: {
            Text("Show earlier messages (\(hiddenEarlierCount) more)")
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .accessibilityHint("The newest part of the conversation is shown. Loads older messages above it.")
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
        await refreshContextProjection()
    }

    // MARK: - Agent switcher (Phase 4)

    /// A single row above the composer showing who will answer next, with a
    /// tap target to open `AgentPickerView`. Disabled while a send is in
    /// flight — switching mid-wait wouldn't affect the reply already
    /// requested, only the confusion of tapping something that visibly does
    /// nothing to it.
    private var agentSection: some View {
        HStack(spacing: 16) {
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
            .accessibilityLabel("Talking to \(agentDisplayLabel)")
            .accessibilityHint("Opens the list of agents to switch who answers your next message.")
            .accessibilityFocused($a11yFocus, equals: .agentButton)

            // Session 25: moved here from the toolbar (see the toolbar
            // comment). Session 21g's original design note still applies:
            // "agent maker sets it, user changes it once they get it" --
            // the pick is saved per-user, per-agent, and follows the
            // account everywhere (read-aloud here, and calls).
            Button {
                activeSheet = .voicePicker
                if let id = selectedAgentId {
                    Task { voiceOverride = (await voiceService.voiceOverride(forAgent: id)) ?? "" }
                }
            } label: {
                Image(systemName: "waveform")
                    .font(.footnote)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .disabled(selectedAgentId == nil)
            .accessibilityLabel("Voice")
            .accessibilityHint("Change the voice \(agentDisplayLabel) speaks in.")
        }
        .padding(.horizontal)
        .padding(.top, 8)
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
    /// Session 23 (Kade: "we need something in chat like that context
    /// window box on the web"). The essence of the web gauge, native: sum
    /// of the server's own per-message tokenCount over what's loaded,
    /// against the fleet's EFFECTIVE window -- the model's real limit
    /// (see the constant's Aug 4 note below; the old "yaml caps it at
    /// 120K" story is retired). Labeled "about" because this is
    /// the same client-side estimate the web shows between authoritative
    /// snapshots: system-prompt/tool overhead isn't counted. One plain
    /// accessibility element, no controls inside. If the yaml's cap ever
    /// changes, update the constant with it.
    /// Aug 4 2026 (her ask: windows fit the model — and her correction:
    /// kimi-k3 is a 1,048,576-token model, verified same day): the fork
    /// clamps every agent's window to min(its configured value, the
    /// model's real limit), and the context-projection endpoint now
    /// resolves that AUTHORITATIVE number server-side per agent — so the
    /// v2 gauge is exact regardless of this constant. This is only the
    /// OFFLINE v1 estimate's denominator: 600,000 = the default agent's
    /// (Kiana's) effective window on k3. "About" has never been more
    /// literal; the projection corrects it the moment it answers.
    private static let effectiveContextTokens = 600_000

    /// CONTEXT METER v2 (session 33, leftovers item 8): the server's own
    /// projection replaces the client-side sum when it's available. POST
    /// /api/endpoints/context-projection runs the SAME pruning math the
    /// next model call will run (agents SDK, no model invoked) and hands
    /// back the real budget: instructions + tool schemas + message tokens,
    /// none of which the v1 estimate could see. v1's sum stays as the
    /// fallback for offline/error/null answers, so the gauge can only get
    /// MORE honest, never disappear. `maxContextTokens` rides in the
    /// request and stays pinned to the yaml's 120K effective cap above --
    /// the server projects for whatever window it's told, it does not know
    /// the yaml cap on its own. If the yaml cap changes, update the one
    /// constant and both halves follow.
    @State private var serverContextUsed: Int?
    @State private var serverContextBudget: Int?
    @State private var contextProjectionInFlight = false

    private struct ContextProjectionAnswer: Codable {
        struct Breakdown: Codable {
            var maxContextTokens: Int? = nil
            var messageTokens: Int? = nil
            var instructionTokens: Int? = nil
            var toolSchemaTokens: Int? = nil
        }
        var breakdown: Breakdown? = nil
        var contextBudget: Int? = nil
        var remainingContextTokens: Int? = nil
    }

    /// One polite call per real change (guarded, paced by the shared
    /// client gate, and rate-limited server-side too). Any failure path
    /// clears the server numbers so the estimate takes back over.
    private func refreshContextProjection() async {
        guard !contextProjectionInFlight,
              let conversationId,
              let lastMessageId = messages.last?.messageId,
              let agentId = selectedAgentId
        else { return }
        contextProjectionInFlight = true
        defer { contextProjectionInFlight = false }
        do {
            var req = apiClient.request(
                path: "api/endpoints/context-projection",
                method: "POST",
                authorized: true
            )
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            struct Body: Codable {
                let conversationId: String
                let messageId: String
                let endpoint: String
                let agentId: String
                let maxContextTokens: Int
            }
            req.httpBody = try JSONEncoder().encode(Body(
                conversationId: conversationId,
                messageId: lastMessageId,
                endpoint: "agents",
                agentId: agentId,
                maxContextTokens: Self.effectiveContextTokens
            ))
            let (data, http) = try await apiClient.send(req)
            guard http.statusCode == 200,
                  let answer = try? JSONDecoder().decode(ContextProjectionAnswer.self, from: data)
            else {
                serverContextUsed = nil
                serverContextBudget = nil
                return
            }
            let budget = answer.contextBudget
                ?? answer.breakdown?.maxContextTokens
                ?? Self.effectiveContextTokens
            var used: Int?
            if let remaining = answer.remainingContextTokens {
                used = max(0, budget - remaining)
            } else if let breakdown = answer.breakdown,
                      let msgTokens = breakdown.messageTokens {
                used = msgTokens + (breakdown.instructionTokens ?? 0) + (breakdown.toolSchemaTokens ?? 0)
            }
            if let used, budget > 0 {
                serverContextUsed = used
                serverContextBudget = budget
            } else {
                serverContextUsed = nil
                serverContextBudget = nil
            }
        } catch {
            serverContextUsed = nil
            serverContextBudget = nil
        }
    }

    @ViewBuilder
    private var contextMeter: some View {
        // Server numbers when the projection answered; the old per-message
        // sum otherwise. `measured` drives the wording -- "of" versus
        // "about" -- so her ear can tell which meter is talking.
        let estimate = messages.reduce(0) { $0 + ($1.tokenCount ?? 0) }
        let measured = (serverContextUsed != nil && serverContextBudget != nil)
        let used = serverContextUsed ?? estimate
        let budget = serverContextBudget ?? Self.effectiveContextTokens
        let percent = (used > 0 && budget > 0)
            ? min(100, Int((Double(used) / Double(budget) * 100).rounded()))
            : 0
        // Session 25 rule kept exactly: the gauge appears only once the
        // window is genuinely filling (60%+), orange urgency at 85. Below
        // 60 the bottom stack stays one element shorter on every
        // swipe-through.
        if percent >= 60 {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.needle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(
                    measured
                        ? "Context: \(used.formatted()) of \(budget.formatted()) tokens \u{2014} \(percent)%"
                        : "Context: about \(used.formatted()) of \(budget.formatted()) tokens \u{2014} \(percent)%"
                )
                .font(.caption2)
                .foregroundStyle(percent >= 85 ? Color.orange : Color.secondary)
            }
            .padding(.horizontal)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                measured
                    ? "Context window \(percent) percent full, server measured. \(used.formatted()) of \(budget.formatted()) tokens used."
                    : "Context window about \(percent) percent full. Roughly \(used.formatted()) of \(budget.formatted()) tokens used."
            )
        }
    }

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
                    endSpeechWait()
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

    /// Aug 6 2026 (Kade: "seems redundant now to have that stop audio
    /// button on native now that we've tucked it into the rotor"): the
    /// standalone morphing Pause/Resume/Stop control is GONE. Its powers
    /// live on where she actually uses them — each message's rotor carries
    /// Play/Pause/Resume, "Stop and clear" rides as a custom action there,
    /// and flipping Voice Messages off still kills playback instantly. If a
    /// sighted family member misses a visible pause, revert THIS commit.
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
        .accessibilityLabel("Voice message speed")
        .accessibilityValue(VoiceService.rateSpokenLabel(voiceService.playbackRate))
        .accessibilityHint("Double-tap to change how fast voice messages play.")
    }

    // MARK: - Composer (Phase 3)

    private var isSending: Bool {
        if case .sending = sendState { return true }
        return false
    }

    /// Session 26: paperclip at the start of the composer row. All of its
    /// picker plumbing (menu, photo library, file importer) hangs off THIS
    /// button so the feature stays self-contained -- the proven Describe
    /// patterns, one surface over.
    private var attachButton: some View {
        Button {
            showingAttachMenu = true
        } label: {
            Image(systemName: "paperclip")
                .font(.title3)
        }
        .disabled(isSending || attachmentUploading || pendingAttachment != nil)
        .accessibilityLabel(pendingAttachment == nil ? "Attach a photo or file" : "Attachment added")
        .accessibilityHint(pendingAttachment == nil
            ? "Sends a photo or document along with your next message so \(agentDisplayLabel) can look at it."
            : "One attachment per message. Remove the current one first to attach something else.")
        .confirmationDialog("Attach to your next message", isPresented: $showingAttachMenu) {
            Button("Choose a photo") { showingAttachPhotos = true }
            Button("Choose a file") { showingAttachImporter = true }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showingAttachPhotos, selection: $attachPhotoItem, matching: .images)
        .onChange(of: attachPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await loadAttachmentPhoto(newItem)
                attachPhotoItem = nil
            }
        }
        .fileImporter(
            isPresented: $showingAttachImporter,
            allowedContentTypes: Self.attachmentImportTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await importAttachmentFile(url) }
            }
        }
    }

    /// The "something is attached" chip above the composer: status text and
    /// the remove control as true siblings (the Amber rule -- never a
    /// control inside another element's label).
    private var attachmentChipRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(attachmentUploading ? "Attaching…" : "Attached: \(pendingAttachment?.displayName ?? "")")
                .font(.footnote)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(attachmentUploading
                    ? "Attaching your file. Hold on."
                    : "Attached: \(pendingAttachment?.displayName ?? ""). It goes out with your next message.")
            Spacer()
            if attachmentUploading {
                ProgressView()
                    .accessibilityHidden(true)
            } else {
                Button {
                    pendingAttachment = nil
                    UIAccessibility.post(notification: .announcement, argument: "Attachment removed.")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Remove attachment")
                .accessibilityHint("Takes the attachment off your next message. The file itself isn't deleted.")
            }
        }
    }

    private static let attachmentImportTypes: [UTType] = [.pdf, .plainText, .image, .data]

    private func loadAttachmentPhoto(_ item: PhotosPickerItem) async {
        let contentType = item.supportedContentTypes.first
        let mimeType = contentType?.preferredMIMEType ?? "image/jpeg"
        let ext = contentType?.preferredFilenameExtension ?? "jpg"
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            attachmentFailed("Couldn't load that photo. Try again.")
            return
        }
        await uploadAttachment(data: data, mimeType: mimeType, fileName: "photo.\(ext)")
    }

    private func importAttachmentFile(_ url: URL) async {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        if let size = resourceValues?.fileSize, Int64(size) > ChatAttachment.maxUploadBytes {
            attachmentFailed("\(name) is larger than 30 megabytes. Try a smaller file.")
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            attachmentFailed("Couldn't read \(name). Try again.")
            return
        }
        await uploadAttachment(
            data: data,
            mimeType: resourceValues?.contentType?.preferredMIMEType ?? "application/octet-stream",
            fileName: name
        )
    }

    private func uploadAttachment(data: Data, mimeType: String, fileName: String) async {
        attachmentUploading = true
        UIAccessibility.post(notification: .announcement, argument: "Attaching \(fileName).")
        defer { attachmentUploading = false }
        do {
            let uploaded = try await ChatAttachment.upload(
                client: apiClient,
                data: data,
                mimeType: mimeType,
                fileName: fileName,
                conversationId: conversationId,
                agentId: selectedAgentId
            )
            pendingAttachment = uploaded
            KadeHaptics.success()
            UIAccessibility.post(
                notification: .announcement,
                argument: "Attached \(fileName). It goes out with your next message."
            )
        } catch {
            attachmentFailed("Couldn't attach \(fileName). Check your connection and try again.")
        }
    }

    private func attachmentFailed(_ message: String) {
        KadeHaptics.error()
        UIAccessibility.post(notification: .announcement, argument: message)
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
            if attachmentUploading || pendingAttachment != nil {
                attachmentChipRow
            }
            HStack(alignment: .bottom, spacing: 8) {
                attachButton
                deepThinkButton
                /* ⭐⭐ BUILD 218 -- THE FIRST CHANGE IN THIS HUNT AIMED AT A LEAF
                 * FRAME INSTEAD OF A THEORY.
                 *
                 * Her two build-217 stacks (17:55:42Z, both Foreground kills,
                 * 10.087s and 10.131s of app CPU against a 10.00s allowance --
                 * a pegged core) bottom out in **UIFoundation text
                 * measurement** reached through UIKitCore from SwiftUI, and
                 * they RECURSE: `SwiftUICore +464312` appears SEVEN times in
                 * one and SIX in the other, 17 distinct frames repeating for
                 * 56 duplicate frames total. Same family as builds 204 and
                 * 208. The shallower AttributeGraph-topped samples on 211/215/
                 * 216 were the same loop caught at a different instant.
                 *
                 * And the Simple-transcript toggle cleared the message rows:
                 * she froze with every row rendered as one bare `Text` with no
                 * accessibility modifiers at all. So the text being measured
                 * recursively is not in the transcript -- and this is the only
                 * other text-measuring surface on the screen.
                 *
                 * Two things about the old line were wrong together:
                 *   - `axis: .vertical` makes this a MULTI-LINE, UITextView-
                 *     backed control, but `.textFieldStyle(.roundedBorder)` is
                 *     UIKit's single-line bordered style. Sizing that pair is a
                 *     negotiation between a control that wants one line and a
                 *     container that permits several -- and it resolves through
                 *     exactly the UIFoundation/UIKitCore frames at her leaf.
                 *   - `.lineLimit(1...5)` is a RANGE, so the layout has to
                 *     measure the text at multiple candidate heights and pick.
                 *     Nested in flexible stacks, those probes multiply. That is
                 *     the recursion.
                 * `isSending` flipping is what dirties this subtree at the
                 * exact moment she freezes, and no swing in this hunt --
                 * feedback, decorations, chunking, windows, rotors, rows -- has
                 * ever touched it.
                 *
                 * ⚠️ HONEST LIMIT: this is not proven. I checked the obvious
                 * corollary (longer drafts = more line candidates = more work)
                 * against every send in the ring and it did NOT hold -- 37
                 * chars froze, 199 chars was fine, 72 chars did both. Length is
                 * at most an amplifier. What is solid is the leaf, the
                 * recursion, and that the rows are eliminated. Hence the
                 * `simpleComposer` bisect below, so a wrong guess here costs
                 * her a tap instead of another day. */
                if simpleComposer {
                    TextField("Message", text: $draftText)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color(uiColor: .separator))
                        )
                        .disabled(isSending || voiceService.isRecording || voiceService.isTranscribing)
                        .accessibilityLabel("Message")
                        .accessibilityFocused($a11yFocus, equals: .composerField)
                } else {
                    TextField("Message", text: $draftText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(5)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color(uiColor: .separator))
                        )
                        .disabled(isSending || voiceService.isRecording || voiceService.isTranscribing)
                        .accessibilityLabel("Message")
                        .accessibilityFocused($a11yFocus, equals: .composerField)
                }
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
            let next: ThinkMode = thinkMode == .auto ? .deep : thinkMode == .deep ? .instant : .auto
            thinkMode = next
            Self.thinkModeGlobal = next
            // Instant persists across launches; deep deliberately does not
            // (it's stored, but the launch-time reader resets deep -> auto).
            UserDefaults.standard.set(next.rawValue, forKey: Self.thinkModeKey)
            UIAccessibility.post(notification: .announcement, argument: next.spoken)
        } label: {
            Image(systemName: thinkMode == .instant ? "hare" : "brain.head.profile")
                .font(.title3)
                .foregroundStyle(thinkMode == .auto ? Color.secondary : Color.accentColor)
                .padding(6)
                .background(
                    Circle().strokeBorder(
                        thinkMode == .auto ? Color.secondary.opacity(0.4) : Color.accentColor,
                        lineWidth: thinkMode == .auto ? 1 : 2
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(isSending)
        .accessibilityLabel("Thinking")
        .accessibilityValue(
            thinkMode == .auto ? "Automatic" : thinkMode == .deep ? "Deep" : "Instant"
        )
        .accessibilityHint("Automatic decides per question. Deep always takes longer for careful answers. Instant always answers fast. Applies to every message until changed.")
        .sensoryFeedback(trigger: thinkMode) { _, _ in
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
    /// Session 23 focus-bounce fix (Kade: "voiceover bounces your focus so
    /// you can't just double tap the button to be done recording...
    /// sometimes it says stop recording or some shit a couple seconds
    /// after you press it"). Two mechanical causes, both fixed here:
    /// (1) the label used to SWAP VIEW TYPES (ProgressView ↔ Image),
    /// and (2) `.disabled(...)` flipped ON the moment transcription
    /// started — either can rebuild/retire the accessibility element
    /// under VoiceOver's cursor, which reads as a bounce. Now it is ONE
    /// Image always (only systemName changes), never disabled — the
    /// in-flight states are guarded inside toggleRecording instead — and
    /// `toggleRecording` pins accessibility focus here the moment
    /// recording starts. The delayed "Stop recording" announcement she
    /// heard is the label flipping when the audio session actually
    /// engages; that one is genuine, useful state feedback and stays.
    private var micButton: some View {
        Button {
            Task { await toggleRecording() }
        } label: {
            Image(systemName: voiceService.isTranscribing
                ? "waveform.circle.fill"
                : voiceService.isRecording ? "stop.circle.fill" : "mic.circle.fill")
            .font(.title)
            .foregroundStyle(voiceService.isRecording ? .red : .accentColor)
        }
        .accessibilityFocused($a11yFocus, equals: .micButton)
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
        // Sending while a search filter is up would land the new turn
        // invisibly outside the filter -- close the search first so the
        // conversation is whole again when the reply arrives.
        if messageSearchActive { endMessageSearch() }

        let parentId = sendParentOverride ?? messages.last?.messageId
        sendParentOverride = nil
        // Build 207 (the 206 on-camera kill: send tapped, screen frozen
        // ~48s, optimistic bubble never painted, 0x8BADF00D scene-update
        // watchdog). Lead suspect is a send-time main-thread pileup: the
        // composer clear (TextKit teardown of a long dictated draft, plus
        // keyboard and VoiceOver updates) stacked into the SAME SwiftUI
        // transaction as the optimistic append and the sending-state flip.
        // Mitigation, measured not guessed: clear the composer ALONE, let
        // that transaction commit and its frame drain, then start the send
        // machinery in a fresh turn of the run loop. Re-entry is safe: a
        // double-tap in the yield window hits the empty-draft guard above.
        /* ⭐⭐ BUILD 220 -- WHAT VOICEOVER LOSES WHEN THE DRAFT CLEARS.
         *
         * Her build-219 report, in her words: "I typed maybe five words and
         * when I hit send, it moved me to the stat bar where VO fucked up,
         * then crashed" -- and NO send sound. Build 216 made the earcons
         * QUEUE onto the next main-queue turn, so a silent send proves the
         * main thread never got to `sendState = .sending`. The ring agrees
         * and goes further: the 219 trail has NO SEND CRUMBS AT ALL. Not
         * `optimistic row painted`, not anything -- the last entry is
         * `became active` from nine minutes earlier, and the freeze-watch
         * marks kept firing right through the wedge, so the crumb queue was
         * demonstrably alive and writing. The absence is real.
         *
         * That puts the wedge EARLIER than any swing in this hunt has looked.
         * Build 211's rule ("stops before optimistic row painted = it is the
         * row insert") cannot resolve it, because there was never a crumb
         * between the tap and that insert -- the composer clear lives in that
         * blind spot. Build 207 split the clear into its own transaction and
         * assumed that made it safe; it only made it SEPARATE.
         *
         * And "it moved me to the stat bar" is the tell. Throwing focus to
         * the status bar is exactly what VoiceOver does when the element it
         * was focused on stops existing: it re-scans the whole accessibility
         * tree looking for somewhere to land. Under VoiceOver the LazyVStack
         * must materialise its rows for that tree, so an orphan-and-rescan at
         * send time pays for the entire transcript AND the pinned inset
         * cluster in one main-thread breath -- which is the non-converging
         * layout the MetricKit stacks have been showing all along.
         *
         * So give it somewhere to land BEFORE taking anything away. Session
         * 23 already fixed this exact class once (`case micButton`, added
         * when VoiceOver "bounces your focus so you can't just double tap the
         * button to be done recording"); this is the same medicine at the
         * send moment. VoiceOver-only -- a sighted user gets no focus
         * movement at all. */
        KadeBreadcrumbs.drop(
            "send tapped (\(trimmed.count) chars\(UIAccessibility.isVoiceOverRunning ? ", vo" : ""))"
        )
        if UIAccessibility.isVoiceOverRunning {
            a11yFocus = messages.last.map { .message($0.id) }
        }
        draftText = ""
        await Self.nextRunLoopTurn()
        // Build 220: the crumb that build 211's bisect was missing. If a
        // future trail carries `send tapped` but not `draft cleared`, the
        // composer teardown is convicted outright. If it carries both and
        // stops before `optimistic row painted`, it is the row insert, and
        // this whole hypothesis is wrong in a way that says so plainly.
        KadeBreadcrumbs.drop("draft cleared")
        // Session 23: while Deep Think is armed, stamp this send with a
        // FRESH epoch-ms marker -- the exact string the web composer
        // appends (useSubmitMessage: `[DEEP THINK ${Date.now()}]`).
        // reframe-proxy only honors a fresh timestamp, so nothing replayed
        // from history can re-trigger deep reasoning by accident. Applies
        // to plain sends and edit-and-resend alike (both are human-authored
        // composer sends); regenerate deliberately not -- it reuses the
        // already-stripped displayText of an old message.
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        let stamped: String
        switch thinkMode {
        case .deep: stamped = trimmed + " [DEEP THINK \(nowMs)]"
        case .instant: stamped = trimmed + " [INSTANT \(nowMs)]"
        case .auto: stamped = trimmed
        }
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

    /// Build 204 — HER ESCAPE HATCH, her design: "when it chooses deepthink,
    /// some kind of get an instant answer now type button pops up where you
    /// can change it to instant if you don't have time for all the deepthink
    /// crap." Shows only while the thinking bubble is up. Stops the thinking
    /// turn exactly the way Stop does (server abort first, then local
    /// cancel — the Session 17 ordering), waits a beat for the abort to
    /// land, then re-asks the SAME question as a fresh sibling send stamped
    /// [INSTANT <ms>] — the proxy's forced fast lane. Same branch shape as
    /// Regenerate (the documented repeated-question tradeoff of this flat
    /// client applies here too, and it's worth it).
    private var answerNowButton: some View {
        Button {
            answerNowInstead()
        } label: {
            Label("Answer now instead", systemImage: "hare")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Stops the deep thinking and asks for a quick answer to the same question.")
    }

    private func answerNowInstead() {
        guard case .sending = sendState else { return }
        guard let lastUser = messages.last(where: { $0.isCreatedByUser }) else { return }
        // readableText: the same strip the transcript shows — Deep Think and
        // Instant markers both come off, so markers never stack on a re-ask.
        let baseText = lastUser.readableText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseText.isEmpty else { return }
        let parentId = lastUser.parentMessageId
        UIAccessibility.post(
            notification: .announcement,
            argument: "Skipping the deep thinking. Getting the quick answer."
        )
        Task {
            await messageSendingService.abortActive()
            sendTask?.cancel()
            // Let the abort land server-side and the cancelled task settle
            // before the fresh send flips state back to sending.
            try? await Task.sleep(nanoseconds: 800_000_000)
            let stamped = baseText + " [INSTANT \(Int(Date().timeIntervalSince1970 * 1000))]"
            sendTask = Task { await performSend(text: stamped, parentId: parentId, includeAttachment: false) }
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

    /// Ends the session-28 autoplay wait: stops the waiting ticks and
    /// disarms the watchdog. Safe to call redundantly -- stopWaitingLoop is
    /// a no-op when nothing is looping.
    private func endSpeechWait() {
        awaitingSpokenReply = false
        speechWaitWatchdog?.cancel()
        speechWaitWatchdog = nil
        Earcons.shared.stopWaitingLoop()
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
            agentName: message.speakerLabel,
            key: message.id
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
        await performSend(text: promptingUser.displayText, parentId: promptingUser.parentMessageId, includeAttachment: false)
    }

    /// Build 207: one full turn of the main run loop. The awaited
    /// continuation resumes only after everything already queued — including
    /// the SwiftUI commit for state mutated just before the call — has
    /// drained. An honest frame boundary, not a magic-number sleep.
    @MainActor
    private static func nextRunLoopTurn() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { c.resume() }
        }
    }

    /// The shared guts of every send -- a plain Send tap (via `send()`
    /// above), "Edit and Resend," and "Regenerate" all fund here,
    /// differing only in which text and which parent they pass.
    private func performSend(text: String, parentId: String?, includeAttachment: Bool = true) async {
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
        /* ⭐ BUILD 211 -- THE COMMIT THAT WAS STILL FUSED (Aug 18 2026).
         *
         * Build 207 split the COMPOSER CLEAR out of the send transaction and
         * proved the technique works. It left these two lines fused, and they
         * are the rest of the pileup: `messages.append` inserts a row into the
         * LazyVStack, and `sendState = .sending` simultaneously changes what
         * `visibleMessages` returns (the window narrows to streamingWindowRows),
         * adds `replyingRow`, and arms the live think/reply rows. One SwiftUI
         * transaction, doing a row insert AND a list-wide re-window.
         *
         * Why that is the suspect, from her own instrumentation rather than a
         * hunch -- the 4am freeze on build 210 (ring 09:01:17Z):
         *   08:59:57  send started (225 chars, vo)
         *   09:00:04  MAIN THREAD UNRESPONSIVE >=6s
         * There is NO "first frame after send" crumb in that trail, and 207's
         * own comment says exactly what that means: "the app died inside that
         * first commit." The transcript was only ~7 rows, so this was not the
         * long-conversation case 209 addressed -- a short conversation wedged
         * on the commit itself. Every freeze on record also carries `vo`:
         * VoiceOver is always on for her, which forces the LazyVStack to
         * materialise its rows so the accessibility tree can be built, so a
         * commit that both inserts a row and re-windows the list pays for the
         * whole a11y rebuild in one main-thread breath. The MetricKit stack
         * agrees: 61 recursive SwiftUICore layout frames bottoming out in
         * UIFoundation text measurement, killed by the 10-second scene-update
         * watchdog after 17.85s of CPU.
         *
         * So: same cure as 207, applied one layer deeper. Each mutation gets
         * its own transaction and its own frame. The crumbs between them mean
         * the NEXT freeze names which half wedged instead of leaving us to
         * guess -- if the trail stops before "optimistic row painted" it is
         * the row insert, if between the two it is the re-window, and if after
         * both then these frames are innocent and the wedge is later.
         *
         * Re-entry stays safe for the same reason 207's yield is safe: the
         * draft was already cleared before this function was reached, so a
         * double-tap in either window hits the empty-draft guard in send(). */
        messages.append(optimisticMessage)
        await Self.nextRunLoopTurn()
        KadeBreadcrumbs.drop("optimistic row painted")
        /* Build 220: the row she just sent is the right place for VoiceOver
         * to be standing. Its own transaction and its own crumb, keeping
         * build 211's one-mutation-per-commit discipline -- fusing it into
         * the `sendState` flip would rebuild exactly the pileup 211 split. */
        if UIAccessibility.isVoiceOverRunning {
            a11yFocus = .message(optimisticMessage.id)
        }
        await Self.nextRunLoopTurn()
        KadeBreadcrumbs.drop("focus anchored")
        sendState = .sending
        await Self.nextRunLoopTurn()
        KadeBreadcrumbs.drop("sending state painted")
        // Build 207: the crumb grows the two facts the composer-wedge
        // hypothesis needs from the NEXT kill — how big the outgoing text
        // was, and whether VoiceOver was up (both suspects in the 204/206
        // stack's TextKit grind).
        KadeBreadcrumbs.drop(
            "send started (\(selectedAgentId ?? "default"), \(text.count) chars\(UIAccessibility.isVoiceOverRunning ? ", vo" : ""))"
        )
        // Build 207: the localizer. Queued to run AFTER the transaction
        // above commits and paints — if the next kill's trail shows "send
        // started" with NO "first frame after send", the app died inside
        // that first commit (composer/keyboard/optimistic-row pileup); if
        // this fires and death still follows, those frames are innocent
        // and the wedge is later in the turn.
        DispatchQueue.main.async {
            KadeBreadcrumbs.drop("first frame after send")
        }

        // Part 70.8: thinning re-arms fresh on every send; the crumb makes
        // the next freeze trail say whether the bounded transcript was in
        // force when the wedge hit.
        streamThinDisabledByUser = false
        if messages.count > Self.streamingWindowRows {
            KadeBreadcrumbs.drop("transcript thinned to \(Self.streamingWindowRows) rows for stream")
        }

        do {
            let wasNewConversation = conversationId == nil
            // Session 26: a pending attachment rides this send (uploaded
            // already, at pick time). Regenerate passes
            // includeAttachment:false -- a re-ask of an OLD question must
            // never quietly consume a file meant for the NEXT message.
            let files = includeAttachment ? pendingAttachment.map { [$0.asMessagePayload] } : nil
            /* ⭐ BUILD 212 -- BISECTING WHAT 211 NARROWED.
             *
             * Build 211's crumbs did their job and CLEARED two suspects. Her
             * 12:18 freeze trail reads:
             *     12:18:30  optimistic row painted
             *     12:18:31  sending state painted
             *     12:18:31  send started (155 chars, vo)
             *     12:18:38  MAIN THREAD UNRESPONSIVE >=6s
             * Both split commits PAINTED. The row insert and the re-window are
             * innocent, and the wedge lives after "send started" and before the
             * queued "first frame after send" ever ran.
             *
             * The MetricKit stack changed shape completely between builds,
             * which matters: build 208's was 100 frames with 61 recursive
             * SwiftUICore layout frames bottoming out in UIFoundation TEXT
             * MEASUREMENT. Build 211's is 35 frames, no recursion, leaf in
             * AttributeGraph inside a QuartzCore CATransaction commit -- and
             * only 16% application CPU over the window. Blocked, not busy.
             * That looks like a DIFFERENT wedge underneath the one 209/211
             * addressed, not the same one surviving.
             *
             * So this build stops guessing and bisects the remaining gap. Two
             * crumbs, each after its own frame: if the trail dies before "turn
             * state reset" the wedge is in these four @State resets coalescing
             * into one commit; if it dies between that and "request
             * dispatched" it is inside startGeneration on the MainActor; if it
             * reaches both then the send prologue is entirely clean and the
             * wedge is in the streaming callbacks.
             *
             * Giving the resets their own frame is also the cheapest plausible
             * mitigation on its own -- it is the same split that cleared the
             * two frames above, applied to the last un-split commit in the
             * prologue. */
            liveThink = ""
            liveReply = ""
            live.resetTurn()
            liveThinkExpanded = false
            await Self.nextRunLoopTurn()
            KadeBreadcrumbs.drop("turn state reset")
            let resolvedConversationId = try await messageSendingService.send(
                text: text,
                conversationId: conversationId,
                parentMessageId: parentId,
                agentId: selectedAgentId,
                files: files,
                onText: { chunk in
                    // Live reply streaming: coalesced to one sanitize+publish
                    // per 250ms (the think lane's exact crash-hardening
                    // discipline), plus the gentle spoken progress line for
                    // long writes — low priority, waits for silence, same
                    // Settings toggle as spoken thinking progress.
                    if !live.crumbedFirstText {
                        live.crumbedFirstText = true
                        KadeBreadcrumbs.drop("first reply chunk")
                    }
                    live.replyRaw += chunk
                    scheduleLiveReplyFlush()
                    if spokenThinkingProgress,
                       UIAccessibility.isVoiceOverRunning,
                       Date().timeIntervalSince(live.lastWriteProgressAnnounce) >= 20,
                       live.replyRaw.count > 300 {
                        live.lastWriteProgressAnnounce = Date()
                        let words = max((live.replyRaw.split(separator: " ").count / 25) * 25, 25)
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: NSAttributedString(
                                string: "Still writing — about \(words) words so far.",
                                attributes: [.accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.low]
                            )
                        )
                    }
                },
                onThink: { chunk in
                    // Session 35 encore: thoughts pour into the live bubble
                    // as they stream. One spoken heads-up the first time,
                    // then near-silence — the bubble narrates only on focus,
                    // plus (Aug 4, her pick) an optional gentle progress
                    // line about every 20 seconds so a screen-reader user
                    // knows a LONG think is still moving. Progress is
                    // VoiceOver announcement only; thoughts themselves are
                    // never spoken by TTS (her explicit rule).
                    // Aug 5 2026 (the watermelon receipts): reasoning can
                    // QUOTE tool output — including raw citation anchors —
                    // and this bubble is a surface VoiceOver reads, so the
                    // published text is always sanitized over the FULL
                    // accumulated raw (a token split across chunks can't
                    // dodge a full-text pass). Same day, crash hardening:
                    // sanitize+publish is COALESCED to one pass per 250ms
                    // (see live.thinkRaw) instead of per chunk.
                    if !live.crumbedFirstThink {
                        live.crumbedFirstThink = true
                        KadeBreadcrumbs.drop("first think chunk")
                    }
                    live.thinkRaw += chunk
                    scheduleLiveThinkFlush()
                    if !live.announcedThinking {
                        live.announcedThinking = true
                        // Aug 4 evening rework (her report + her instinct
                        // "maybe it should just be closed by default"):
                        // auto-open is for SIGHTED eyes only. Under
                        // VoiceOver the bubble stays collapsed -- the
                        // stable "open at will" control she named as the
                        // pattern every other platform uses -- because an
                        // auto-opened bubble full of live-mutating text is
                        // exactly what kept cutting her readout off.
                        if !UIAccessibility.isVoiceOverRunning {
                            liveThinkExpanded = true
                        }
                        live.lastThinkProgressAnnounce = Date()
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: "Deep thoughts are streaming — the thinking bubble is under the last message."
                        )
                    } else if spokenThinkingProgress,
                              !liveThinkExpanded,
                              Date().timeIntervalSince(live.lastThinkProgressAnnounce) >= 20 {
                        // Progress only speaks while the bubble is CLOSED
                        // (open = she's reading it; talking over her was
                        // the whole bug) and only politely: low-priority
                        // announcements wait for silence instead of
                        // interrupting whatever VoiceOver is mid-way
                        // through.
                        live.lastThinkProgressAnnounce = Date()
                        let rounded = max((live.thinkRaw.count / 100) * 100, 100)
                        UIAccessibility.post(
                            notification: .announcement,
                            argument: NSAttributedString(
                                string: "Still thinking — about \(rounded) characters so far.",
                                attributes: [.accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.low]
                            )
                        )
                    }
                }
            )
            // Build 205: her Aug-15 kill left a NINETY-SECOND hole between
            // "send started" and a "reply landed" that never came, so nothing
            // in the trail could say which of these steps the app died in.
            // Sizes ride along because they are the one thing the crash
            // summary got wrong by guessing (the real reply was 1,860 chars,
            // not the essay the workup assumed).
            KadeBreadcrumbs.drop("stream finished (reply \(live.replyRaw.count) chars, think \(live.thinkRaw.count) chars)")
            liveThink = ""
            liveReply = ""
            live.resetTurn()
            liveThinkExpanded = false
            conversationId = resolvedConversationId
            // Authoritative reload: replaces the optimistic placeholder with
            // whatever the server actually persisted (real ids, real content
            // shape) rather than trusting the SSE payload's exact field set
            // — see MessageSendingService's type doc for why.
            KadeBreadcrumbs.drop("authoritative reload started")
            messages = try await conversationsService.fetchMessages(
                conversationId: resolvedConversationId
            )
            KadeBreadcrumbs.drop("reply landed (\(messages.count) msgs)")
            // Session 28: decide the autoplay handoff BEFORE sendState
            // flips -- the sendState watcher reads this flag to know whether
            // the waiting ticks survive past the received bloop. Same
            // reply-exists condition as the enqueueSpeak below.
            awaitingSpokenReply = readAloudEnabled && messages.contains(where: { !$0.isCreatedByUser })
            sendState = .idle
            if files != nil {
                // Spent successfully -- the server owns it now.
                pendingAttachment = nil
            }
            a11yFocus = messages.last.map { .message($0.id) }
            if wasNewConversation {
                // Session 24 (Kade: new chats "all say new chat"): now that
                // the first send carries the NO_PARENT sentinel (see
                // MessageSendingService.startGeneration), the server names
                // the newborn conversation in parallel with this first
                // reply. Pick the name up in the background -- gen_title
                // long-polls server-side until it lands -- then refresh the
                // list quietly, so by the time she backs out the row reads
                // as its real name instead of "New Chat." Fail-soft: a
                // missed title costs a name, never a message.
                let newId = resolvedConversationId
                Task {
                    if let title = await conversationsService.fetchGeneratedTitle(conversationId: newId) {
                        // Build 207: same special-token strip the list rows
                        // get — the nav bar speaks this string too.
                        generatedTitle = MessageTextSanitizer.stripSpecialTokens(title)
                    }
                    await conversationsService.loadFirstPage()
                }
            }
            // Session 23 hardening (Kade: "When deep think is on, it
            // doesn't auto read the message as a voice message"): the
            // stored deep-reply SHAPE was pulled and proven fine (think
            // part first, text part present, displayText extracts it), so
            // the data side is clean -- the failure is runtime-side and
            // unreproducible from here. Two defenses: (1) the reply is now
            // the last ASSISTANT message, not blindly `messages.last`, so
            // any extra trailing doc a reasoning turn might persist can't
            // silently break the trigger; (2) TTS failures are now audible
            // (see VoiceService.speakOne) instead of indistinguishable
            // from "never fired." If her next deep turn stays silent, an
            // error boop = TTS half; pure silence = trigger half.
            if readAloudEnabled, let reply = messages.last(where: { !$0.isCreatedByUser }) {
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
                    agentName: reply.speakerLabel,
                    key: reply.id
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
            KadeBreadcrumbs.drop("send failed: \(type(of: error))")
            liveThink = ""
            liveReply = ""
            live.resetTurn()
            liveThinkExpanded = false
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
        // Replaces the old `.disabled(...)` on the button (which retired
        // the element under VoiceOver's cursor — the focus bounce): the
        // button stays live and these states just decline politely.
        if voiceService.isTranscribing {
            UIAccessibility.post(
                notification: .announcement,
                argument: "Still turning your last recording into text."
            )
            return
        }
        if isSending {
            UIAccessibility.post(notification: .announcement, argument: "Still sending.")
            return
        }
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
        // Pin VoiceOver to the button that is now "Stop recording" — the
        // whole point of the session-23 fix: double-tap again just works.
        a11yFocus = .micButton
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
/// Aug 4 2026: which voice-playback phase a given message row is in, so its
/// own actions can morph (Play -> Pause -> Resume) for exactly the message
/// that is speaking. Computed by the parent from `VoiceService.nowPlayingKey`.
enum VoicePlaybackPhase { case idle, playing, paused }

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
    /// Build 217: Settings -> "Simple transcript (troubleshooting)". See the
    /// `simpleTranscript` declaration in ConversationDetailView for why this
    /// exists and what its two answers mean.
    var simpleMode: Bool = false
    /// Only the last user message gets an Edit action; see
    /// `ConversationDetailView.canEdit(_:)`.
    let canEdit: Bool
    /// Only the last assistant message gets a Regenerate action; see
    /// `ConversationDetailView.canRegenerate(_:)`.
    let canRegenerate: Bool
    /// Aug 4 2026 (Kade: "tuck it in the rotor with read aloud... the
    /// button can change"): the phase THIS message is in. While it is the
    /// one speaking, the row's "Play as voice message" action reads
    /// "Pause voice message" (or "Resume..."), driven by `onPauseResume`.
    let voicePlayback: VoicePlaybackPhase
    let onReadAloud: () -> Void
    let onPauseResume: () -> Void
    /// Session 25: opens the full-screen distraction-free reader for this
    /// reply. Nil on USER messages (the web feature is AI-replies-only and
    /// this port keeps that) -- nil means neither the rotor action nor the
    /// menu item exists, so VoiceOver never announces an action a message
    /// can't perform.
    let onReadingView: (() -> Void)?
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

    /// Part 70.6 (Aug 15 2026 — her council-board freeze ON build 207): a
    /// long reply used to render as ONE giant Text, a single TextKit layout
    /// job whose sizing recursion is exactly the 0x8BADF00D workup's stack
    /// (61 sizing frames, TextKit at the leaf). Long replies now render as
    /// a stack of paragraph-boundary chunks inside the same bubble: same
    /// glyphs, same look, but every TextKit container stays small and
    /// bounded — and during streaming, early chunks are stable so a landing
    /// long reply re-lays-out only its tail instead of the whole message.
    /// VoiceOver is untouched by construction: the row is one accessibility
    /// element whose label is `accessibleLabel`, never the visual children.
    /// Short messages keep the exact single-Text path they had.
    /* ⭐⭐ BUILD 213 -- THE CHUNKER HAS NEVER ONCE FIRED (Aug 18 2026).
     *
     * Build 208 shipped transcript chunking as the cure for a single giant
     * Text wedging TextKit, and it was the right idea aimed at the right
     * mechanism. It has also never run. The threshold was 4000 characters and
     * her replies are not that long -- EVERY freeze on record sat under it:
     *     208 freeze : reply 1,021 chars
     *     210 freeze : reply 2,190 chars
     *     212 freeze : reply 3,113 chars
     * `chunkLongText` returns `[text]` unchanged below 4000, so all three
     * rendered as ONE Text and the cure was inert. Same class of bug as the
     * titler guard that never fired: a real fix behind a condition that is
     * never true.
     *
     * What proves it is a single row and not the transcript: the 212 freeze
     * was a BRAND NEW conversation on its second send -- three rows on screen
     * (her first message, one 3,113-char reply, the optimistic row) -- and it
     * still wedged the main thread for 30+ seconds. Row count, the 60-row
     * window and the 12-row stream thinning are all therefore innocent; 211's
     * crumbs had already cleared the row insert and the re-window, and 212's
     * cleared the whole send prologue (`turn state reset` and `request
     * dispatched` both fired on the clean send, neither on the wedged one).
     * What is left is the layout of one big Text, and the MetricKit stack
     * agrees: 58 recursive SwiftUICore frames on 212 with the identical
     * repeating offset cycle as build 208's 61, bottoming out in UIFoundation
     * text measurement, killed by the 10s scene-update watchdog. VoiceOver is
     * always on for her, so that row's text is measured for the accessibility
     * tree as well, every commit.
     *
     * So: make the chunker actually engage at the sizes she really receives.
     * 700/600 turns a typical 3,000-char reply into ~5 modest paragraph Texts
     * instead of one monolith. Paragraph boundaries are preserved, so
     * VoiceOver still reads it as continuous prose -- the same "untouched by
     * construction" property 208 designed for, finally switched on. */
    /* ⭐ REVERTED IN BUILD 215 (Aug 18 2026) back to build 208's values.
     * Build 213 dropped these to 700/600 on the theory that a single big Text
     * was the freeze. That theory was WRONG -- the freeze was the custom
     * VoiceOver rotors (build 214), and it reproduced on a SIX-ROW
     * conversation whose biggest row was 2,190 chars. Meanwhile 700/600 did
     * real cosmetic damage: a normal 2,621-char reply split into FOUR pieces
     * with a visible 10pt gap MID-PARAGRAPH (measured: piece 2 ended in the
     * middle of a sentence). Every reply she received was being visually
     * chopped for nothing. Back to 4000/2600, which only ever engages on
     * genuinely huge rows -- the bound 208 actually intended. */
    fileprivate static let chunkThreshold = 4000
    fileprivate static let chunkTarget = 2600

    fileprivate static func chunkLongText(_ text: String) -> [String] {
        guard text.count > chunkThreshold else { return [text] }
        var chunks: [String] = []
        var current = ""
        for para in text.components(separatedBy: "\n\n") {
            let candidate = current.isEmpty ? para : current + "\n\n" + para
            if candidate.count > chunkTarget && !current.isEmpty {
                chunks.append(current)
                current = para
            } else {
                current = candidate
            }
            // A single monster paragraph splits at hard caps so no chunk can
            // recreate the giant-layout problem on its own; back up to the
            // nearest whitespace so a word never splits mid-glyph.
            while current.count > chunkTarget * 2 {
                let cut = current.index(current.startIndex, offsetBy: chunkTarget)
                var cutAt = cut
                var probe = cut
                var steps = 0
                while probe > current.startIndex && steps < 400 {
                    probe = current.index(before: probe)
                    steps += 1
                    if current[probe] == " " || current[probe] == "\n" {
                        cutAt = probe
                        break
                    }
                }
                let dropSeparator = current[cutAt] == " " || current[cutAt] == "\n"
                chunks.append(String(current[..<cutAt]))
                let resumeAt = dropSeparator ? current.index(after: cutAt) : cutAt
                current = String(current[resumeAt...])
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    @ViewBuilder private var messageBodyView: some View {
        if bodyText.count <= Self.chunkThreshold {
            Text(bodyText)
                .font(appearance.messageFont())
                .lineSpacing(appearance.lineSpacing.extraPoints)
                .multilineTextAlignment(message.isCreatedByUser ? .trailing : .leading)
        } else {
            VStack(alignment: message.isCreatedByUser ? .trailing : .leading, spacing: 10) {
                ForEach(Array(Self.chunkLongText(bodyText).enumerated()), id: \.offset) { piece in
                    Text(piece.element)
                        .font(appearance.messageFont())
                        .lineSpacing(appearance.lineSpacing.extraPoints)
                        .multilineTextAlignment(message.isCreatedByUser ? .trailing : .leading)
                }
            }
        }
    }

    var body: some View {
        if simpleMode { simpleRow } else { fullRow }
    }

    /* ⭐ BUILD 217. The stripped row: ONE Text, and not one accessibility
     * modifier on it. No `.accessibilityElement(children: .ignore)`, no
     * `accessibleLabel` interpolating the whole body on every evaluation, no
     * `.accessibilityActions`, no bubble background, no timestamp, no
     * attachment view, no chunking. The speaker is folded into the visible
     * string so she still knows who is talking without a custom label
     * putting one back. VoiceOver reads a plain Text natively.
     *
     * Everything she gives up while this is on (row actions, Reading View,
     * read-aloud, copy) is still reachable from the message Actions menu and
     * the composer -- this strips the ROW, not the app. */
    private var simpleRow: some View {
        Text("\(message.speakerLabel): \(bodyText)")
            .font(appearance.messageFont())
            .lineSpacing(appearance.lineSpacing.extraPoints)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fullRow: some View {
        VStack(alignment: message.isCreatedByUser ? .trailing : .leading, spacing: 6) {
            // Conversation compacting (July 22 2026): a reply that carries a
            // summary block marks the spot where the server condensed the
            // OLDER conversation into a running summary -- payload-only,
            // nothing visible was deleted. One short system-style line,
            // its own VoiceOver stop, deliberately brief by her decision
            // ("one-time subtle note").
            if message.hasCompactionSummary {
                Text("Earlier conversation condensed into a summary — nothing deleted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityLabel("Earlier conversation condensed into a summary. Nothing deleted.")
            }
            // Session 27 (visual delight): agent replies carry a small
            // colored initial circle -- speaker identity at a glance when
            // agents switch mid-conversation. Sits OUTSIDE the row's
            // combined accessibility element, so it hides itself
            // (KadeSpeakerMonogram is accessibilityHidden internally); the
            // user's own messages stay clean on purpose.
            HStack(alignment: .top, spacing: 8) {
            if !message.isCreatedByUser {
                KadeSpeakerMonogram(name: message.speakerLabel)
                    .padding(.top, 2)
            }
            VStack(alignment: message.isCreatedByUser ? .trailing : .leading, spacing: 4) {
                Text(message.speakerLabel)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                messageBodyView
                    // Session 25 (Kade approved the audit list, "All four"):
                    // the transcript used to be bare aligned text -- no
                    // bubble chrome at all, visually spartan next to every
                    // modern chat app. Soft rounded bubbles now: hers in a
                    // gentle accent tint, replies on the system's secondary
                    // surface (adapts to light/dark for free). Purely
                    // decorative -- the row's accessibility element ignores
                    // children and its label is unchanged, so VoiceOver
                    // reads exactly what it read before. High contrast gets
                    // a stronger tint (opacity alone is the low-contrast
                    // trap KadeVisualStyle's own styles avoid).
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        bubbleFill,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                // Session 34 (July 28 2026): attachments finally SHOW on
                // the transcript. Purely visual here -- the row is one
                // accessibility element that ignores children, and
                // `accessibleLabel` appends the spoken "sent with ..."
                // sentence instead, so by ear this stays ONE swipe stop.
                if let files = message.files, !files.isEmpty {
                    ForEach(files) { file in
                        MessageAttachmentView(file: file)
                    }
                }
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
                /* Aug 18 2026 -- ALWAYS OFFERED, not conditional.
                 * It shipped conditional in build 210 on the usual rule that
                 * VoiceOver should never list an action a message can't
                 * perform. In practice that rule backfired here: only turns
                 * that actually THOUGHT carry a think block (measured on her
                 * real data: 15 of 60 recent replies, ~25%), so the action
                 * silently vanished on the other 75% and read as "the feature
                 * is missing" -- she asked for it back believing it had never
                 * shipped. An action that is sometimes there and sometimes not
                 * is worse to navigate by ear than one that is always there
                 * and tells you the honest answer. So: always present, and
                 * when there is nothing to copy it SAYS so rather than
                 * quietly doing nothing. */
                Button("Copy thoughts") {
                    if let thoughts = message.thoughtsText {
                        UIPasteboard.general.string = thoughts
                        UIAccessibility.post(notification: .announcement, argument: "Thoughts copied to clipboard.")
                    } else {
                        UIAccessibility.post(notification: .announcement, argument: "This reply didn't include any thoughts.")
                    }
                }
                switch voicePlayback {
                case .playing:
                    Button("Pause voice message") { onPauseResume() }
                case .paused:
                    Button("Resume voice message") { onPauseResume() }
                case .idle:
                    Button("Play as voice message") { onReadAloud() }
                }
                if let onReadingView {
                    Button("Open reading view") { onReadingView() }
                }
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
            }

            actionsButton
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: message.isCreatedByUser ? .trailing : .leading)
    }

    private var bubbleFill: Color {
        // `appearance` (the live environment object this row already holds
        // for fonts/spacing), NOT KadeVisualStyle's StylePrefs -- that enum
        // is private to its own file, and the environment object is the
        // reactive source of truth anyway (a toggle flip restyles bubbles
        // without a relaunch).
        if message.isCreatedByUser {
            return Color.accentColor.opacity(appearance.highContrast ? 0.30 : 0.15)
        }
        return Color(uiColor: .secondarySystemBackground)
    }

    private var accessibleLabel: String {
        let who = message.isCreatedByUser ? "You said" : "\(message.speakerLabel) said"
        let time = timeLabel.isEmpty ? "" : ", \(timeLabel)"
        var label = "\(who)\(time): \(bodyText)"
        // Session 34: attachments are spoken HERE, as part of the row's one
        // element, rather than adding a second swipe stop -- "You said:
        // look at this, 3:12 PM. Sent with a photo, porch.jpeg, attached."
        if let files = message.files, !files.isEmpty {
            let names = files.map(\.spokenLabel).joined(separator: "; ")
            label += message.isCreatedByUser
                ? " Sent with \(names) attached."
                : " Comes with \(names) attached."
        }
        return label
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
            // Always shown, same reasoning as the rotor action above.
            Button {
                if let thoughts = message.thoughtsText {
                    UIPasteboard.general.string = thoughts
                    UIAccessibility.post(notification: .announcement, argument: "Thoughts copied to clipboard.")
                } else {
                    UIAccessibility.post(notification: .announcement, argument: "This reply didn't include any thoughts.")
                }
            } label: {
                Label("Copy Thoughts", systemImage: "brain")
            }
            switch voicePlayback {
            case .playing:
                Button {
                    onPauseResume()
                } label: {
                    Label("Pause Voice Message", systemImage: "pause.circle")
                }
            case .paused:
                Button {
                    onPauseResume()
                } label: {
                    Label("Resume Voice Message", systemImage: "play.circle")
                }
            case .idle:
                Button {
                    onReadAloud()
                } label: {
                    Label("Play as Voice Message", systemImage: "speaker.wave.2")
                }
            }
            if let onReadingView {
                Button {
                    onReadingView()
                } label: {
                    Label("Reading View", systemImage: "book")
                }
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

/// Session 34: one attachment under a message bubble. Images render as a
/// small thumbnail straight off the presigned `filepath` URL; anything
/// else -- and any image whose URL has expired or failed to load -- shows
/// a named chip instead, so an attachment can never silently vanish.
/// Decorative by design: the OWNING row speaks the attachment (see
/// `MessageRow.accessibleLabel`), so everything here hides from VoiceOver
/// and the transcript stays one swipe stop per message.
private struct MessageAttachmentView: View {
    let file: KadeMessageFile

    var body: some View {
        Group {
            if file.isImage, let path = file.filepath, let url = URL(string: path) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 220, maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    case .failure:
                        chip
                    default:
                        chip
                    }
                }
            } else {
                chip
            }
        }
        .accessibilityHidden(true)
    }

    private var chip: some View {
        HStack(spacing: 6) {
            Image(systemName: file.isImage ? "photo" : "doc")
                .font(.caption)
            Text(file.filename ?? (file.isImage ? "Photo" : "File"))
                .font(.footnote)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: Capsule()
        )
        .foregroundStyle(.secondary)
    }
}


/// Bookkeeping for one in-flight streamed turn. Reference type on purpose —
/// see `ConversationDetailView.live`. Nothing here is ever read by a view
/// builder; if that ever stops being true, this needs to become observable
/// and the hot-path cost comes back with it.
private final class LiveStreamBuffers {
    /// Raw, UNSANITIZED accumulation. Sanitizing happens once per flush over
    /// the FULL accumulated text (a tag split across two chunks can't dodge a
    /// full-text pass) — see `scheduleLiveReplyFlush`.
    var replyRaw = ""
    var thinkRaw = ""
    var replyFlushScheduled = false
    var thinkFlushScheduled = false
    var lastWriteProgressAnnounce = Date.distantPast
    var lastThinkProgressAnnounce = Date.distantPast
    var announcedThinking = false

    /// Build 205 breadcrumb latches. One crumb per turn per event, never per
    /// chunk — a trail that costs a file write per streamed token would be a
    /// worse bug than the one it is trying to find.
    var crumbedFirstText = false
    var crumbedFirstThink = false
    var crumbedFlushDeferred = false

    /// Exactly the four fields the old inline reset cleared, no more: the two
    /// buffers, the write-progress timer, and the thinking-announced latch.
    /// The flush-scheduled guards are deliberately LEFT ALONE — an
    /// `asyncAfter` may already be in flight, and clearing its guard here
    /// would let a second one stack on top of it.
    func resetTurn() {
        replyRaw = ""
        thinkRaw = ""
        lastWriteProgressAnnounce = .distantPast
        announcedThinking = false
        crumbedFirstText = false
        crumbedFirstThink = false
        crumbedFlushDeferred = false
    }
}
