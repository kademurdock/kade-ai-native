import SwiftUI
import AVFoundation

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

    @StateObject private var callService: StreamingCallService
    @StateObject private var camera = CameraCaptureController()
    @Environment(\.dismiss) private var dismiss

    @State private var startError: String?
    @State private var didAnnounceConnected = false

    private enum A11yFocus: Hashable { case status, error }
    @AccessibilityFocusState private var a11yFocus: A11yFocus?

    init(agentId: String?, agentName: String, apiClient: KadeAPIClient, spotterDirect: Bool = false) {
        self.agentId = agentId
        self.agentName = agentName
        self.spotterDirect = spotterDirect
        _callService = StateObject(wrappedValue: StreamingCallService(apiClient: apiClient))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                statusHeader
                captionArea
                if callService.liveOn {
                    cameraPreview
                }
                Spacer(minLength: 0)
                spotterButton
                controls
            }
            .padding()
            .navigationTitle(agentName)
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await beginCall() }
        .onDisappear {
            callService.stop()
            camera.stop()
        }
        .onChange(of: callService.liveOn) { _, on in
            if on {
                Task { await camera.start() }
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "\(callService.spotterName ?? "Your Spotter") is on the line."
                )
            } else {
                camera.stop()
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
        .sensoryFeedback(.impact(weight: .light), trigger: callService.liveOn)
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

    private var statusHeader: some View {
        VStack(spacing: 6) {
            Text(currentSpeakerName)
                .font(.title2.bold())
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
        CameraPreviewLayer(session: camera.session)
            .frame(height: 220)
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
        }
        .buttonStyle(.bordered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spotter")
        .accessibilityValue(callService.liveOn ? "On" : "Off")
        .accessibilityHint(
            callService.liveOn
                ? "Double-tap to hand the call back to \(agentName)."
                : "Double-tap to bring in your live visual companion."
        )
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                callService.barge()
            } label: {
                Label("Stop Talking", systemImage: "hand.raised.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Interrupts what \(currentSpeakerName) is saying so you can talk.")

            Button(role: .destructive) {
                hangUp()
            } label: {
                Label("Hang Up", systemImage: "phone.down.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    private func beginCall() async {
        do {
            try await callService.start(agentId: agentId, spotterDirect: spotterDirect)
        } catch {
            startError = (error as? LocalizedError)?.errorDescription ?? "Something went wrong starting the call."
        }
    }

    private func hangUp() {
        callService.stop()
        camera.stop()
        dismiss()
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
