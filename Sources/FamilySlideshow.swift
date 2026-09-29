import SwiftUI
import UIKit

// MARK: - Family history: Play slideshow (Sep 29 2026)
//
// DESIGN 1.5: one picture at a time across the screen, six seconds each,
// only after Play is pressed (it never starts by itself). A cross-fade
// between pictures, or a plain cut when motion is not allowed. The caption
// sits on a solid band at the bottom, two lines at most. Pause, Previous and
// Next stay on screen, and the screen stays awake while it plays. It stops at
// the last picture, when the app goes to the background, and when it closes.
// Screen Mirroring puts it on a TV (Help says how).
//
// VoiceOver: it moves only when she swipes. The picture is ONE adjustable
// element (the alt text, "3 of 12"); each new picture's caption is said,
// queued behind what VoiceOver is saying. Play, Pause, Previous and Next are
// for sight and Voice Control, hidden while VoiceOver runs.

struct FamilySlideshow: View {
    let items: [FHImage]
    @Binding var index: Int
    /// Back to the viewer, or closed (when it was opened straight from a list).
    let onClose: () -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @Environment(\.scenePhase) private var scenePhase
    @KadeMotionPolicy private var motionAllowed: Bool
    @State private var playing = false
    @AccessibilityFocusState private var doneFocused: Bool

    private var safeIndex: Int { min(max(0, index), max(0, items.count - 1)) }

    private var current: FHImage? {
        items.indices.contains(safeIndex) ? items[safeIndex] : nil
    }

    private func caption(_ image: FHImage?) -> String {
        FamilyAccessRules.nonEmpty(image?.caption) ?? FamilyAccessRules.nonEmpty(image?.short) ?? image?.label ?? ""
    }

    private var position: String { "\(safeIndex + 1) of \(items.count)" }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            picture
            captionBand
            controls
        }
        .task(id: playing) { await run() }
        .onChange(of: playing) { _, on in
            UIApplication.shared.isIdleTimerDisabled = on
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playing = false }
        }
        .onDisappear {
            playing = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                playing = false
                onClose()
            } label: {
                Label("Done", systemImage: "xmark")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .accessibilityHint("Stops the slideshow.")
            .accessibilityFocused($doneFocused)
            .task {
                try? await Task.sleep(nanoseconds: 550_000_000)
                if Task.isCancelled { return }
                doneFocused = true
            }
            Spacer()
            Text(position)
                .font(.subheadline)
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var picture: some View {
        GeometryReader { geo in
            ZStack {
                if let current {
                    FamilyWidePhoto(image: current, size: .s, height: geo.size.height,
                                    longSide: max(geo.size.width, geo.size.height))
                        .id("\(safeIndex)-\(current.id)")
                        .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FamilyAccessRules.nonEmpty(current?.label) ?? "A family picture")
        .accessibilityValue(position)
        .accessibilityAddTraits(.isImage)
        .accessibilityHint("Swipe up or down for another picture.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1, say: true)
            case .decrement: step(-1, say: true)
            @unknown default: break
            }
        }
        .accessibilityIgnoresInvertColors(true)
    }

    /// Two lines at most, on a solid band (never over the picture).
    private var captionBand: some View {
        Text(caption(current))
            .font(.title3)
            .foregroundStyle(.white)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color.black)
            .accessibilityHidden(true)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button { step(-1, say: false) } label: { Label("Previous", systemImage: "backward.fill") }
                .disabled(safeIndex <= 0)
            Button {
                playing.toggle()
            } label: {
                Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
                    .frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
            Button { step(1, say: false) } label: { Label("Next", systemImage: "forward.fill") }
                .disabled(safeIndex >= items.count - 1)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .padding()
        .accessibilityHidden(voiceOverOn)
    }

    // MARK: Moving

    private func step(_ by: Int, say: Bool) {
        let target: Int = min(max(0, safeIndex + by), max(0, items.count - 1))
        guard target != safeIndex else { return }
        let fade: Animation? = motionAllowed ? Animation.easeInOut(duration: 0.8) : nil
        withAnimation(fade) {
            index = target
        }
        if say {
            FamilyAnnounce.say(caption(items[target]))
        }
    }

    /// Six seconds a picture while playing; stops at the last one. VoiceOver
    /// moves only when she swipes, so it never runs then.
    @MainActor
    private func run() async {
        guard playing else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 6_000_000_000)
            } catch {
                return
            }
            if !playing || voiceOverOn { return }
            if safeIndex >= items.count - 1 {
                playing = false
                return
            }
            step(1, say: false)
        }
    }
}
