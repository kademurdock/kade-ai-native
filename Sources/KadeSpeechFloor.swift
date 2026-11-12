import Foundation
import UIKit

/// IOS-14 (Nov 12 2026 audit). The app's own voice and VoiceOver share one
/// pair of ears. Lines that are not answers to something she just did
/// ("Memory saved.", a tool line, "Still thinking") wait for the character to
/// finish. Progress lines that would be stale by then are dropped; a tool line
/// is held (latest only) and retracted by the chat when the tool is over. All
/// go out at low priority, as one announcement.
///
/// The floor knows only `VoiceService` (each instance reports itself): live
/// calls, Library narration and described video are not sources.
@MainActor
final class KadeSpeechFloor {
    static let shared = KadeSpeechFloor()
    enum Kind: Hashable { case memory, tool, thinking, notice }

    private var speakingSources = Set<ObjectIdentifier>()
    private var held: [Kind: String] = [:]
    private var heldOrder: [Kind] = []
    private var flushTask: Task<Void, Never>?

    var appVoiceBusy: Bool { !speakingSources.isEmpty }

    func appVoice(busy: Bool, source: ObjectIdentifier) {
        if busy {
            speakingSources.insert(source)
            flushTask?.cancel(); flushTask = nil
            return
        }
        speakingSources.remove(source)
        guard speakingSources.isEmpty, !held.isEmpty else { return }
        scheduleFlush()
    }

    /// Returns false only when the line was dropped. `staleAfterVoice`: the
    /// line means nothing once the reply is being heard (thinking progress).
    @discardableResult
    func announce(_ text: String, kind: Kind, staleAfterVoice: Bool = false) -> Bool {
        guard UIAccessibility.isVoiceOverRunning, !text.isEmpty else { return false }
        // The settle window after the voice stops counts as busy for held
        // lines, so nothing jumps ahead of an older held line.
        if appVoiceBusy {
            if staleAfterVoice { return false }
        } else if flushTask == nil || staleAfterVoice {
            post(text)
            return true
        }
        if held[kind] == nil { heldOrder.append(kind) }
        held[kind] = text
        return true
    }

    /// A held line that is no longer true (the tool finished, the turn ended).
    func retract(_ kind: Kind) {
        guard held.removeValue(forKey: kind) != nil else { return }
        heldOrder.removeAll { $0 == kind }
        if held.isEmpty { flushTask?.cancel(); flushTask = nil }
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)   // a gap between two pieces is not the end
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            guard self.speakingSources.isEmpty else { return }
            self.flush()
        }
    }

    private func flush() {
        let lines = heldOrder.compactMap { held[$0] }
        held.removeAll()
        heldOrder.removeAll()
        guard !lines.isEmpty else { return }
        // One announcement: queued low-priority lines can displace each other.
        post(lines.joined(separator: " "))
    }

    private func post(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
            string: text, attributes: [.accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.low]))
    }
}
