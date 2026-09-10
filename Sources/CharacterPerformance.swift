import Foundation

enum CharacterExpression: String, Codable, CaseIterable {
    case neutral, warm, amused, serious, concerned, skeptical, surprised
    var cell: Int? {
        switch self {
        case .neutral: return nil
        case .amused: return 0
        case .serious: return 1
        case .concerned: return 2
        case .skeptical: return 3
        case .surprised: return 4
        case .warm: return 5
        }
    }
}

enum CharacterActivity { case idle, listening, thinking, speaking }

/// Reads authored leading speech directions only. Never analyzes a person's
/// words or assigns invented word-to-audio timestamps.
struct CharacterCue: Equatable {
    var expression: CharacterExpression = .neutral
    var moment: CharacterExpression?
    static let neutral = CharacterCue()
    func expression(at elapsed: Double) -> CharacterExpression {
        if elapsed.isFinite, elapsed >= 0, elapsed < 0.8, let moment { return moment }
        return expression
    }
    static func fromSpeech(_ text: String) -> CharacterCue {
        let prefix = String(text.prefix(1024))
        var rest = prefix[...], result = CharacterCue.neutral
        for _ in 0..<8 {
            rest = rest.drop(while: { $0.isWhitespace })
            guard rest.hasPrefix("%%%"), let end = rest.dropFirst(3).range(of: "%%%") else { break }
            let tag = String(rest[rest.index(rest.startIndex, offsetBy: 3)..<end.lowerBound])
            guard !tag.isEmpty, !tag.contains("%"), !tag.contains("\n"), tag.count <= 160 else { break }
            let words = tag.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            let exact = words.joined(separator: " ")
            let moments: [String: CharacterExpression] = ["laugh": .amused, "chuckle": .amused,
                "giggle": .amused, "cackle": .amused, "scoff": .skeptical, "gasp": .surprised,
                "sigh": .concerned, "cry": .concerned, "sob": .concerned]
            if let value = moments[exact] { result.moment = value }
            else {
                let ignored = ["breath", "pant", "huff", "grunt", "groan", "moan", "snort", "wail", "whimper", "whine", "sniffle", "sniff", "shriek", "squeal", "howl", "clear throat", "cough", "sneeze", "hiccup", "yawn", "burp", "snore", "choke", "gag", "swallow", "gulp", "spit", "tongue click", "mouth click", "mouth sound", "lip smack", "kiss", "shush", "raspberry", "whistle", "bleh", "chew", "slurp", "babble", "beatbox", "growl"]
                if !ignored.contains(exact) {
                    result = .neutral
                    let tokens = Set(words)
                    if tokens.isDisjoint(with: ["not", "never", "without", "no"]) {
                        let rules: [(CharacterExpression, Set<String>)] = [
                            (.concerned, ["sad", "sadness", "worried", "concerned", "sorrowful"]),
                            (.serious, ["serious", "solemn", "firm"]),
                            (.skeptical, ["skeptical", "sceptical", "doubtful", "unconvinced"]),
                            (.surprised, ["surprised", "astonished", "startled", "shocked"]),
                            (.amused, ["amused", "playful", "delighted", "grinning", "excited"]),
                            (.warm, ["warm", "fond", "friendly", "tender"])]
                        result.expression = rules.first { !tokens.isDisjoint(with: $0.1) }?.0 ?? .neutral
                    }
                }
            }
            rest = rest[end.upperBound...]
        }
        return result
    }
}

struct CharacterPresentation {
    var activity: CharacterActivity = .idle
    var expression: CharacterExpression = .neutral
    var elapsed: Double = 0
    static let idle = CharacterPresentation()
}

struct CharacterAudioIdentity {
    let speakerID: String
    let speech: Bool
    let cue: CharacterCue
    init?(speakerID: String?, speech: Bool?, expression: String?, moment: String?) {
        guard let speakerID, !speakerID.isEmpty, speakerID.count <= 64, let speech,
              let expression, let value = CharacterExpression(rawValue: expression),
              moment == nil || CharacterExpression(rawValue: moment!) != nil else { return nil }
        self.speakerID = speakerID; self.speech = speech
        self.cue = CharacterCue(expression: value, moment: moment.flatMap(CharacterExpression.init(rawValue:)))
    }
}

/// Presentation-only queue against the existing player's source clock. It never
/// supplies times to the audio scheduler, and retains no sound or transcript.
struct CharacterPlaybackTimeline {
    struct Clip { let start: Double; let end: Double; let identity: CharacterAudioIdentity? }
    private(set) var clips: [Clip] = []
    private var end = 0.0
    private var blocked = false
    mutating func reset() { clips.removeAll(keepingCapacity: true); end = 0; blocked = false }
    mutating func append(identity: CharacterAudioIdentity?, duration: Double, now: Double) {
        guard !blocked else { return }
        guard duration.isFinite, duration > 0, duration <= 120, now.isFinite, now >= 0 else { reset(); blocked = true; return }
        clips.removeAll { $0.end <= now }
        guard clips.count < 128 else { reset(); blocked = true; return }
        let start = max(end, now)
        clips.append(Clip(start: start, end: start + duration, identity: identity))
        end = start + duration
    }
    func presentation(at time: Double, expectedID: String?) -> CharacterPresentation? {
        guard time.isFinite, time >= 0, let expectedID,
              let clip = clips.first(where: { $0.start <= time && time < $0.end }),
              let identity = clip.identity, identity.speech, identity.speakerID == expectedID else { return nil }
        let elapsed = time - clip.start
        return CharacterPresentation(activity: .speaking, expression: identity.cue.expression(at: elapsed), elapsed: elapsed)
    }
}
