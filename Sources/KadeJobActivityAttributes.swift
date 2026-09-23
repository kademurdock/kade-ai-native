import ActivityKit
import Foundation

/// Sep 23 2026 redesign (C3): the shape of a lock-screen "long job" card — a
/// Sound Booth render or a Library upload. ONE file compiled into BOTH the app
/// (which starts, updates and ends the activity) and the widget extension
/// (which draws it), the same one-contract-file rule as KadeShareStore.swift.
/// Change a field here and both sides change together.
///
/// VoiceOver reads Live Activities on the Lock Screen and in the Dynamic
/// Island, so every field is written to be heard: `title` names the thing,
/// `status` says where it is in words.
struct KadeJobActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// "Writing the words", "Recording the song", "Ready to play".
        var status: String
        /// 0...1 when the job knows how far along it is; nil when it doesn't.
        var progress: Double?
        var finished: Bool
        var failed: Bool
    }

    /// "song", "scene", "upload" — picks the symbol.
    var kind: String
    /// "Your song: Porch Light", "Uploading: Side A".
    var title: String
    var startedAt: Date
}
