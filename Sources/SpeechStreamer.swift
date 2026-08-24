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

    /// Past this, a "sentence" is not a sentence any more and the soft cut
    /// takes over. Twice the cap: long enough that a genuinely long sentence
    /// still gets spoken whole, short enough that a runaway cannot turn into
    /// one enormous synthesis call the listener waits out in silence.
    private var runawayCeiling: Int { maxPieceChars * 2 }

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
        /* PART 92.6 — A REAL SENTENCE BOUNDARY BEATS THE RUNAWAY CAP, AND THE
         * ORDER OF THESE TWO BLOCKS WAS THE WHOLE BUG.
         *
         * The cap block used to run FIRST. So the moment the buffer went over
         * 320 characters — a fast burst, a fat chunk, a pump that fell a beat
         * behind — the lane jumped straight to softCutIndex() and cut at the
         * last COMMA, ignoring every perfectly good sentence ending sitting
         * inside those same 320 characters. Receipt, 354 characters of four
         * clean sentences: arriving in one chunk it came out as a 258-char
         * lump ending "...the fourth complete sentence," and a 95-char
         * remainder. Arriving one character at a time the SAME text came out
         * as four clean sentences. Same input, different cut, and the only
         * difference was how the network happened to fragment it.
         *
         * That is her "it breaks in strange places" from Aug 23, and 91.8
         * fixed only the other half of it (the short-opener deadlock). Worse,
         * 91.8 made this half MORE reachable: short sentences now absorb the
         * next one, so the buffer crosses the cap more often than it used to.
         *
         * The cap's own comment always said what it was for — "if the model
         * writes a long clause with no terminator." It is the FALLBACK. A
         * sentence you can actually speak is always the better piece, even a
         * long one; only past twice the cap is it not really a sentence any
         * more and the soft cut takes over. */
        var searchFrom = buffer.startIndex
        while let end = sentenceEndIndex(from: searchFrom) {
            let piece = String(buffer[buffer.startIndex..<end])
            if piece.count > runawayCeiling { break }
            if piece.trimmingCharacters(in: .whitespacesAndNewlines).count >= minPieceChars {
                buffer = String(buffer[end...])
                return piece
            }
            guard end < buffer.endIndex else { break }
            searchFrom = end
        }
        if buffer.count >= maxPieceChars, let cut = softCutIndex() {
            let piece = String(buffer[buffer.startIndex..<cut])
            buffer = String(buffer[cut...])
            return piece
        }
        return nil
    }

    /* Kept only so the history below stays readable next to the code it
     * describes. PART 91.8 — KEEP WALKING TO THE NEXT BOUNDARY INSTEAD OF STALLING.
         * The first version stopped at the FIRST sentence end and, if that
         * piece was under the minimum, returned nil and waited. But the buffer
         * still began with that same short sentence, so every later push hit
         * the identical too-short piece and bailed again — a short opener
         * ("Okay." / "Yeah.") deadlocked the lane until the 320-character cap
         * fired and cut the text at an arbitrary comma. That is why her pieces
         * broke in strange places. Now a short sentence simply absorbs the one
         * after it until the piece is worth speaking. That absorb-forward rule
         * is the loop above; this note is what bought it. */

    /// Index just past the first real sentence terminator at or after `from`.
    private func sentenceEndIndex(from: String.Index? = nil) -> String.Index? {
        var idx = from ?? buffer.startIndex
        while idx < buffer.endIndex {
            let ch = buffer[idx]
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                let next = buffer.index(after: idx)
                // A terminator only ends a sentence if whitespace or the end
                // follows it — this is what keeps "3.5" and "kade.ai" whole.
                /* PART 92.6 — THE BUFFER ENDING IS NOT THE TEXT ENDING.
                 * This used to read `next >= buffer.endIndex || …`, treating
                 * "nothing follows the dot YET" as "the sentence is over". In
                 * a stream that is never true: more is coming. When a network
                 * chunk boundary happened to land right after a dot, the lane
                 * cut there — and "kade.ai" went to the synthesiser as "kade."
                 * then "ai", and "3.5" as "3." then "5". A dose read aloud as
                 * "three point" … "five milligrams" is the failure that matters,
                 * and the abbreviation list cannot catch it because the guard
                 * that fires is this one, not that one.
                 * Reproduced on the real struct: the identical sentence split
                 * in two when fed as two chunks and stayed whole when fed as
                 * one. Now only flush() — which takes the whole remaining
                 * buffer by design — may end a sentence at the end of the text. */
                let followedByBreak = next < buffer.endIndex && buffer[next].isWhitespace
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
            /* PART 92.11 — REMEMBER THE DIRECTION, BUT NEVER SPEAK IT ALONE.
             *
             * Found by her ear on build 241: "every now and then it would play
             * the error sound tone in the middle — first section, error sound,
             * more words, error sound, more words." The production logs named
             * it exactly. Two of twenty-nine synthesis calls for that one reply
             * carried NOTHING BUT A DIRECTION:
             *
             *   input len=65, after strip len=61: "%%%settling in like…%%%"
             *   input len=77, after strip len=73: "%%%picking up a little…%%%"
             *
             * The synthesiser strips the tag, finds no words, returns nothing;
             * VoiceService gets nil and plays the error boop — which session 23
             * added on purpose so a dead synth would stop being silent. The
             * boop was right. The request should never have been made.
             *
             * ⚠️ THE GUARD FIVE LINES UP WAS SUPPOSED TO CATCH THIS AND ITS
             * COMMENT SAYS SO — "refuse anything that would only make the voice
             * say punctuation." It tests isLetter || isNumber, and "settling in
             * like i've been waiting for somebody to ask this" is ALL letters.
             * A direction reads as speech to a check that only knows symbols.
             * These tags run 60-80 characters, which clears minPieceChars, so a
             * tag alone at the top of a paragraph was a legal piece by every
             * rule this splitter had.
             *
             * The direction is still CARRIED — dropping it is what makes a
             * streamed reply go emotionally flat after sentence one, which is
             * the whole reason carriedDirection exists. It just does not get
             * spoken by itself. takeReadyPiece() has already removed this piece
             * from the buffer, so returning nil drops it without stalling: no
             * repeat of 91.8's deadlock, where bailing left the same text at
             * the front of the buffer forever. */
            carriedDirection = lead
            guard hasSpeechAfterDirection(piece) else { return nil }
            return piece
        }
        if let carried = carriedDirection {
            return "%%%\(carried)%%% \(piece)"
        }
        return piece
    }

    /// Is there anything to actually SAY after this piece's leading tag?
    /// A piece that is only a direction costs a synthesis call and comes back
    /// empty, which the app reports to her as an error tone.
    private func hasSpeechAfterDirection(_ piece: String) -> Bool {
        guard piece.hasPrefix("%%%"),
              let close = piece.range(of: "%%%", range: piece.index(piece.startIndex, offsetBy: 3)..<piece.endIndex)
        else { return true }
        return !piece[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
