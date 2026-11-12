import UIKit

/// IOS-16 Part A (Nov 12 2026 audit; Part B was NOT taken, her choice: the
/// silent switch keeps silencing the thinking bubbles).
///
/// A locked phone must not freeze a turn before its first spoken word: until a
/// clip plays (and background audio keeps the app alive), the stream read and
/// the first speech fetch need the grace iOS gives a declared background task.
/// That grace is short (about 30 s), so it bridges the gap; it does not carry
/// a long deep-think on its own.
@MainActor
final class KadeBackgroundTurn {
    private var id: UIBackgroundTaskIdentifier = .invalid

    static func begin() -> KadeBackgroundTurn {
        let turn = KadeBackgroundTurn()
        turn.id = UIApplication.shared.beginBackgroundTask(withName: "kade.chat.turn") { [weak turn] in
            MainActor.assumeIsolated {
                KadeBreadcrumbs.drop("chat turn: background time expired")
                turn?.end()
            }
        }
        if turn.id == .invalid {
            KadeBreadcrumbs.drop("chat turn: no background time granted")
        }
        return turn
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }

    /// performSend returns at "reply landed", which can be BEFORE the first
    /// clip has been fetched. Hold the task until a clip is really sounding
    /// (background audio then owns the app's life) or the queue is idle on two
    /// looks in a row, capped at 25 s. The expiry handler still ends it sooner.
    func endWhenSpeechSettles(_ voice: VoiceService, hearReplies: Bool) {
        guard id != .invalid else { return }
        guard hearReplies else { end(); return }
        Task { @MainActor in
            var idleLooks = 0
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if self.id == .invalid { return }
                if voice.isClipPlaying { break }
                idleLooks = voice.isSpeaking ? 0 : idleLooks + 1
                if idleLooks >= 2 { break }
            }
            self.end()
        }
    }
}
