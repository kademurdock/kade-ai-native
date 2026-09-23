import ActivityKit
import Foundation

/// Sep 23 2026 redesign (C3): lock-screen progress for long jobs, the way food
/// delivery apps show it. The app side only — the card itself is drawn by the
/// widget extension from `KadeJobActivityAttributes`.
///
/// Fail-soft everywhere: Live Activities switched off, an older build without
/// the extension, or any ActivityKit error simply means no card. A job never
/// depends on its card. Local updates only (no push token), so a card that
/// outlives the app shows its last words plus the time elapsed, and goes stale
/// after an hour rather than claiming to still be working.
///
/// Usage:
///   let job = KadeJobActivity.start(kind: "song", title: "Your song: Porch Light", status: "Writing the words")
///   KadeJobActivity.update(job, status: "Recording the song", progress: 0.4)
///   KadeJobActivity.finish(job, status: "Ready to play")          // or failed: true
@MainActor
enum KadeJobActivity {
    private static var live: [String: Activity<KadeJobActivityAttributes>] = [:]

    /// Returns an id to pass back to `update`/`finish`, or nil when no card
    /// could be shown (that is not an error for the caller).
    @discardableResult
    static func start(kind: String, title: String, status: String, progress: Double? = nil) -> String? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        let attributes = KadeJobActivityAttributes(kind: kind, title: title, startedAt: Date())
        let state = KadeJobActivityAttributes.ContentState(status: status, progress: progress, finished: false, failed: false)
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(60 * 60)),
                pushType: nil
            )
            live[activity.id] = activity
            return activity.id
        } catch {
            return nil
        }
    }

    static func update(_ id: String?, status: String, progress: Double? = nil) {
        guard let id, let activity = live[id] else { return }
        let state = KadeJobActivityAttributes.ContentState(status: status, progress: progress, finished: false, failed: false)
        Task {
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(60 * 60)))
        }
    }

    /// A card left over from an earlier run of the app (it was closed while a
    /// job ran) can't be updated by this run, which never knew it. Ends each
    /// one at launch so the Lock Screen never shows a job as still working
    /// when nothing is watching it. The room the job lives in shows its real
    /// state.
    static func endLeftovers() {
        for activity in Activity<KadeJobActivityAttributes>.activities where live[activity.id] == nil {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Ends the card with its last words showing for a few minutes, so a
    /// person who glances at the Lock Screen later still sees "Ready to play".
    static func finish(_ id: String?, status: String, failed: Bool = false) {
        guard let id, let activity = live[id] else { return }
        live[id] = nil
        let state = KadeJobActivityAttributes.ContentState(status: status, progress: failed ? nil : 1, finished: !failed, failed: failed)
        Task {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(15 * 60))
            )
        }
    }
}
