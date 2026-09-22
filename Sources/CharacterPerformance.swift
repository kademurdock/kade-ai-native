import Foundation

/// Original sheet indices remain stable; additional faces use the nuance sheet.
enum CharacterFace: Int, CaseIterable {
    case neutral = 0, smile, laugh, surprised, skeptical, angry, sad, worried, closed
    case curious, thoughtful, playful, confident, tender, tired, serious, delighted
}

enum CharacterExpression: String, Codable, CaseIterable {
    case neutral, warm, amused, serious, concerned, skeptical, surprised
    // Sep 19 2026 (Kade: "a wide scope of keywords and expressions"). The first
    // seven stay first and keep their names: call metadata sends them by name.
    case tender, calm, confident, playful, excited, smug, curious, thoughtful
    case dry, frustrated, angry, disgusted, afraid, sad, tired
    var cell: Int? {
        switch self {
        case .amused: return 0
        case .serious: return 1
        case .concerned: return 2
        case .skeptical: return 3
        case .surprised: return 4
        case .warm: return 5
        default: return nil
        }
    }
    /// Delivery directions select a complete expression rather than a partial overlay.
    var face: CharacterFace {
        switch self {
        case .warm, .amused: return .smile
        case .curious: return .curious
        case .thoughtful: return .thoughtful
        case .playful, .smug: return .playful
        case .confident: return .confident
        case .tender: return .tender
        case .tired: return .tired
        case .serious: return .serious
        case .excited: return .delighted
        case .skeptical, .dry: return .skeptical
        case .frustrated, .angry, .disgusted: return .angry
        case .surprised: return .surprised
        case .sad: return .sad
        case .concerned, .afraid: return .worried
        default: return .neutral
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
                    // A negated word is dropped, not the whole direction:
                    // "warm but not letting it slide" is still warm, "not sad" is nothing.
                    var kept: [String] = []
                    var skipNext = false
                    for word in words {
                        if skipNext { skipNext = false; continue }
                        if ["not", "never", "without", "no", "hardly", "zero"].contains(word) { skipNext = true; continue }
                        kept.append(word)
                    }
                    let tokens = Set(kept)
                    result.expression = CharacterCue.vocabulary.first { !tokens.isDisjoint(with: $0.1) }?.0 ?? .neutral
                }
            }
            rest = rest[end.upperBound...]
        }
        return result
    }
}

extension CharacterCue {
    /// First match wins, so the stronger and more visible feeling sits higher.
    /// Same families and order as the web's avatar-expression.mjs, as single words.
    static let vocabulary: [(CharacterExpression, Set<String>)] = [
        (.angry, ["angry", "anger", "mad", "furious", "fury", "livid", "seething", "fuming", "rage", "raging", "enraged", "irate", "hot", "heated", "snarling", "growling", "outraged", "pissed", "venomous", "spitting", "hostile", "fierce", "biting", "scathing", "yelling", "shouting", "screaming", "roaring", "barking"]),
        (.frustrated, ["frustrated", "frustration", "exasperated", "irritated", "annoyed", "annoyance", "impatient", "impatience", "clipped", "curt", "terse", "snappy", "snapping", "testy", "aggravated", "bristling", "gritted"]),
        (.afraid, ["afraid", "scared", "fear", "fearful", "frightened", "terrified", "panicked", "panicky", "alarmed", "nervous", "nervously", "anxious", "anxiously", "anxiety", "jittery", "shaky", "shaking", "trembling", "uneasy", "spooked", "dread", "rattled"]),
        (.sad, ["sad", "sadness", "sadly", "sorrow", "sorrowful", "grief", "grieving", "mournful", "heartbroken", "tearful", "teary", "crying", "wounded", "hurt", "aching", "bereft", "lonely", "wistful", "melancholy", "defeated", "deflated", "crestfallen", "hollow"]),
        (.concerned, ["worried", "worry", "concerned", "concern", "troubled", "protective", "sympathetic", "sympathy", "compassionate", "apologetic", "sorry", "regretful", "pained"]),
        (.disgusted, ["disgusted", "disgust", "revolted", "repulsed", "appalled", "sneering", "contempt", "contemptuous", "scornful", "scorn", "disdain", "disdainful", "withering"]),
        (.surprised, ["surprised", "surprise", "astonished", "startled", "shocked", "stunned", "amazed", "amazement", "awed", "awestruck", "disbelief", "disbelieving", "incredulous", "floored", "blindsided", "marveling"]),
        (.excited, ["excited", "excitedly", "excitement", "thrilled", "elated", "ecstatic", "overjoyed", "joyful", "joyous", "joy", "jubilant", "delighted", "delight", "giddy", "bubbly", "bright", "brightly", "bouncy", "bouncing", "buzzing", "hyped", "pumped", "eager", "eagerly", "enthusiastic", "exuberant", "gushing", "beaming", "triumphant", "celebrating"]),
        (.amused, ["amused", "amusement", "laughing", "chuckling", "giggling", "cackling", "snickering", "tickled", "funny", "humor", "humorous", "grinning", "grin", "mirth", "entertained", "wheezing"]),
        (.playful, ["playful", "playfully", "teasing", "teasingly", "tease", "mischievous", "mischief", "impish", "cheeky", "sly", "slyly", "flirty", "flirting", "flirtatious", "coy", "sassy", "sass", "saucy", "silly", "goofy", "joking", "kidding", "ribbing", "needling", "conspiratorial", "winking"]),
        (.smug, ["smug", "smugly", "proud", "proudly", "gloating", "cocky", "superior", "vindicated", "satisfied", "preening"]),
        (.skeptical, ["skeptical", "skeptically", "sceptical", "doubtful", "doubting", "doubt", "unconvinced", "suspicious", "suspiciously", "dubious", "wary", "warily", "unimpressed", "arch", "archly", "pointed", "pointedly", "questioning"]),
        (.serious, ["serious", "seriously", "solemn", "solemnly", "firm", "firmly", "stern", "sternly", "grave", "gravely", "sober", "level", "leveling", "measured", "steady", "steadily", "direct", "blunt", "bluntly", "resolute", "commanding", "authoritative", "warning", "urgent", "urgently", "intense", "intensely", "earnest", "earnestly", "sincere", "sincerely"]),
        (.dry, ["dry", "dryly", "drily", "deadpan", "flat", "flatly", "wry", "wryly", "sardonic", "sarcastic", "sarcastically", "ironic", "droll", "laconic", "monotone", "unbothered", "bored", "unamused"]),
        (.tired, ["tired", "weary", "wearily", "exhausted", "worn", "drained", "sleepy", "drowsy", "groggy", "yawning", "spent", "fatigued", "sluggish", "raspy", "hoarse"]),
        (.thoughtful, ["thoughtful", "thoughtfully", "thinking", "pondering", "musing", "mulling", "reflective", "reflecting", "considering", "careful", "carefully", "cautious", "cautiously", "contemplative", "deliberate", "deliberately"]),
        (.curious, ["curious", "curiously", "curiosity", "intrigued", "interested", "inquisitive", "fascinated", "nosy", "probing", "puzzled", "perplexed", "confused", "quizzical"]),
        (.tender, ["tender", "tenderly", "soft", "softly", "softer", "softening", "gentle", "gently", "quiet", "quietly", "quieter", "hushed", "whisper", "whispering", "whispered", "murmuring", "intimate", "soothing", "comforting", "loving", "lovingly", "affectionate"]),
        (.warm, ["warm", "warmly", "warmer", "warming", "warmth", "fond", "fondly", "friendly", "kind", "kindly", "welcoming", "smiling", "smile", "glad", "happy", "happily", "cheerful", "cheerfully", "cheery", "sunny", "pleasant", "pleased", "grateful", "appreciative", "encouraging", "supportive"]),
        (.confident, ["confident", "confidently", "sure", "certain", "assured", "bold", "boldly", "decisive", "strong", "strongly", "brisk", "briskly", "crisp", "crisply"]),
        (.calm, ["calm", "calmly", "calmer", "calming", "relaxed", "easy", "easygoing", "unhurried", "settled", "settling", "peaceful", "serene", "mellow", "even", "evenly", "patient", "patiently", "reassuring", "grounded"]),
    ]

    /// The app speaks a reply one sentence per clip and only the first clip
    /// carries the character's direction, so a clip with no direction of its
    /// own keeps the one before it. A leading sound alone (a laugh) plays over
    /// the carried direction. A new direction, or reset, replaces it.
    static func fromSpeech(_ text: String, carrying previous: CharacterCue) -> CharacterCue {
        let cue = fromSpeech(text)
        let leadsWithTag = text.drop(while: { $0.isWhitespace }).hasPrefix("%%%")
        if !leadsWithTag { return CharacterCue(expression: previous.expression, moment: nil) }
        if cue.expression == .neutral, cue.moment != nil { return CharacterCue(expression: previous.expression, moment: cue.moment) }
        return cue
    }
    /// A laugh is the one sound with a face of its own.
    func laughing(at elapsed: Double) -> Bool {
        elapsed.isFinite && elapsed >= 0 && elapsed < 0.8 && moment == .amused
    }
}

struct CharacterPresentation {
    var activity: CharacterActivity = .idle
    var expression: CharacterExpression = .neutral
    var elapsed: Double = 0
    var laughing = false
    var face: CharacterFace {
        if laughing { return .laugh }
        if expression == .neutral && activity == .thinking { return .thoughtful }
        if expression == .neutral && activity == .listening { return .curious }
        return expression.face
    }
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
        return CharacterPresentation(activity: .speaking, expression: identity.cue.expression(at: elapsed), elapsed: elapsed, laughing: identity.cue.laughing(at: elapsed))
    }
}
