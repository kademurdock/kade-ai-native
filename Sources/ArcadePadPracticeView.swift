import SwiftUI
import UIKit
import AVFoundation

// MARK: - PAD PRACTICE (Oct 20 2026)
//
// A native screen, no WebView and no game: its own strip (Done, Next lesson,
// Repeat) and below it the same game pad, whose gestures go to the practice
// engine (ArcadePadPractice) instead of the page. Every attempt is said back
// as "<gesture>: <action>." by a VoiceOver announcement in her own voice and
// rate, one at a time; a touch that did nothing gets its reason, a different
// gesture a specific correction. Lesson 1 is the pad itself (the chimes),
// Lesson 2 menus, Lesson 3 the Easy fight; her taps and flicks are measured
// all the way through, and Done keeps them as Fitted to me.

@MainActor
final class ArcadePracticeController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var finished = false
    private(set) var engine: ArcadePadPractice
    private let table: ArcadeTouchTable
    private let hapticsOn: Bool
    private let chimesOn: Bool
    private let takesHoldAtOnce: Bool
    private weak var pad: ArcadeTouchPadView?
    private var speech = ArcadeSpeechQueue()
    private var speechCheck: Task<Void, Never>?
    private var speaker: AVSpeechSynthesizer?
    private var observer: NSObjectProtocol?
    private var started = false

    init(table: ArcadeTouchTable, practice: [String: Any]?, hapticsOn: Bool, chimesOn: Bool, takesHoldAtOnce: Bool) {
        let voiceOver = UIAccessibility.isVoiceOverRunning
        // Practice teaches the Easy fight controls when the game has them.
        let easy = table.fights["easy"] != nil ? table.onTier("easy") : table
        self.table = easy
        if let custom = ArcadePadPractice.makeLessons(json: practice, voiceOver: voiceOver) {
            engine = ArcadePadPractice(lessons: custom.lessons, endLine: custom.end)
        } else {
            engine = ArcadePadPractice(lessons: ArcadePadPractice.makeLessons(table: easy, voiceOver: voiceOver))
        }
        self.hapticsOn = hapticsOn
        self.chimesOn = chimesOn
        self.takesHoldAtOnce = takesHoldAtOnce
        super.init()
    }

    /// Her measurements, when there are enough to fit (else nothing is kept).
    var fitToKeep: ArcadeTouchFit? {
        engine.taps.count >= ArcadeTouchFit.minimumSamples ? engine.fit : nil
    }

    func attach(pad: ArcadeTouchPadView) {
        self.pad = pad
        pad.hapticsOn = hapticsOn
        pad.chimesOn = chimesOn
        pad.takesHoldAtOnce = takesHoldAtOnce
        pad.pauseOnLeave = false
        pad.setTable(table)
        // Her touch is measured on the relaxed numbers, the tables' own.
        pad.setFit(nil)
        pad.setMode(engine.mode)
        pad.onOutputs = { [weak self] outputs in self?.handle(outputs) }
        // No game voice here: the held state only moves Lesson 1 along.
        pad.onHold = { _ in }
        pad.onPadLog = { [weak self] on, _ in self?.padChanged(on) }
    }

    func start() {
        guard !started else { return }
        started = true
        observer = NotificationCenter.default.addObserver(forName: UIAccessibility.announcementDidFinishNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let text = note.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String
            let ok = (note.userInfo?[UIAccessibility.announcementWasSuccessfulUserInfoKey] as? Bool) ?? true
            Task { @MainActor in self?.ended(text: text, ok: ok) }
        }
        // After VoiceOver has said the new screen's first button.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self, self.started else { return }
            self.announce(self.engine.startLines(), cut: false)
        }
    }

    func stop() {
        started = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        speechCheck?.cancel()
        speechCheck = nil
        speech = ArcadeSpeechQueue()
        speaker?.stopSpeaking(at: .immediate)
        pad?.releaseAll()
    }

    func nextLesson() {
        announce(engine.nextLesson(), cut: true)
        syncMode()
    }

    func repeatStep() {
        announce(engine.repeatLines(), cut: true)
    }

    // MARK: Inside

    private func handle(_ outputs: [ArcadeTouchOutput]) {
        var lines: [String] = []
        for output in outputs { lines += engine.handle(output) }
        // A new attempt's words cut the last attempt's (her own action).
        announce(lines, cut: true)
        syncMode()
    }

    private func padChanged(_ on: Bool) {
        announce(on ? engine.padHeld() : engine.padReleased(), cut: true)
        syncMode()
    }

    private func syncMode() {
        finished = engine.finished
        if let pad, pad.mode != engine.mode { pad.setMode(engine.mode) }
    }

    private var clock: Double { ProcessInfo.processInfo.systemUptime * 1000 }

    private func announce(_ lines: [String], cut: Bool) {
        guard started else { return }
        var first = cut
        for line in lines {
            run(speech.add(ArcadeSpeechItem(id: nil, text: line, cls: "answer", interrupts: first), now: clock))
            first = false
        }
    }

    private func run(_ steps: [ArcadeSpeechStep]) {
        for step in steps {
            switch step {
            case .post(let item): post(item)
            case .ack: break
            case .stop: speaker?.stopSpeaking(at: .immediate)
            }
        }
        scheduleCheck()
    }

    private func post(_ item: ArcadeSpeechItem) {
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
                string: item.text, attributes: [.accessibilitySpeechQueueAnnouncement: NSNumber(value: !item.interrupts)]))
        } else {
            let synthesizer: AVSpeechSynthesizer
            if let speaker {
                synthesizer = speaker
            } else {
                synthesizer = AVSpeechSynthesizer()
                synthesizer.delegate = self
                speaker = synthesizer
            }
            if item.interrupts { synthesizer.stopSpeaking(at: .immediate) }
            let utterance = AVSpeechUtterance(string: item.text)
            utterance.prefersAssistiveTechnologySettings = true
            synthesizer.speak(utterance)
        }
    }

    private func ended(text: String?, ok: Bool) {
        guard started else { return }
        run(speech.finished(text: text, ok: ok, now: clock))
    }

    private func scheduleCheck() {
        speechCheck?.cancel()
        speechCheck = nil
        guard let deadline = speech.deadline else { return }
        let wait = max(0, deadline - clock) / 1000 + 0.02
        speechCheck = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.started else { return }
            self.run(self.speech.expire(now: self.clock))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor [weak self] in self?.ended(text: text, ok: true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor [weak self] in self?.ended(text: text, ok: true) }
    }
}

/// The practice pad inside SwiftUI: the same game pad, its gestures for the practice engine.
struct ArcadePracticePadSurface: UIViewRepresentable {
    let practice: ArcadePracticeController

    func makeUIView(context: Context) -> ArcadeTouchPadView {
        let pad = ArcadeTouchPadView(frame: .zero)
        practice.attach(pad: pad)
        return pad
    }

    func updateUIView(_ pad: ArcadeTouchPadView, context: Context) {}
}

struct ArcadePadPracticeView: View {
    @ObservedObject var host: ArcadeGameHost
    @StateObject private var practice: ArcadePracticeController
    @Environment(\.dismiss) private var dismiss
    @State private var stripTop: CGFloat = 0

    init(host: ArcadeGameHost) {
        _host = ObservedObject(wrappedValue: host)
        _practice = StateObject(wrappedValue: ArcadePracticeController(
            table: host.touchTableInUse, practice: host.practiceJSON, hapticsOn: host.hapticsOn,
            chimesOn: host.chimesOn, takesHoldAtOnce: host.takesHoldAtOnce))
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    stripButton("Done", symbol: "checkmark",
                                hint: practice.finished ? "Goes back to the game." : "Ends Pad practice and goes back to the game.") {
                        finish()
                    }
                    stripButton("Next lesson", symbol: "forward.end", hint: "Skips to the next lesson.") {
                        practice.nextLesson()
                    }
                    stripButton("Repeat", symbol: "arrow.counterclockwise", hint: "Says the step again.") {
                        practice.repeatStep()
                    }
                }
                .padding(.horizontal, 4)
                .background(Color(white: 0.12))
                ArcadePracticePadSurface(practice: practice)
                    .background(Color.black)
            }
            .ignoresSafeArea(.container, edges: .top)
            .onAppear { stripTop = proxy.safeAreaInsets.top }
            .onChange(of: proxy.safeAreaInsets.top) { _, top in stripTop = top }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .accessibilityAction(.escape) { finish() }
        .onAppear { practice.start() }
        .onDisappear { practice.stop() }
    }

    /// Done: her measurements kept as Fitted to me (when there are enough), then back to the game.
    private func finish() {
        if let fit = practice.fitToKeep { host.keepFit(fit) }
        practice.stop()
        dismiss()
    }

    private func stripButton(_ title: String, symbol: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .foregroundStyle(.white)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, minHeight: 64 + stripTop, alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }
}
