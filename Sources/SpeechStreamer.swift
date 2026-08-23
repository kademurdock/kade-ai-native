import Foundation

/// PART 91.6 — SPEAK THE REPLY WHILE IT IS STILL BEING WRITTEN.
///
/// Her question, asked more than once: *"I wonder why we can't have tts play
/// the voice as the text output answer is streaming… there's a hell of a break
/// between ding, message arrived, and tts speaking the message out loud."*
///
/// She guessed the cause was the filtering and editing. It was not. The honest
/// answer is that nothing ever tried. The old order was:
///
///   stream ends -> RELOAD the whole conversation from the server -> hand the
///   ENTIRE reply to the voice service as one synthesis job -> wait for that
///   job -> audio starts.
///
/// A 1,400-character reply is a long synthesis, and the reload is a network
/// round trip on top of it. That whole stack is the silence she hears.
///
/// ⚠️ AND THE ENGINE FOR THE FIX ALREADY EXISTED, ON THE PHONE. voice-stream.js
/// on the bridge has run a SentenceStreamer since the Twilio work — first
/// sentence spoken in about two to three seconds instead of twenty to thirty.
/// The phone got it because a caller will not sit through dead air. The app
/// never got it. This is that idea, client-side, feeding the speech queue the
/// app already has.
///
/// WHAT THIS IS NOT: a second voice system. `VoiceService.enqueueSpeak` already
/// plays items strictly in order and already handles pausing, superseding and
/// per-message keys. This only decides WHEN to hand it a piece.
struct SpeechStreamer {

    /// Sentence-enders that are really sentence-enders. Splitting naively on a
    /// period is how "Dr. Marlowe" and "9 a.m." become two sentences and the
    /// voice stumbles — the phone lane hit exactly that and fixed it the same
    /// way, so the abbreviation list is shared thinking, not a new guess.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "sr", "jr", "prof", "rev", "gen", "sen", "rep",
        "vs", "etc", "eg", "ie", "approx", "dept", "est", "min", "max", "no", "vol",
        "a.m", "p.m", "u.s", "u.k",
    ]

    /// Not spoken until a piece is at least this long. A three-word opener
    /// ("Okay.") synthesised on its own costs a whole network round trip to
    /// say one word, and the queue then stutters between it and the next.
    private let minPieceChars: Int
    /// If the model writes a long clause with no terminator, speak anyway once
    /// it gets this big rather than holding the whole paragraph hostage.
    private let maxPieceChars: Int

    private var buffer = ""
    /// The last `%%%direction%%%` seen. Steering tags lead a paragraph and are
    /// meant to colour everything after them — but each piece is synthesised as
    /// its own stateless call, so without carrying the direction forward only
    /// the first sentence of a reply would be steered and the rest would come
    /// out flat. The phone lane calls this applyDirectionCarry and it is the
    /// reason a streamed reply does not go emotionally dead after sentence one.
    private var carriedDirection: String?

    init(minPieceChars: Int = 60, maxPieceChars: Int = 320) {
        self.minPieceChars = minPieceChars
        self.maxPieceChars = maxPieceChars
    }

    /// Feed a streamed chunk; get back whatever is now ready to speak.
    mutating func push(_ chunk: String) -> [String] {
        buffer += chunk
        var out: [String] = []
        while let piece = takeReadyPiece() {
            if let ready = prepare(piece) { out.append(ready) }
        }
        return out
    }

    /// The stream ended: speak whatever is left, however short.
    mutating func flush() -> [String] {
        let rest = buffer
        buffer = ""
        guard let ready = prepare(rest) else { return [] }
        return [ready]
    }

    // MARK: - internals

    /// Pull one speakable piece off the front of the buffer, or nil if nothing
    /// is ready yet.
    private mutating func takeReadyPiece() -> String? {
        if buffer.count >= maxPieceChars, let cut = softCutIndex() {
            let piece = String(buffer[buffer.startIndex..<cut])
            buffer = String(buffer[cut...])
            return piece
        }
        /* PART 91.8 — KEEP WALKING TO THE NEXT BOUNDARY INSTEAD OF STALLING.
         * The first version stopped at the FIRST sentence end and, if that
         * piece was under the minimum, returned nil and waited. But the buffer
         * still began with that same short sentence, so every later push hit
         * the identical too-short piece and bailed again — a short opener
         * ("Okay." / "Yeah.") deadlocked the lane until the 320-character cap
         * fired and cut the text at an arbitrary comma. That is why her pieces
         * broke in strange places. Now a short sentence simply absorbs the one
         * after it until the piece is worth speaking. */
        var searchFrom = buffer.startIndex
        while let end = sentenceEndIndex(from: searchFrom) {
            let piece = String(buffer[buffer.startIndex..<end])
            if piece.trimmingCharacters(in: .whitespacesAndNewlines).count >= minPieceChars {
                buffer = String(buffer[end...])
                return piece
            }
            guard end < buffer.endIndex else { return nil }
            searchFrom = end
        }
        return nil
    }

    /// Index just past the first real sentence terminator at or after `from`.
    private func sentenceEndIndex(from: String.Index? = nil) -> String.Index? {
        var idx = from ?? buffer.startIndex
        while idx < buffer.endIndex {
            let ch = buffer[idx]
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                let next = buffer.index(after: idx)
                // A terminator only ends a sentence if whitespace or the end
                // follows it — this is what keeps "3.5" and "kade.ai" whole.
                let followedByBreak = next >= buffer.endIndex || buffer[next].isWhitespace
                if followedByBreak && !endsWithAbbreviation(before: idx) {
                    return next <= buffer.endIndex ? next : buffer.endIndex
                }
            }
            idx = buffer.index(after: idx)
        }
        return nil
    }

    private func endsWithAbbreviation(before idx: String.Index) -> Bool {
        guard buffer[idx] == "." else { return false }
        var word = ""
        var i = idx
        while i > buffer.startIndex {
            i = buffer.index(before: i)
            let c = buffer[i]
            if c.isLetter || c == "." { word.insert(c, at: word.startIndex) } else { break }
        }
        return Self.abbreviations.contains(word.lowercased())
    }

    /// For a runaway clause: cut at the last comma or space before the cap so
    /// the break lands somewhere a person would breathe.
    private func softCutIndex() -> String.Index? {
        let cap = buffer.index(buffer.startIndex, offsetBy: maxPieceChars, limitedBy: buffer.endIndex)
            ?? buffer.endIndex
        let head = buffer[buffer.startIndex..<cap]
        if let comma = head.lastIndex(of: ",") { return buffer.index(after: comma) }
        if let space = head.lastIndex(of: " ") { return buffer.index(after: space) }
        return cap
    }

    /// Trim, carry the steering direction, and refuse anything that would only
    /// make the voice say punctuation.
    private mutating func prepare(_ raw: String) -> String? {
        let piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return nil }
        // Nothing worth speaking is only symbols — a lone "---" or "**" would
        // otherwise cost a synthesis call to say nothing.
        guard piece.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }

        if let lead = leadingDirection(of: piece) {
            carriedDirection = lead
            return piece
        }
        if let carried = carriedDirection {
            return "%%%\(carried)%%% \(piece)"
        }
        return piece
    }

    /// A leading `%%%…%%%` tag, if this piece opens with one. Non-verbal cues
    /// (laugh, sigh) are one-shots and are deliberately NOT carried forward —
    /// carrying "laugh" would make her laugh through the whole reply.
    private func leadingDirection(of piece: String) -> String? {
        guard piece.hasPrefix("%%%"),
              let close = piece.range(of: "%%%", range: piece.index(piece.startIndex, offsetBy: 3)..<piece.endIndex)
        else { return nil }
        let inner = String(piece[piece.index(piece.startIndex, offsetBy: 3)..<close.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let nonVerbal: Set<String> = ["laugh", "breathe", "clear throat", "sigh", "cough", "yawn"]
        return nonVerbal.contains(inner.lowercased()) ? nil : inner
    }
}
