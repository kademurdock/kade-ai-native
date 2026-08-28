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

    /* PART 92.12 — THE FLOOR IS NOT ONE NUMBER, BECAUSE THE FIRST PIECE AND
     * EVERY PIECE AFTER IT ARE PAYING FOR DIFFERENT THINGS.
     *
     * Measured against the live endpoint Aug 24-25 2026, both regimes:
     *   normal   ~1.31s fixed per-request overhead + ~12.6ms/char
     *   degraded ~5.9s  fixed per-request overhead + ~7.1ms/char  (a ~30min
     *            Inworld spike; same voice, same text, no deploy of ours)
     * Audio runs ~62ms/char. So margin per piece = 0.062c - (fixed + rate*c).
     * At 1.31s fixed EVERY piece size clears, which is why this never showed
     * before. At 5.9s fixed a 60-char piece is ~3.3s of audio against ~6.3s
     * of synthesis — a DEFICIT. Consecutive short sentences drain the buffer
     * and the listener eats a whole synthesis as dead air. That is the "five
     * or more seconds, every few sentences" a family member reported.
     *
     * A 160-char floor leaves ~+2.9s of margin even at 5.9s fixed overhead.
     * But raising the floor for the FIRST piece would pay for that with
     * time-to-first-word, which is the exact complaint 91.6 was built to fix
     * ("a hell of a break between ding and tts speaking"). So the opener keeps
     * the old small floor and everything after it gets the big one.
     *
     * ⚠️ Forge's catch, and it is the failure mode worth naming: the floor is
     * enforced by ABSORB-FORWARD (91.8) — a piece under the floor swallows the
     * next sentence. If the opener were ever measured against the big floor it
     * would absorb sentence two and the fast start would be silently gone.
     * `pieceFloor` reads `piecesEmitted == 0`, and takeReadyPiece returns the
     * instant the floor is met, so the opener cannot absorb. firstPieceGuard()
     * in the tests is what keeps that true. */
    private let firstPieceChars: Int
    /// Not spoken until a piece is at least this long. A three-word opener
    /// ("Okay.") synthesised on its own costs a whole network round trip to
    /// say one word, and the queue then stutters between it and the next.
    private let minPieceChars: Int
    /// If the model writes a long clause with no terminator, speak anyway once
    /// it gets this big rather than holding the whole paragraph hostage.
    private let maxPieceChars: Int

    private var buffer = ""
    /// How many pieces this reply has actually handed out. Only the opener
    /// (0) gets the small floor. Counted on EMIT, not on cut, so a piece that
    /// prepare() drops (a direction with nothing to say) never spends the
    /// fast-start allowance.
    private var piecesEmitted = 0
    /// The floor this piece must clear before it is worth a synthesis call.
    private var pieceFloor: Int { piecesEmitted == 0 ? firstPieceChars : minPieceChars }
    /// The last `%%%direction%%%` seen. Steering tags lead a paragraph and are
    /// meant to colour everything after them — but each piece is synthesised as
    /// its own stateless call, so without carrying the direction forward only
    /// the first sentence of a reply would be steered and the rest would come
    /// out flat. The phone lane calls this applyDirectionCarry and it is the
    /// reason a streamed reply does not go emotionally dead after sentence one.
    private var carriedDirection: String?

    /* ⭐ PART 94 — THE CARRY HAD NO BRAKE, AND THAT IS THE BUG SHE HEARD.
     *
     * Her report, Aug 28 2026: "a single tag carried over the entire message."
     * She opened a reply with one %%%slow and soothing%%% and never re-tagged,
     * and every sentence of that reply came out slow and soothing.
     *
     * ⚠️ AND THE CAP FOR THIS ALREADY EXISTED — IN THE WRONG LANE. The proxy's
     * `applySteeringTags` has capped its paragraph carry at TTS_STEER_CARRY=2
     * since Aug 18, written for this exact complaint ("a direction should
     * colour the thought it was written for and the next beat or two, not
     * haunt the rest of the reply"). It never fires for a streamed reply,
     * and it CANNOT: this struct re-stamps `%%%direction%%%` onto the front
     * of every piece, and each piece is its own request, so from the proxy's
     * side every paragraph it sees was tagged BY THE AUTHOR. A paragraph that
     * opens with its own tag is exactly the case the proxy skips. The cap was
     * being handed a forgery every time.
     *
     * So the brake belongs here, where the carry is actually created, and it
     * is set to match the proxy's number rather than invent a second one.
     * Two bounds because pieces vary from 160 to 640 characters and either
     * one alone would be the wrong shape: the direction colours the thought
     * it opened plus the next beat or two, then the voice returns to her own
     * register exactly as if the author had written %%%reset%%%.
     *
     * NOT zero, and this is the trap 91.10 already fell into once: dropping
     * the carry entirely is what makes a streamed reply go emotionally dead
     * after sentence one, which is the whole reason carriedDirection exists.
     * The fix for "it never stops" is not "it never starts." */
    private let carryMaxPieces: Int
    private let carryMaxChars: Int
    /// Pieces that have been stamped with the CARRIED direction (the authored
    /// piece itself is not counted -- the author asked for that one).
    private var carriedPieces = 0
    /// Characters spoken under the carried direction, the second bound.
    private var carriedChars = 0

    /// Past this, a "sentence" is not a sentence any more and the soft cut
    /// takes over. Twice the cap: long enough that a genuinely long sentence
    /// still gets spoken whole, short enough that a runaway cannot turn into
    /// one enormous synthesis call the listener waits out in silence.
    private var runawayCeiling: Int { maxPieceChars * 2 }

    init(
        firstPieceChars: Int = 60,
        minPieceChars: Int = 160,
        maxPieceChars: Int = 320,
        carryMaxPieces: Int = 2,
        carryMaxChars: Int = 600
    ) {
        self.firstPieceChars = firstPieceChars
        self.minPieceChars = minPieceChars
        self.maxPieceChars = maxPieceChars
        self.carryMaxPieces = carryMaxPieces
        self.carryMaxChars = carryMaxChars
    }

    /// Feed a streamed chunk; get back whatever is now ready to speak.
    mutating func push(_ chunk: String) -> [String] {
        buffer += chunk
        var out: [String] = []
        while let piece = takeReadyPiece() {
            if let ready = prepare(piece) { out.append(ready); piecesEmitted += 1 }
        }
        return out
    }

    /// The stream ended: speak whatever is left, however short.
    mutating func flush() -> [String] {
        let rest = buffer
        buffer = ""
        guard let ready = prepare(rest) else { return [] }
        piecesEmitted += 1
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
            if piece.trimmingCharacters(in: .whitespacesAndNewlines).count >= pieceFloor {
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
            /* ⭐ PART 94 — %%%reset%%% IS AN ENDING, NOT A DIRECTION.
             *
             * The persona tells her to close a steered passage with
             * %%%reset%%% and the PROXY has honoured that since Aug 25
             * (soundsIsResetTag ends the paragraph carry). This lane never
             * learned the word. "reset" is not in the non-verbal set above,
             * so it fell through as an ordinary direction and became the
             * CARRIED one -- every following piece went out stamped
             * `%%%reset%%%`, which is the precise opposite of what the
             * author asked for and left the real direction un-ended.
             * The one tool she had for saying STOP was a no-op here. */
            if Self.isResetTag(lead) {
                clearCarry()
            } else {
                carriedDirection = lead
                carriedPieces = 0
                carriedChars = 0
            }
            guard hasSpeechAfterDirection(piece) else { return nil }
            return piece
        }
        if let carried = carriedDirection {
            // Spent: the direction has coloured its thought and the next beat
            // or two. Return to her own register, same as a written reset.
            if carriedPieces >= carryMaxPieces || carriedChars >= carryMaxChars {
                clearCarry()
                return piece
            }
            carriedPieces += 1
            carriedChars += piece.count
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

    /// The author's way of saying "stop steering, go back to normal."
    /// Case- and space-insensitive, matching `sounds.js`'s `isResetTag` on
    /// the proxy so the two halves can never disagree about the word.
    private static func isResetTag(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "reset"
    }

    private mutating func clearCarry() {
        carriedDirection = nil
        carriedPieces = 0
        carriedChars = 0
    }
}
