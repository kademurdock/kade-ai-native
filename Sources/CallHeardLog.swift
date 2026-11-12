import Foundation

/* Nov 11 2026: how far a call's playback got, for the bridge ("keep only what was heard").
 *
 * When someone stops a character mid-reply, the bridge now stores only what was actually heard
 * (kade-ai-bridge heard-cut.js). It knows what it SENT; only the app knows what PLAYED. So when
 * playback is flushed (the bridge's `clear`, or the Stop button) the call sends one message:
 *
 *   { "type": "heard", "seq": <int>, "ms": <int> }
 *
 *   seq: the number of the WAV clip that was playing, counting every WAV binary frame this
 *        socket has delivered, from 1. A "LIVE" PCM frame is not a clip and is not counted; a
 *        clip dropped by an earlier flush, or one that failed to decode, still counts, because
 *        the bridge counted it when it sent it. 0 = no clip has played yet.
 *   ms:  milliseconds of that clip that had played. A clip that had finished reports its length.
 *
 * Clips numbered below seq played whole; clips after it never started. A port of the website's
 * client/src/components/Chat/heard-report.mjs, rule for rule; pure Foundation, tested in
 * TimingTrackTests/main.swift. Old bridges ignore the message.
 */
struct CallHeardLog {
    struct Report: Equatable {
        let seq: Int
        let ms: Int
    }
    private struct Clip {
        let seq: Int
        let start: Double
        let duration: Double
    }

    /// UserDefaults switch: false stops the app sending the report (the bridge then keeps its
    /// own playhead guess, as it does for builds before this one).
    static let switchKey = "kadeHeardReport"
    static func sends(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: switchKey) as? Bool ?? true
    }

    /// WAV frames received on this socket (the next clip's number is this plus one).
    private(set) var received = 0
    private var clips: [Clip] = []
    /// Where the player's queue ends, in player seconds (clips queue gaplessly behind it).
    private var end = 0.0
    /// The last report sent; repeated when a flush finds that nothing new had started.
    private(set) var last = Report(seq: 0, ms: 0)

    /// A WAV binary frame arrived; returns its clip number. Call for every WAV frame, before decoding.
    mutating func noteClipReceived() -> Int {
        received += 1
        return received
    }

    /// A buffer was queued on the player at player time `now` and lasts `duration` seconds. It
    /// starts once everything queued before it has played (bare `scheduleBuffer`). `seq` 0 is a
    /// buffer that is not a numbered clip (the LIVE lane): it takes room in the queue but is never
    /// reported.
    mutating func noteScheduled(seq: Int, duration: Double, now: Double) {
        guard duration.isFinite, duration >= 0, now.isFinite, now >= 0 else { return }
        let start = max(end, now)
        end = start + duration
        guard seq > 0 else { return }
        clips.append(Clip(seq: seq, start: start, duration: duration))
        if clips.count > 64 { clips.removeFirst(clips.count - 64) }
    }

    /// Where playback is at player time `now`. Does not change the log.
    func heard(at now: Double) -> Report {
        var best: Report?
        for clip in clips where clip.start <= now {
            let ms = Int((min(now - clip.start, clip.duration) * 1000).rounded())
            if best == nil || clip.seq > best!.seq { best = Report(seq: clip.seq, ms: max(0, ms)) }
        }
        guard let found = best, found.seq >= last.seq else { return last }
        return found
    }

    /// Playback was flushed at player time `now`: the report to send. The log starts afresh (the
    /// player's own timeline restarts at zero after stop()).
    mutating func flushReport(at now: Double) -> Report {
        let report = heard(at: now)
        clips.removeAll()
        end = 0
        last = report
        return report
    }

    /// Playback was cleared without a report (a reconnect, an engine restart): forget the queue,
    /// keep the clip count and the last report.
    mutating func dropQueue() {
        clips.removeAll()
        end = 0
    }

    /// The message for the socket.
    static func message(_ report: Report) -> [String: Any] {
        ["type": "heard", "seq": report.seq, "ms": report.ms]
    }
}
