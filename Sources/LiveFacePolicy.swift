import Foundation

/// Oct 28 2026 (Kade: "like Marco Polo or WhatsApp where for sighted people,
/// listening to a voice message would trigger a video... and calls would be
/// video calls... for blind people, we could turn it off to save money").
///
/// The account says whether this person uses the screen. The live video face
/// (a character's painting driven live by whatever it is saying, rendered by
/// a paid service at about a cent a minute) only ever opens for an account
/// that has said yes. Nobody is charged for a picture they cannot see, and
/// nobody is charged before they have said so. Pure, so the decision is
/// testable with swiftc alone (LiveFaceTests, run-live-face-tests.sh).
enum SightSetting {
    static let key = "kadeSight"
    static let unset = ""
    static let sighted = "sighted"
    static let nonvisual = "nonvisual"
}

enum LiveFaceSetting {
    static let key = "kadeLiveFaces"
    static let defaultOn = true
}

enum LiveFaceLane: String {
    case chat, call
}

/// Why a live face stays closed. `nil` from `LiveFacePolicy.refusal` means open it.
enum LiveFaceRefusal: Equatable {
    /// The account has not said it uses the screen, or said it does not.
    case notSighted
    /// The person turned "Live video faces" off.
    case switchedOff
    /// VoiceOver is running: whoever is holding the phone is not watching it.
    case voiceOver
    /// The server has no live face service set up at all.
    case notOffered
    /// This character has no live face (Kiana and Harley first).
    case noFace
    /// No character on the stage.
    case noAgent
    /// Motion is off (Reduce Motion, Low Power Mode, a hot phone): a video
    /// face is the biggest motion there is, so it follows the same gate.
    case motionOff
    /// Only the big stage (a conversation's top, a call) shows video; compact
    /// rows keep their paintings.
    case notStage
}

enum LiveFacePolicy {
    static func refusal(sight: String, liveFaces: Bool, voiceOver: Bool,
                        serverEnabled: Bool, agents: Set<String>, agentID: String?,
                        motionAllowed: Bool, stage: Bool) -> LiveFaceRefusal? {
        guard let agentID, !agentID.isEmpty else { return .noAgent }
        guard stage else { return .notStage }
        if sight != SightSetting.sighted { return .notSighted }
        if !liveFaces { return .switchedOff }
        if voiceOver { return .voiceOver }
        if !motionAllowed { return .motionOff }
        guard serverEnabled else { return .notOffered }
        guard agents.contains(agentID) else { return .noFace }
        return nil
    }

    /// The page is loaded muted for a call: the call's own audio engine keeps
    /// playing (and echo-cancelling) as before and the video follows it. A chat
    /// clip is heard from the page, which keeps the mouth and the voice together.
    static func pageMuted(lane: LiveFaceLane) -> Bool { lane == .call }

    /// Seconds a clip is allowed to take before the wait gives up: its own
    /// length plus the service's lag, plus a margin for a slow first frame.
    static func clipTimeout(seconds: Double) -> Double {
        max(2, seconds) + 4
    }

    /// PCM16 mono 16 kHz, in quarter-second pieces: small enough that the first
    /// frame moves within a beat, large enough not to flood the socket.
    static let chunkBytes = 8000
}

/// The painted loops (option four): short film loops made once from each
/// character's painting, shown on a sighted person's stage between replies
/// when the live face is not running. While the character speaks the mesh
/// rig takes over, since only it knows the mouth. Blind accounts never load
/// them: they are decoration, and data.
enum CharacterLoopState: String, CaseIterable {
    case idle, listening, thinking, laugh, surprised, concerned
}

enum CharacterLoopPolicy {
    /// Which loop a stage shows for a performance, or nil to show the rig.
    static func state(sight: String, speaking: Bool, thinking: Bool, listening: Bool,
                      face: String, motionAllowed: Bool, liveFaceUp: Bool) -> CharacterLoopState? {
        guard sight == SightSetting.sighted, motionAllowed, !liveFaceUp, !speaking else { return nil }
        if thinking { return .thinking }
        switch face {
        case "laugh", "delighted": return .laugh
        case "surprised", "shocked": return .surprised
        case "worried", "sad", "serious", "tender": return .concerned
        default: return listening ? .listening : .idle
        }
    }

    /// Where a character's loops live. Only the painted cast with loops.
    static func folder(agentID: String?) -> String? {
        switch agentID {
        case "agent_6llV0eMu4fmIaj8f2x1Sb": return "kiana"
        case "agent_d26Mtu8mgOzkVGQECqO1a": return "harley"
        default: return nil
        }
    }

    static func url(agentID: String?, state: CharacterLoopState) -> URL? {
        guard let folder = folder(agentID: agentID) else { return nil }
        return URL(string: "https://kademurdock.com/assets/characters/\(folder)/loops/\(state.rawValue).mp4")
    }
}
