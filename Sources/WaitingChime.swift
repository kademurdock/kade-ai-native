import Foundation

/// Nov 13 2026 (her ask): while she listens to a described video that is still
/// being made and has caught up with it, nothing played, so with the phone
/// locked she could not tell a wait from a dead app. Now a soft two-note chime
/// sounds about every 20 seconds for as long as the wait lasts, and stops the
/// moment the next section starts, the job ends or fails, she pauses, or she
/// stops listening.
///
/// How it keeps time: there is no timer. The sound is ONE 20-second loop that
/// is silent except for the chime at its very end, played by one looping
/// player through the same playback audio session the sections use. So the
/// first chime comes 20 seconds after the wait begins (after VoiceOver has
/// finished the caught-up sentence), the spacing is exact, two chimes can
/// never stack, and because sound keeps flowing iOS keeps the app running
/// with the phone locked, which a timer and a short sound could not do.
///
/// This file is plain Foundation (no audio, no UIKit) so the rules and the
/// loop are tested by run-waiting-chime-tests.sh. The player itself lives in
/// DescribedListenAhead.swift.
///
/// Switches: the Sound effects setting (Feedback & Sounds), and on the phone
/// UserDefaults kade.switch.waitingChime = false.
enum WaitingChime {
    /// Seconds from one chime to the next, and from the wait beginning to the
    /// first chime.
    static let period: Double = 20
    static let sampleRate = 22_050
    /// The two notes, low then high (D5, G5), one after the other.
    static let notes: [Double] = [587.33, 783.99]
    static let noteSeconds: Double = 0.16
    /// Loudest sample, out of 1. Speech in a section peaks near 1; this sits
    /// about 22 dB under that.
    static let peak: Double = 0.08

    /// What the listen-while-made player is doing right now.
    struct State: Equatable {
        /// A job is being listened to.
        var listening = false
        /// She has reached the end of the sections made so far.
        var waiting = false
        /// The job is still running (not finished, failed or cancelled).
        var making = false
        /// She paused it.
        var paused = false
        /// The switches allow the chime.
        var enabled = true
    }

    /// The chime sounds only while every one of these holds.
    static func shouldSound(_ state: State) -> Bool {
        state.listening && state.waiting && state.making && !state.paused && state.enabled
    }

    /// The two notes on their own: about a third of a second, each note
    /// swelling in over 20 ms and fading out over 90 ms, so nothing clicks.
    static func chimeSamples() -> [Int16] {
        let perNote = Int((noteSeconds * Double(sampleRate)).rounded())
        let attack = 0.02 * Double(sampleRate)
        let release = 0.09 * Double(sampleRate)
        var samples: [Int16] = []
        samples.reserveCapacity(perNote * notes.count)
        for frequency in notes {
            for index in 0..<perNote {
                let position = Double(index)
                let left = Double(perNote - 1 - index)
                var gain = 1.0
                if position < attack { gain = min(gain, 0.5 - 0.5 * cos(Double.pi * position / attack)) }
                if left < release { gain = min(gain, 0.5 - 0.5 * cos(Double.pi * left / release)) }
                let wave = sin(2 * Double.pi * frequency * position / Double(sampleRate))
                samples.append(Int16((wave * gain * peak * 32_767).rounded()))
            }
        }
        return samples
    }

    /// The whole loop: true silence, then the chime, `period` seconds in all.
    static func loopSamples() -> [Int16] {
        let total = Int((period * Double(sampleRate)).rounded())
        let chime = chimeSamples()
        var samples = [Int16](repeating: 0, count: max(0, total - chime.count))
        samples.append(contentsOf: chime)
        return samples
    }

    /// A 16-bit mono WAV file holding `samples`.
    static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        data.reserveCapacity(44 + samples.count * 2)
        func text(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
        func le32(_ value: UInt32) {
            data.append(UInt8(value & 0xff))
            data.append(UInt8((value >> 8) & 0xff))
            data.append(UInt8((value >> 16) & 0xff))
            data.append(UInt8((value >> 24) & 0xff))
        }
        func le16(_ value: UInt16) {
            data.append(UInt8(value & 0xff))
            data.append(UInt8((value >> 8) & 0xff))
        }
        let bytes = UInt32(samples.count * 2)
        text("RIFF"); le32(36 + bytes); text("WAVE")
        text("fmt "); le32(16); le16(1); le16(1)
        le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 2)); le16(2); le16(16)
        text("data"); le32(bytes)
        for sample in samples { le16(UInt16(bitPattern: sample)) }
        return data
    }

    /// What she hears once when she catches up. With the chime it says what
    /// the chime means; without it, the sentence is the one from before.
    static func caughtUpSentence(section: Int, of count: Int, chime: Bool) -> String {
        let lead = "You have caught up. Section \(section) of \(max(count, section)) is still being made."
        if chime {
            return lead + " A soft chime about every 20 seconds means it is still waiting. The section starts by itself when it is ready. If the chime stops and nothing plays, come back to this app."
        }
        return lead + " It will start by itself while this app is open. If your phone locks, come back to this app to carry on."
    }
}

/// Remembers whether the chime loop is on, so it is started once and stopped
/// once however many times the player's state is looked at.
struct WaitingChimeKeeper {
    enum Action: Equatable { case nothing, start, stop }
    private(set) var sounding = false

    /// What to do now that the player is in `state`.
    mutating func next(_ state: WaitingChime.State) -> Action {
        let wanted = WaitingChime.shouldSound(state)
        if wanted == sounding { return .nothing }
        sounding = wanted
        return wanted ? .start : .stop
    }

    /// The loop did not start, or the system stopped it (a phone call): the
    /// next look may start it again.
    mutating func lost() { sounding = false }
}
