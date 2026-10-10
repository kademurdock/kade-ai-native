import SwiftUI
import AVFoundation

#if DEBUG && targetEnvironment(simulator)
/// Whitelisted, local-only inputs for the real CallView layout fixture.
/// These values never select an agent for a normal authenticated call.
enum CharacterCallLayoutFixture {
    enum Variant: String { case large, accessibility, still, off }
    static var person: CharacterAuditPerson {
        CharacterAuditPerson(rawValue: ProcessInfo.processInfo.environment["KADE_CALL_LAYOUT_CHARACTER"] ?? "") ?? .kiana
    }
    static var variant: Variant {
        Variant(rawValue: ProcessInfo.processInfo.environment["KADE_CALL_LAYOUT_VARIANT"] ?? "") ?? .large
    }
    static var agentID: String { person.agentID }
    static var name: String { person.name }
}
#endif

/// Real-time call screen — voice always, Spotter's camera/video layer once
/// toggled on mid-call. New in session 13 ("work on calling and spotters
/// and shit too... I'd like to be fully featured soon"). Presented full-
/// screen (not a sheet) from `ConversationDetailView`'s new toolbar Call
/// button, since a live call is an immersive state you don't want an
/// accidental swipe-down to interrupt.
struct CallView: View {
    let agentId: String?
    let agentName: String
    let spotterDirect: Bool
    /// Post-call handoff (Kade, session 14: "It doesn't drop you into your
    /// current voice conversation via text after the call. I'd like you to
    /// improve that if you can"). The presenter decides what "open it"
    /// means for where it sits in the navigation stack; this screen's only
    /// job is to resolve WHICH conversation and hand it over on the way out.
    var onOpenTranscript: ((KadeConversation) -> Void)?

    @StateObject private var callService: StreamingCallService
    @StateObject private var camera = CameraCaptureController()
    @EnvironmentObject private var conversationsService: ConversationsService
    @EnvironmentObject private var agentsService: AgentsService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var scrollBounds: CGRect?
    @State private var primaryControlBounds: CGRect?
    #if DEBUG && targetEnvironment(simulator)
    @AppStorage("kade.della.articulatedReview") private var dellaHostReview = false
    #endif

    @State private var startError: String?
    @State private var didAnnounceConnected = false
    /// True while the call is over and the transcript conversation is being
    /// resolved. Shown as a real, readable step rather than a silent pause:
    /// the server mints the transcript asynchronously after the socket
    /// closes, so there IS a genuine wait here and pretending otherwise
    /// would just look like a frozen screen.
    @State private var wrappingUp = false
    @State private var wrapUpTask: Task<Void, Never>?

    private enum A11yFocus: Hashable { case status, error }
    @AccessibilityFocusState private var a11yFocus: A11yFocus?

    /// Session 26 (call continuity): non-nil when this call was started
    /// from INSIDE a conversation -- rides the call's hello so the agent
    /// picks up with that conversation's recent turns in mind, and the
    /// post-call transcript APPENDS there instead of minting a fresh
    /// conversation. Nil (home-screen Spotter, agent picker) = the old
    /// fresh-call behavior, unchanged.
    let conversationId: String?
    /// Part 75 (Aug 21 2026): non-nil when this screen is the ANSWER to an
    /// agent-call ring -- forwarded to the call's hello (see
    /// StreamingCallService.pendingCallPlanId).
    let callPlanId: String?

    init(
        agentId: String?,
        agentName: String,
        apiClient: KadeAPIClient,
        spotterDirect: Bool = false,
        conversationId: String? = nil,
        callPlanId: String? = nil,
        onOpenTranscript: ((KadeConversation) -> Void)? = nil
    ) {
        self.agentId = agentId
        self.agentName = agentName
        self.spotterDirect = spotterDirect
        self.conversationId = conversationId
        self.callPlanId = callPlanId
        self.onOpenTranscript = onOpenTranscript
        _callService = StateObject(wrappedValue: StreamingCallService(apiClient: apiClient))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(spacing: 20) {
                            statusHeader
                            captionArea
                            if callService.liveOn || callService.videoOn {
                                cameraPreview
                                    .dellaHostProbe("camera")
                            }
                            // Session 27 (visual delight, VO-invisible): the call's
                            // state as a breathing orb -- teal listening, amber
                            // thinking (twin of the typing sound), green + ripples
                            // speaking. See KadeCallStateOrb for the motion gates.
                            if !callService.liveOn && [.listening, .thinking, .speaking].contains(callService.status) {
                                callPortrait(geometry)
                                    .dellaHostProbe("stage")
                            } else {
                                KadeCallStateOrb(status: callService.status).padding(.bottom, 8)
                            }
                            if wrappingUp {
                                wrapUpPanel
                            }
                            // Aug 9 2026 (her call): the audio-check readout only
                            // appears when something is actually wrong — see
                            // audioTrouble's doc comment in the service.
                            if callService.audioTrouble {
                                audioCheck
                            }
                            // The plain camera-describe lane belongs to the CURRENT
                            // conversation agent. Once Spotter/Live is on, the Spotter
                            // is who's actually holding the call and already owns the
                            // camera (liveOn auto-starts capture) -- so a second button
                            // reading "Let <original agent> see your camera" is both
                            // redundant AND misattributed to whoever you WERE talking to
                            // before the handoff, which is exactly the wrong-agent
                            // camera control Kade reported after a transfer. Hide it
                            // while Spotter is live; the Spotter's own camera controls
                            // (the preview + flashlight, both agent-agnostic) stay, and
                            // spotterButton is how you hand the call back.
                            VStack(spacing: 20) {
                                if !callService.liveOn {
                                    cameraButton
                                }
                                spotterButton
                                deepThinkButton
                                stopTalkingButton.id("della-host-secondary")
                            }
                            .dellaHostProbe("secondaryControls")
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                    }
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { scrollBounds = $0 }
                    // Captions, the camera and secondary actions can grow freely.
                    // Mute and Hang Up keep one identity outside the scrolling content.
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            Divider()
                            controls.padding(.horizontal).padding(.top, 12)
                        }
                        .background(Color(.systemBackground))
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { primaryControlBounds = $0 }
                        .dellaHostProbe("primaryControls")
                    }
                    .task {
                        #if DEBUG && targetEnvironment(simulator)
                        if CharacterDellaHostAudit.scenario?.scrolled == true {
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            if !Task.isCancelled { scroll.scrollTo("della-host-secondary", anchor: .bottom) }
                        }
                        #endif
                    }
                }
            }
            .navigationTitle(currentSpeakerName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !callService.liveOn {
                    ToolbarItem(placement: .primaryAction) {
                        CharacterAppearanceButton(agentID: agentId)
                    }
                }
            }
        }
        .onAppear { LibraryNowPlaying.shared.pauseForOtherAudio("a call") }
        .task {
            #if DEBUG && targetEnvironment(simulator)
            if CharacterDellaHostAudit.isEnabled {
                await prepareDellaHostAudit()
                return
            }
            if ProcessInfo.processInfo.environment["KADE_CALL_LAYOUT_AUDIT"] == "1" {
                prepareLayoutAudit()
                return
            }
            #endif
            // FIX (session 21e, Kade: "I don't think she can actually see my
            // camera... she might be hallucinating"). The camera captured
            // frames the whole time, but nothing ever wired `onFrame` to the
            // call -- every JPEG went to a nil handler, so the Spotter received
            // ZERO images and described whatever the model imagined ("package",
            // "bottle"). Wire it BEFORE beginCall so frames flow the instant
            // Spotter/Live turns the camera on. sendFrame ships one JSON frame
            // the bridge forwards to the live vision model (verified against
            // voice-stream.js `type:'frame'` -> forwardFrame).
            camera.onFrame = { jpeg in
                callService.sendFrame(jpegData: jpeg)
            }
            await beginCall()
        }
        .onDisappear {
            wrapUpTask?.cancel()
            callService.stop()
            camera.stop()
        }
        .onChange(of: callService.liveOn) { _, on in
            #if DEBUG && targetEnvironment(simulator)
            if CharacterDellaHostAudit.isEnabled { return }
            #endif
            // Aug 4 2026: Spotter/Live runs the faster frame cadence
            // (~1.4/s); handing back drops to the plain lane's 2s pace.
            camera.setLiveCadence(on)
            if on {
                Task { await camera.start(facing: .back) }
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "\(callService.spotterName ?? "Your Spotter") is on the line."
                )
            } else if !callService.videoOn {
                // Only stop the capture session if the OTHER camera lane
                // isn't still using it -- handing Spotter back to the
                // character while plain camera-describe stays on must not
                // kill the camera out from under it.
                camera.stop()
            }
        }
        .onChange(of: callService.videoOn) { _, on in
            #if DEBUG && targetEnvironment(simulator)
            if CharacterDellaHostAudit.isEnabled { return }
            #endif
            if on {
                Task { await camera.start(facing: .back) }
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "\(agentName) can see your camera now."
                )
            } else {
                if !callService.liveOn { camera.stop() }
                UIAccessibility.post(notification: .announcement, argument: "Camera off.")
            }
        }
        .onChange(of: callService.status) { _, new in
            if !didAnnounceConnected, new == .listening {
                didAnnounceConnected = true
                UIAccessibility.post(notification: .announcement, argument: "Call connected, listening.")
            }
            if case .ended = new {
                UIAccessibility.post(notification: .announcement, argument: "Call ended.")
            }
        }
        .onChange(of: callService.errorMessage) { _, message in
            if let message {
                a11yFocus = .error
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
        .sensoryFeedback(trigger: callService.liveOn) { _, _ in
            FeedbackPrefs.gate(.impact(weight: .light))
        }
        // Kade, session 17/18: "We need to add more cool stuff like
        // haptics." A physical confirmation at the two moments this screen
        // already announces to VoiceOver by voice alone -- "Call connected,
        // listening." and "Call ended." -- same reasoning as the existing
        // Spotter on/off haptic just above: a non-audio channel for a
        // call-state transition that matters. Deliberately triggered off
        // `didAnnounceConnected`, NOT the raw `callService.status` value,
        // for "connected": `status` legitimately cycles back to `.listening`
        // on every ordinary turn all call long (whenever it's her turn to
        // talk again), which is exactly why the EXISTING voice announcement
        // just above already needed a one-shot latch (`didAnnounceConnected`)
        // instead of reacting to `.listening` directly -- binding the haptic
        // to that same latch keeps it a true one-shot "call connected" cue
        // instead of a buzz on every single turn. `.ended` has no such
        // recurrence risk (a terminal state for this view's one call), so it
        // stays a direct status trigger.
        .sensoryFeedback(trigger: didAnnounceConnected) { old, new in
            FeedbackPrefs.gate((!old && new) ? .success : nil)
        }
        .sensoryFeedback(trigger: callService.status) { _, new in
            if case .ended = new { return FeedbackPrefs.gate(.impact(weight: .light)) }
            return nil
        }
        .alert(
            "Spotter",
            isPresented: Binding(
                get: { callService.liveNotice != nil },
                set: { if !$0 { callService.clearLiveNotice() } }
            ),
            presenting: callService.liveNotice
        ) { _ in
            Button("Not now", role: .cancel) { callService.clearLiveNotice() }
            Button("Put them on") {
                callService.clearLiveNotice()
                callService.setLive(on: true, ack: true)
            }
        } message: { text in
            Text(text)
        }
        .alert(
            "Camera",
            isPresented: Binding(
                get: { callService.videoNotice != nil },
                set: { if !$0 { callService.clearVideoNotice() } }
            ),
            presenting: callService.videoNotice
        ) { _ in
            Button("Not now", role: .cancel) { callService.clearVideoNotice() }
            Button("Turn the camera on") {
                callService.clearVideoNotice()
                callService.setVideo(on: true, ack: true)
            }
        } message: { text in
            Text(text)
        }
        .alert(
            "Couldn't start the call",
            isPresented: Binding(get: { startError != nil }, set: { if !$0 { startError = nil } }),
            presenting: startError
        ) { _ in
            Button("Close") { dismiss() }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Pieces

    /// Resolve the host and portrait from the same stable window inputs. The
    /// observed scroll region excludes the pinned call controls, so decoration
    /// stops when long captions or a scroll move the body out of view.
    private func callPortrait(_ geometry: GeometryProxy) -> some View {
        let preferredSide = CharacterStageLayout.callSide(
            width: Double(geometry.size.width), height: Double(geometry.size.height),
            accessibilityText: dynamicTypeSize.isAccessibilitySize)
        let avatarPath = agentsService.agents.first { $0.id == agentId }?.avatar?.filepath
        #if DEBUG && targetEnvironment(simulator)
        let candidateEligible = CharacterDellaHostReview.available(enabled: dellaHostReview,
            agentID: agentId, avatarPath: avatarPath)
        #else
        let candidateEligible = false
        #endif
        let layout = CharacterDellaHostLayout.call(preferredSide: preferredSide,
            availableHeight: Double(geometry.size.height),
            camera: callService.videoOn || callService.liveOn,
            accessibilityText: dynamicTypeSize.isAccessibilitySize,
            candidateEligible: candidateEligible)
        let viewport = portraitViewport(in: geometry.frame(in: .global))
        var portrait = CharacterPortraitView(agentID: agentId, name: agentName,
            playing: callService.status == .speaking,
            level: { callService.characterLevel }, listening: true,
            presentation: { callService.characterPresentation },
            stage: true, side: layout.side, viewport: viewport)
        #if DEBUG && targetEnvironment(simulator)
        portrait.dellaArticulatedReview = layout.articulated
        if CharacterDellaHostAudit.isEnabled {
            CharacterDellaHostAuditRecorder.stage = layout
            CharacterDellaHostAuditRecorder.record("viewport", frame: viewport)
        }
        #endif
        return portrait
    }

    private func portraitViewport(in hostBounds: CGRect) -> CGRect {
        let visible = (scrollBounds ?? hostBounds).intersection(hostBounds)
        guard !visible.isNull else { return .zero }
        let bottom = min(visible.maxY, primaryControlBounds?.minY ?? visible.maxY)
        return CGRect(x: visible.minX, y: visible.minY, width: visible.width,
            height: max(0, bottom - visible.minY))
    }

    private var statusHeader: some View {
        VStack(spacing: 6) {
            Text(currentSpeakerName)
                .font(.title2.bold())
            // Session 20 visual flair: a live pulse once the call is
            // connected. Decorative only -- the whole header is
            // accessibilityElement(children: .ignore), so VoiceOver reads just
            // the label below and never sees this; it also goes static under
            // Reduce Motion (KadePulseDot).
            HStack(spacing: 7) {
                KadePulseDot(color: .green, diameter: 8, active: didAnnounceConnected)
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(currentSpeakerName). \(statusText)")
        .accessibilityFocused($a11yFocus, equals: .status)
    }

    /// Once Spotter/Live is on, the Spotter is who's actually talking, not
    /// the character the call started with (`video-live.js`'s whole handoff
    /// design: "the live session BECOMES the voice for that call segment").
    /// Everything the caller sees/hears on screen should say so, or a blind
    /// caller has no way to know the character handed off.
    private var currentSpeakerName: String {
        callService.liveOn ? (callService.spotterName ?? "Your Spotter") : agentName
    }

    private var statusText: String {
        switch callService.status {
        case .idle: return "Starting…"
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking"
        case .ended(let graceful): return graceful ? "Call ended" : "Call disconnected"
        case .failed: return "Call failed"
        case .reconnecting: return "Reconnecting…"
        }
    }

    private var captionArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !callService.userCaption.isEmpty {
                captionLine(label: "You said", text: callService.userCaption)
            }
            if !callService.agentCaption.isEmpty {
                captionLine(label: "\(currentSpeakerName) said", text: callService.agentCaption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func captionLine(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(text)")
    }

    /// Camera preview while Spotter/Live is on — a secondary, sighted-
    /// helper convenience. Hidden from VoiceOver entirely: the actual
    /// "description" of what the camera sees is the Spotter's own spoken
    /// commentary, not anything a raw video layer could usefully narrate.
    private var cameraPreview: some View {
        VStack(spacing: 8) {
            CameraPreviewLayer(session: camera.session)
                // Aug 4 2026 (Spotter polish): the preview grows while the
                // Spotter is actually the one looking -- sighted family
                // helping aim the phone get a real viewfinder, not a strip.
                .frame(height: callService.liveOn ? 300 : 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topTrailing) {
                    if camera.torchAvailable {
                        Button {
                            camera.setTorch(!camera.torchOn)
                        } label: {
                            Image(systemName: camera.torchOn ? "bolt.fill" : "bolt.slash")
                                .padding(8)
                                .background(.black.opacity(0.4), in: Circle())
                                .foregroundStyle(.white)
                        }
                        .padding(8)
                        .accessibilityLabel(camera.torchOn ? "Turn off flashlight" : "Turn on flashlight")
                    }
                }
                .accessibilityHidden(true)
            // Aug 4 2026 -- REAL accessibility catch from this session's
            // audit: the only torch control lived INSIDE the preview
            // overlay above, and the whole preview is (correctly)
            // accessibilityHidden -- so a VoiceOver user in a dark room,
            // the exact person the auto-flash exists for, had NO manual
            // flashlight control at all if the automation guessed wrong.
            // This full-width button is the torch's accessible home; the
            // overlay chip stays for sighted muscle memory. Toggling here
            // counts as a manual set, so auto-flash stops overriding it
            // (same respect-the-human rule as the chip).
            if camera.torchAvailable {
                Button {
                    camera.setTorch(!camera.torchOn)
                    KadeHaptics.tap()
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: camera.torchOn ? "Flashlight on." : "Flashlight off."
                    )
                } label: {
                    Label(
                        camera.torchOn ? "Flashlight On" : "Flashlight Off",
                        systemImage: camera.torchOn ? "bolt.fill" : "bolt.slash"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(camera.torchOn ? .yellow : nil)
                .accessibilityLabel("Flashlight")
                .accessibilityValue(camera.torchOn ? "On" : "Off")
                .accessibilityHint("Lights up what the camera sees. It also comes on by itself in the dark until you set it yourself.")
            }
        }
    }

    /// Read-out-loud audio diagnostic. Added after build 119: the call
    /// connected and captions rendered, but no sound came out, and there was
    /// no way for the caller to tell anyone WHICH part had failed. Paired
    /// with the short two-note tone the service now plays the moment the
    /// audio engine starts, this turns "no sound" into an answerable
    /// question: heard the tone but not the agent means clips aren't
    /// arriving or aren't decoding (and the numbers here say which); heard
    /// nothing at all means route, session, or volume.
    private var audioCheck: some View {
        Text(callService.audioDiagnostic)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Audio check. \(callService.audioDiagnostic)")
            .accessibilityHint("Read this out if the call has no sound.")
    }

    /// Plain camera-describe lane. Deliberately worded to make the
    /// difference from Spotter unmistakable by ear alone: this one keeps
    /// the SAME voice you're already talking to and just gives her sight,
    /// where Spotter hands the call to a different companion entirely.
    private var cameraButton: some View {
        Button {
            if callService.videoOn {
                callService.setVideo(on: false)
            } else {
                callService.setVideo(on: true, ack: false)
            }
        } label: {
            Label(
                callService.videoOn ? "\(agentName) can see your camera" : "Let \(agentName) see your camera",
                systemImage: "camera"
            )
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        // Session 26, the Amber rule: no children:.ignore on a Button
        // (see AgentPickerView's row). Label/value/hint stay.
        .accessibilityLabel("Camera")
        .accessibilityValue(callService.videoOn ? "On" : "Off")
        .dellaHostProbe("cameraButton", identifier: "della-host.call.camera")
        .accessibilityHint(
            callService.videoOn
                ? "Double-tap to stop sharing your camera. \(agentName) keeps talking either way."
                : "Double-tap to let \(agentName) describe what your camera sees, in her own voice."
        )
    }

    private var spotterButton: some View {
        Button {
            if callService.liveOn {
                callService.setLive(on: false)
            } else {
                callService.setLive(on: true, ack: false)
            }
        } label: {
            Label(callService.liveOn ? "Spotter is on the line" : "Bring in your Spotter", systemImage: "eye")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        // Session 26, the Amber rule — same as the camera button above.
        .accessibilityLabel("Spotter")
        .accessibilityValue(callService.liveOn ? "On" : "Off")
        .dellaHostProbe("spotterButton", identifier: "della-host.call.spotter")
        .accessibilityHint(
            callService.liveOn
                ? "Double-tap to hand the call back to \(agentName)."
                : "Double-tap to bring in your Spotter."
        )
    }

    /// DEEP THINK, on the call screen (Aug 31 2026, Part 110). Her ask, in the
    /// same breath as the barge-in one: "I'd like to have a deep think button
    /// or something in case you don't want an instant answer in the middle of a
    /// conversation."
    ///
    /// That sentence is the whole spec, and it explains why this arms the NEXT
    /// answer rather than latching: the case she named is a single hard
    /// question inside an otherwise ordinary conversation. A mode would make
    /// every answer after it slow, and leaving it on by accident is the failure
    /// nobody notices until the call feels sluggish.
    ///
    /// ⚠️ THE STATE SHOWN HERE IS THE SERVER'S, NOT THIS VIEW'S. `deepThinkArmed`
    /// is only ever set from the bridge's reply, so a tap that never landed
    /// leaves the button reading "Off" instead of confidently lying. On a screen
    /// somebody is driving entirely by ear, a control whose VALUE is a guess is
    /// worse than no control: she would ask the hard question, hear "on", and
    /// silently get the quick answer anyway.
    private var deepThinkButton: some View {
        Button {
            let want = !callService.deepThinkArmed
            callService.setDeepThink(want)
            KadeHaptics.tap()
            // Announce the INTENT, present tense. The value below is what
            // reports the settled truth once the server answers.
            UIAccessibility.post(
                notification: .announcement,
                argument: want
                    ? "Deep think on for your next question."
                    : "Deep think off."
            )
        } label: {
            Label(
                callService.deepThinkArmed ? "Deep Think is on for your next question" : "Deep Think",
                // One symbol for both states, deliberately. A wrong SF Symbol
                // name renders as NOTHING rather than failing to compile, and
                // the filled variant of this glyph has moved names across SF
                // Symbols releases — a silent blank icon on the state that
                // matters most is not a trade worth making. The tint, the
                // label and the accessibility value all carry the state.
                systemImage: "brain.head.profile"
            )
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(callService.deepThinkArmed ? .accentColor : nil)
        .disabled(callService.status == .reconnecting)
        // Session 26, the Amber rule: label names the control, value carries
        // the state, hint says what a double-tap does. Never all three in one
        // string -- VoiceOver reads them in that order and a label that already
        // contains the state stutters.
        .accessibilityLabel("Deep think")
        .accessibilityValue(callService.deepThinkArmed ? "On for your next question" : "Off")
        .dellaHostProbe("deepThinkButton", identifier: "della-host.call.deep-think")
        .accessibilityHint(
            callService.deepThinkArmed
                ? "Double-tap to go back to quick answers."
                : "Double-tap so \(currentSpeakerName) takes her time on your next question. It turns itself off after that one answer."
        )
    }

    /// Aug 17 2026, her call: OFF the main strip, not gone. She asked why it
    /// still exists at all -- "barge should handle that correctly, and of
    /// course you can mute yourself" -- and the honest answer is that auto
    /// barge-in is server-side and only fires when she SPEAKS, which means it
    /// cannot fire at all while the mic is MUTED (mute sends silence by
    /// design). So this button is the only way to stop a rambling agent while
    /// muted, or to stop one without having to make noise. It keeps its full
    /// label and hint for VoiceOver; it just no longer eats a third of the
    /// primary row, which is now the two controls she actually reaches for.
    ///
    /// ⭐ PART 110 UPDATE, and it makes her Aug-17 question finally have the
    /// answer she expected: "barge should handle that correctly" was TRUE of
    /// the phone line and false of this screen. App calls had been running
    /// bargeMode 'push' since July 24 2026, so on this surface the auto
    /// barge-in she was reasoning about did not exist and this button was doing
    /// all the work. The hello now asks for 'auto'. The button stays for
    /// exactly the reason written above — a muted mic makes no sound to barge
    /// with — and that reason is now the ONLY one.
    private var stopTalkingButton: some View {
        Button {
            callService.barge()
        } label: {
            Label("Stop Talking", systemImage: "hand.raised.fill")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(callService.status == .reconnecting)
        .accessibilityLabel("Stop talking")
        .dellaHostProbe("stopTalkingButton", identifier: "della-host.call.stop-talking")
        .accessibilityHint("Interrupts what \(currentSpeakerName) is saying. Works even while your microphone is muted.")
    }

    private var controls: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            // Session 26, her spec exactly: "a mute button to mute your
            // mic" -- with auto barge-in, a hot mic means any cough or TV
            // line interrupts the agent mid-sentence; mute sends silence
            // instead (see StreamingCallService.micMuted). Same
            // label/value/hint construction as Camera and Spotter above.
            Button {
                callService.setMicMuted(!callService.micMuted)
                if callService.micMuted {
                    KadeHaptics.warning()
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: "Microphone muted. \(currentSpeakerName) can't hear you."
                    )
                } else {
                    KadeHaptics.tap()
                    UIAccessibility.post(notification: .announcement, argument: "Microphone back on.")
                }
            } label: {
                Label(callService.micMuted ? "Unmute" : "Mute", systemImage: callService.micMuted ? "mic.slash.fill" : "mic.slash")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(callService.micMuted ? .red : nil)
            // Session 26, the Amber rule — same as the camera/Spotter buttons.
            .accessibilityLabel("Mute microphone")
            .accessibilityValue(callService.micMuted ? "Muted" : "On")
            .dellaHostProbe("muteButton", identifier: "della-host.call.mute")
            .accessibilityHint(
                callService.micMuted
                    ? "Double-tap so \(currentSpeakerName) can hear you again."
                    : "Double-tap to send silence instead of your microphone. Stops accidental interruptions too."
            )

            Button(role: .destructive) {
                hangUp()
            } label: {
                Label("Hang Up", systemImage: "phone.down.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .dellaHostProbe("hangUpButton", identifier: "della-host.call.hang-up")
        }
        .padding(.bottom, 8)
    }

    #if DEBUG && targetEnvironment(simulator)
    private func prepareDellaHostAudit() async {
        guard let scenario = CharacterDellaHostAudit.scenario, !scenario.chat else { return }
        CharacterDellaHostAudit.configure(scenario)
        agentsService.seedCharacterAudit()
        callService.auditControl("{\"type\":\"state\",\"state\":\"listening\"}")
        let paragraph = "The lake is quiet this afternoon. We can sit on the porch, listen to the birds, and take our time deciding what to do next."
        let reply = scenario.longCaptions
            ? Array(repeating: paragraph, count: 12).joined(separator: " ")
            : "We can sit by the lake and listen to the birds."
        for (role, text) in [
            ("user", "Tell me about the lake."),
            ("assistant", reply)
        ] {
            if let data = try? JSONSerialization.data(withJSONObject: ["type": "caption", "role": role, "text": text]),
               let json = String(data: data, encoding: .utf8) { callService.auditControl(json) }
        }
        // Exercise the real camera layout without beginning capture or wiring
        // frame delivery. The host-audit guards above suppress the on-change
        // camera start; the fixture does not call beginCall or auditStart.
        if scenario.camera { callService.auditControl("{\"type\":\"video-state\",\"on\":true}") }
        await CharacterDellaHostAuditRecorder.ready()
    }

    /// Photograph the production screen with invented text. No call is started.
    private func prepareLayoutAudit() {
        agentsService.seedCharacterAudit()
        let person = CharacterCallLayoutFixture.person
        let variant = CharacterCallLayoutFixture.variant
        UserDefaults.standard.set(variant != .off, forKey: "kadeVoicePortraits")
        UserDefaults.standard.set(variant == .still, forKey: "kade.feedback.reduceMotion")
        callService.auditControl("{\"type\":\"state\",\"state\":\"listening\"}")
        let captions = [
            ("user", "Tell me about a quiet afternoon by the lake."),
            ("assistant", "The water is still, and the porch swing creaks in the shade. We can sit for a while, listen to the birds, and decide what to do next. There is no hurry.")
        ]
        for (role, text) in captions {
            if let data = try? JSONSerialization.data(withJSONObject: ["type": "caption", "role": role, "text": text]),
               let json = String(data: data, encoding: .utf8) { callService.auditControl(json) }
        }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let registered = CharacterPuppetRegistration.approved(stage: true, side: 208,
            agentID: agentId, avatarPath: "/images/" + person.avatarFile)
        let receipt: [String: Any] = [
            "character": person.rawValue, "agentID": agentId ?? "",
            "expectedAgentID": person.agentID, "avatarFile": person.avatarFile,
            "variant": variant.rawValue, "portraitEnabled": variant != .off,
            "appReduceMotion": variant == .still, "productionPuppetRegistered": registered,
            "syntheticCaptions": true, "audioStarted": false, "microphoneStarted": false
        ]
        if let data = try? JSONSerialization.data(withJSONObject: receipt) {
            try? data.write(to: folder.appendingPathComponent("call-layout-ready.txt"), options: .atomic)
        }
    }
    #endif

    // MARK: - Actions

    private func beginCall() async {
        do {
            try await callService.start(
                agentId: agentId, displayName: agentName, spotterDirect: spotterDirect,
                conversationId: conversationId, callPlanId: callPlanId
            )
        } catch {
            startError = (error as? LocalizedError)?.errorDescription ?? "Something went wrong starting the call."
        }
    }

    /// Hang up, then WAIT for the transcript before leaving, so she lands in
    /// the text version of the call she just had instead of back where she
    /// started with nothing to show for it.
    ///
    /// Sequenced deliberately: `stop()` sends `bye` and closes the socket,
    /// and the bridge only posts the transcript to the fork on socket CLOSE
    /// -- so there is nothing to look for until after this point. If nothing
    /// turns up within the polling window (an empty call logs no transcript
    /// at all, by design, and the mint is allowed to fail), it dismisses
    /// exactly as it always did. The handoff is a bonus, never a gate.
    private func hangUp() {
        callService.stop()
        camera.stop()
        guard onOpenTranscript != nil else {
            dismiss()
            return
        }
        wrappingUp = true
        a11yFocus = .status
        UIAccessibility.post(
            notification: .announcement,
            argument: "Call ended. Getting the written version of your call."
        )
        let startedAt = callService.startedAt
        wrapUpTask = Task {
            let convo = await conversationsService.awaitCallConversation(startedAfter: startedAt)
            guard !Task.isCancelled else { return }
            wrappingUp = false
            if let convo {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "Opening your call as a conversation."
                )
                onOpenTranscript?(convo)
            }
            dismiss()
        }
    }

    /// Skippable on purpose. The wait is short but it is a wait, and making
    /// someone sit through a server-side step they did not ask for is
    /// exactly the kind of thing that turns a nice touch into an annoyance.
    private var wrapUpPanel: some View {
        HStack(spacing: 10) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("Writing up your call")
                    .font(.subheadline.bold())
                Text("It'll open as a conversation you can read and carry on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Skip") {
                wrapUpTask?.cancel()
                wrappingUp = false
                dismiss()
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Closes the call screen without waiting for the written version.")
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

/// Thin `UIViewRepresentable` around `AVCaptureVideoPreviewLayer` — SwiftUI
/// has no native camera-preview view, so this is the standard bridge.
private struct CameraPreviewLayer: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
