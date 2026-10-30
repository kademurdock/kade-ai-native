import Foundation

/// One voice speed for every voice (Oct 16 2026, Kade: separate Fish and
/// Classic speed lists side by side were confusing). The chosen pace's value
/// rides the next synthesis request as `speed`; the proxy turns it into each
/// provider's own control. Audio players always use 1.0, including after a
/// preference changes mid-clip.
///
/// Oct 30 2026, Kade: "The brisk and all that, that wasn't original, that was
/// just because we couldn't get fish api to sound right. Inworld originally
/// just had a speed, 1x 1.2x whatever, up and down." So the list shows the
/// number the proxy now delivers. The value keys are what phones have saved
/// (`kade.voiceMessage.pace`): the old five stay, and the new stops get word
/// keys too, never numeric strings, because an unknown saved string means
/// the character's speed.
enum VoicePacePolicy {
    static let options: [(value: String, label: String, rate: Double?)] = [
        ("character", "Character's speed", nil), ("unhurried", "0.75x", 0.75),
        ("relaxed", "0.8x", 0.8), ("easygoing", "0.9x", 0.9), ("natural", "1x", 1),
        ("upbeat", "1.1x", 1.1), ("brisk", "1.2x", 1.2), ("swift", "1.3x", 1.3),
        ("rapid", "1.4x", 1.4), ("quick", "1.5x", 1.5),
    ]
    static func rate(base: Double?, preference: Double?) -> Double {
        let value = preference ?? base ?? 1
        return value.isFinite ? min(1.5, max(0.5, value)) : 1
    }
    /// The `speed` sent for a saved pace; "character" keeps the character's own rate.
    static func paceRate(_ pace: String, base: Double?) -> Double {
        rate(base: base, preference: options.first { $0.value == pace }?.rate)
    }
    /// The nearest named pace for an old numeric speed; normal or none keeps
    /// the character's own speed.
    static func legacyPace(_ rate: Double?) -> String {
        guard let rate, rate.isFinite, abs(rate - 1) > 0.001 else { return "character" }
        return options.filter { $0.rate != nil }.min {
            abs(($0.rate ?? 1) - rate) < abs(($1.rate ?? 1) - rate)
        }?.value ?? "character"
    }
    /// One pace from the two older preferences: a chosen Fish pace wins,
    /// otherwise a non-normal Classic rate becomes its nearest pace.
    static func unifiedPace(fishPace: String?, classicRate: Double?) -> String {
        if let fishPace, fishPace != "character", options.contains(where: { $0.value == fishPace }) {
            return fishPace
        }
        return legacyPace(classicRate)
    }
    static func name(_ pace: String) -> String {
        options.first { $0.value == pace }?.label ?? "Character's speed"
    }
    /// Short on-screen form: the number, or "Auto" for the character's speed.
    static func chipLabel(_ pace: String) -> String {
        pace != "character" && options.contains(where: { $0.value == pace }) ? name(pace) : "Auto"
    }
    /// What VoiceOver says for a choice in the list: "1.2 times", not "1.2x".
    static func spokenName(_ pace: String) -> String {
        guard let rate = options.first(where: { $0.value == pace })?.rate else { return name(pace) }
        return speedWords(rate)
    }
    /// The list's numbers, without "Character's speed" (the builder's Speed row).
    static var rates: [Double] { options.compactMap { $0.rate } }
    /// "1.2x". A saved number off the list shows as itself ("1.15x").
    static func speedShort(_ rate: Double) -> String { numberText(rate) + "x" }
    /// "Normal", "1.2 times": the same words Family stories speak
    /// (FamilyStoryParts.speedWords).
    static func speedWords(_ rate: Double) -> String {
        abs(rate - 1) < 0.001 ? "Normal" : numberText(rate) + " times"
    }
    private static func numberText(_ value: Double) -> String {
        guard value.isFinite else { return "1" }
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
    /// A list that also offers a saved number it does not contain, in order,
    /// so a saved 1.25 keeps working and shows as itself instead of leaving a
    /// picker blank.
    static func choices(_ list: [Double], keeping saved: Double?) -> [Double] {
        guard let saved, saved.isFinite, !list.contains(where: { abs($0 - saved) < 0.001 }) else { return list }
        return (list + [saved]).sorted()
    }
    /// A character's default speed belongs to the character's own builder
    /// voice (Oct 30 2026, Kade: "a default voice speed for the default agent
    /// voice we choose when we build an agent ... so people can hear it how
    /// you intended"). A voice the listener picked was never tuned to that
    /// number, so it plays at the listener's number or 1x. Picking the
    /// builder's own voice is still the builder's voice. A character with no
    /// builder voice has no number either: the fallback voice plays at the
    /// listener's number or 1x, as the fork's kadeVoiceResolver.js does.
    static func characterRate(_ rate: Double?, builderVoice: String?, listenerVoice: String?) -> Double? {
        let builder = (builderVoice ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !builder.isEmpty else { return nil }
        let picked = (listenerVoice ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !picked.isEmpty else { return rate }
        return picked.caseInsensitiveCompare(builder) == .orderedSame ? rate : nil
    }
    /// The `tts` an agent save sends (Oct 30 2026). The field is replaced
    /// whole on the server, so every part the agent has must ride along:
    /// a save that sent only the voice used to erase the speed and delivery
    /// set on the website. nil = nothing to say, and `tts` stays out of the
    /// body. No empty voice id and no number outside 0.5-1.5: the server's
    /// validator refuses the whole save over either one.
    static func agentTTSBody(voice: String, speakingRate: Double?, deliveryMode: String?) -> [String: Any]? {
        var tts: [String: Any] = [:]
        let voiceId = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        if !voiceId.isEmpty { tts["voiceId"] = voiceId }
        if let speakingRate, speakingRate.isFinite {
            tts["speakingRate"] = rate(base: nil, preference: speakingRate)
        }
        if let deliveryMode, ["STABLE", "BALANCED", "CREATIVE"].contains(deliveryMode) {
            tts["deliveryMode"] = deliveryMode
        }
        return tts.isEmpty ? nil : tts
    }
}

/// Filler words and little sounds (Oct 16 2026): the "um" or "uh", a
/// breath or a small laugh the proxy can add to what a character SAYS. The
/// text never changes. Settings carries the switch, on by default.
/// The request field is `fillers`: "true" on, "false" off, left out = the
/// server's default (on for Fish chat voices today).
enum VoiceFillerPolicy {
    static let defaultsKey = "kade.voiceMessage.fillers"

    /// Who a speech request speaks for.
    enum Speaker: Equatable {
        /// A character's voice message, or a cast voice in the Debate Room.
        case character
        /// A book or anything else from the Library: never fillers.
        case libraryReading
        /// No character (a picture description, a transcript read back, the
        /// morning brief): read aloud, so never fillers. Kade, Oct 16 2026:
        /// "Just not for descriptions and books."
        case noCharacter
    }

    /// Nothing saved yet = on.
    static func isOn(stored: Bool?) -> Bool { stored ?? true }

    /// The `fillers` field for one request. It is always sent, so no lane
    /// falls back to the server's default (which is on for chat speech).
    /// Only a character's voice message follows the switch.
    static func field(switchOn: Bool, speaker: Speaker) -> String? {
        switch speaker {
        case .libraryReading, .noCharacter: return "false"
        case .character: return switchOn ? "true" : "false"
        }
    }
}

/// The two audition lines. The proxy matches both exactly: the long one
/// becomes the full performed audition, and both get a voice message's
/// treatment. Change them only together with the proxy.
enum VoiceAudition {
    static let longSample = "Hi there. This is how I sound."
    static let quickSample = "Hey — quick hello from this voice, right here with you."
    static func sample(long: Bool) -> String { long ? longSample : quickSample }
}

/// A play command is not evidence that the renderer has advanced. One bounded
/// recovery may restart the same queued audio; it never synthesizes a new clip.
struct StreamPlaybackStart {
    enum Action: Equatable { case wait, recover, started, failed, cancelled }
    private var deadline: TimeInterval
    private var recovered = false
    private let grace: TimeInterval

    init(now: TimeInterval, grace: TimeInterval = 0.5) {
        self.grace = grace
        deadline = now + grace
    }

    mutating func observe(now: TimeInterval, renderedSeconds: Double?, completedBuffers: Int, current: Bool) -> Action {
        guard current else { return .cancelled }
        if let seconds = renderedSeconds, seconds.isFinite, seconds > 0 { return .started }
        // A very short clip may finish between clock polls.
        if completedBuffers > 0 { return .started }
        guard now >= deadline else { return .wait }
        guard !recovered else { return .failed }
        recovered = true
        deadline = now + grace
        return .recover
    }
}

/// Bounded replay of the SAME HTTP response, so a local player failure does
/// not bill another synthesis. An incomplete/error/oversized response cannot
/// masquerade as a complete clip. Owned and synchronized by StreamingClipFetch.
struct StreamAudioReplay {
    private var bytes = Data()
    private var eligible = true
    private var succeeded = false
    private let limit: Int

    init(limit: Int = 8 * 1024 * 1024) { self.limit = limit }

    mutating func append(_ data: Data) {
        guard eligible else { return }
        guard data.count <= limit - bytes.count else {
            eligible = false
            bytes = Data()
            return
        }
        bytes.append(data)
    }

    mutating func finish(success: Bool) { succeeded = success && eligible }
    var completeAudio: Data? { succeeded && !bytes.isEmpty ? bytes : nil }
}
