import Foundation

/// Strips inline tags that agents embed in message text for a consumer
/// OTHER than a human directly reading or hearing the words -- TTS
/// performance-steering delimiters, Game Parlor sound/table cues, and the
/// web composer's Deep Think marker. Ported July 19 2026 after Kade
/// reported VoiceOver reading raw "%%%" tags aloud in the native chat
/// view: `KadeMessage.displayText` never sanitized anything before this,
/// unlike the web client. Mirrors the fork's own
/// `stripGameSoundTags(stripVoiceTags(text))` composition exactly
/// (`client/src/utils/voiceTags.ts` + `client/src/utils/gameSounds.ts`)
/// so a conversation reads the same whether she's on web or here.
///
/// NEVER apply this to text headed for `VoiceService.enqueueSpeak` -- the
/// "%%%..." voice tags must survive intact so inworld-tts-proxy can turn
/// them into real steering brackets right before synthesis. That is the
/// actual spoken agent voice, which already sounds correct today (per
/// Kade's own report: "not the agent voice but voiceover") and must stay
/// exactly as it is. This sanitizer exists only for the two surfaces a
/// human directly reads or VoiceOver directly speaks: the chat bubble
/// text (`MessageRow.bodyText`) and its accessibility label/rotor
/// preview -- see `KadeMessage.readableText`.
///
/// This app only ever renders a FINISHED message (see
/// `ConversationDetailView`'s top doc comment -- Phase 3 deliberately
/// shows no token-by-token streaming), so unlike the web client this
/// never needs the paired "hideDangling…" half of those web utilities:
/// there is no in-flight, not-yet-closed tag to guard against here, only
/// ever a complete saved message.
enum MessageTextSanitizer {
    /// A complete "%%%direction%%%" pair -- the canonical TTS-2 voice
    /// performance tag delimiter.
    private static let voiceTagRegex = makeRegex("%%%([\\s\\S]*?)%%%")

    /// Aug 6 2026 — multi-speaker voice SCENES (Part 32): "[[Deuce]] line" /
    /// "[[Voice 214]] line" perform as true multi-voice audio server-side;
    /// on every READ surface the tag renders as a screenplay cue, "Deuce:
    /// line" — the native twin of voiceTags.ts's sceneTagsToScript. Double
    /// brackets only; single-bracket spans are other machinery.
    private static let sceneTagRegex = makeRegex("\\[\\[\\s*([^\\[\\]\\n]{1,58}?)[:\\s]*\\]\\][ \\t]*")

    /// Tag-typo tolerance: the model sometimes emits a malformed
    /// delimiter ("%%sigh%%" or "%%%sigh%%") the canonical regex above
    /// misses. Mirrors SLOPPY_VOICE_TAG_RE exactly, including its guard
    /// against eating a legitimate doubled percent sign in ordinary prose
    /// (the enclosed span must start with a letter, contain no percent
    /// sign or newline, and stay short).
    private static let sloppyVoiceTagRegex = makeRegex(
        "%{2,4}([a-zA-Z][a-zA-Z \u{2019}',!-]{0,60}?)%{2,4}"
    )

    /// Game Parlor sound cue, e.g. "[sound:card_deal]".
    private static let gameSoundRegex = makeRegex(
        "\\[sound:([a-z0-9_]+)\\]", caseInsensitive: true
    )

    /// Game Parlor live-table widget token, e.g. "[table:uno7x]".
    private static let gameTableRegex = makeRegex(
        "\\[table:([a-z0-9]{1,12})\\]", caseInsensitive: true
    )

    /// The web composer's Deep Think marker appended to an outgoing user
    /// message, e.g. "[DEEP THINK 1737400000000]".
    private static let deepThinkRegex = makeRegex(
        "\\[DEEP THINK(?:\\s+\\d{10,17})?\\]", caseInsensitive: true
    )

    /// Session 23 (Kade: "\\u200 searchtern spam in the text of Kiana's
    /// replies... they didn't show up in audio but they need to be gone
    /// from the text"): WEB-SEARCH CITATION ANCHORS. The web-search tool
    /// context instructs the model to emit citation markers — private-use
    /// characters U+E200..U+E204 plus anchors like "turn0search0" — which
    /// the WEB client renders as tidy citation chips. This app renders raw
    /// text, so they surfaced verbatim (and models often emit the LITERAL
    /// ASCII escape "\\ue202turn0search0" rather than the real
    /// character, which is exactly the "\\u200 searchtern" VoiceOver
    /// read to her). The voice lane never had them because the TTS path
    /// scrubs server-side. Three passes: literal ASCII escapes with any
    /// attached anchor token, real PUA characters with any attached
    /// anchor token, then orphaned anchor tokens left behind by either.
    private static let literalCitationRegex = makeRegex(
        "\\\\+u\\s?e?20[0-9a-f](?:turn\\d{1,3}[a-z]{2,10}\\d{1,3})?", caseInsensitive: true
    )
    private static let puaCitationRegex = makeRegex(
        "[\u{E200}-\u{E20F}](?:turn\\d{1,3}[a-z]{2,10}\\d{1,3})?", caseInsensitive: true
    )
    private static let orphanAnchorRegex = makeRegex(
        "\\bturn\\d{1,3}(?:search|news|image|ref|view|fetch|video|file)\\d{1,3}\\b", caseInsensitive: true
    )

    /// Aug 7 2026 (Kade: "what's with all the ## stuff") — markdown
    /// DECORATION on the display surface. Models dress structured replies
    /// for a screen (## headers, **bold**, bullet stars); the WEB renders
    /// that as real formatting, and the TTS proxy strips it before speech —
    /// native was the one surface showing the raw marks. Same rules as the
    /// proxy's stripSpeechMarkdown: markers vanish, words survive. Applied
    /// in forDisplay only, so copies of what the eye/ear gets stay in sync.
    private static let mdHeaderRegex = makeRegex("^#{1,6}\\s+", caseInsensitive: false)
    private static let mdBoldRegex = makeRegex("\\*\\*([^*]+)\\*\\*")
    private static let mdUnderlineRegex = makeRegex("__([^_]+)__")
    private static let mdStrikeRegex = makeRegex("~~([^~]+)~~")
    private static let mdLinkRegex = makeRegex("\\[([^\\]]+)\\]\\(([^)]*)\\)")
    private static let mdBulletRegex = makeRegex("^\\s*[-*\u{2022}]\\s+")
    private static let mdInlineHashRunRegex = makeRegex("#{2,}")
    private static let mdInlineStarRunRegex = makeRegex("\\*{2,}")

    private static let doubledSpaceOrTabRegex = makeRegex("[ \\t]{2,}")
    private static let leadingSpaceOrTabPerLineRegex = makeRegex(
        "^[ \\t]+", extraOptions: [.anchorsMatchLines]
    )
    private static let leadingWhitespaceRegex = makeRegex("^\\s+")

    private static func makeRegex(
        _ pattern: String,
        caseInsensitive: Bool = false,
        extraOptions: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        var options = extraOptions
        if caseInsensitive { options.insert(.caseInsensitive) }
        // Every pattern above is a fixed, compile-time constant (never
        // built from server/user input), so a `try!` here can only ever
        // fail on a typo in THIS file -- caught the moment the app is
        // exercised at all (hand-review, or Codemagic's build), never as
        // a runtime condition that depends on what a message contains.
        return try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func removingMatches(
        of regex: NSRegularExpression,
        in text: String,
        replacement: String = ""
    ) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    /// Mirrors `stripVoiceTags` (voiceTags.ts) exactly, including its
    /// whitespace-cleanup pass order: collapse doubled spaces/tabs left
    /// behind by a removed inline tag, trim leading spaces/tabs at the
    /// start of every line, then trim leading whitespace/newlines from
    /// the very start of the whole string only -- a blank line in the
    /// MIDDLE of a message is a real paragraph break and stays untouched.
    static func stripVoiceTags(_ text: String) -> String {
        var result = text
        // Scene tags first (Aug 6 2026): "[[Deuce]] " -> "Deuce: " so a saved
        // scene reads as a script in the transcript and under VoiceOver.
        if result.contains("[[") {
            result = removingMatches(of: sceneTagRegex, in: result, replacement: "$1: ")
        }
        guard result.contains("%%") else { return result }
        result = removingMatches(of: voiceTagRegex, in: result)
        result = removingMatches(of: sloppyVoiceTagRegex, in: result)
        result = removingMatches(of: doubledSpaceOrTabRegex, in: result, replacement: " ")
        result = removingMatches(of: leadingSpaceOrTabPerLineRegex, in: result)
        result = removingMatches(of: leadingWhitespaceRegex, in: result)
        return result
    }

    /// Mirrors `stripGameSoundTags` (gameSounds.ts) exactly.
    static func stripGameSoundTags(_ text: String) -> String {
        guard text.contains("[sound:") || text.contains("[table:") || text.contains("[DEEP THINK") else {
            return text
        }
        var result = text
        result = removingMatches(of: gameSoundRegex, in: result)
        result = removingMatches(of: gameTableRegex, in: result)
        result = removingMatches(of: deepThinkRegex, in: result)
        result = removingMatches(of: doubledSpaceOrTabRegex, in: result, replacement: " ")
        result = removingMatches(of: leadingWhitespaceRegex, in: result)
        return result
    }

    /// Session 23: strips web-search citation anchors (see the regex doc
    /// comment above). Guarded cheaply: the overwhelming majority of
    /// messages contain neither the literal "ue20" spelling nor any
    /// U+E200-block character and skip all three regex passes.
    static func stripCitationAnchors(_ text: String) -> String {
        let hasLiteral = text.range(of: "ue20", options: .caseInsensitive) != nil
        let hasPUA = text.unicodeScalars.contains { (0xE200...0xE204).contains($0.value) }
        guard hasLiteral || hasPUA else { return text }
        var result = text
        result = removingMatches(of: literalCitationRegex, in: result)
        result = removingMatches(of: puaCitationRegex, in: result)
        result = removingMatches(of: orphanAnchorRegex, in: result)
        result = removingMatches(of: doubledSpaceOrTabRegex, in: result, replacement: " ")
        result = removingMatches(of: leadingWhitespaceRegex, in: result)
        return result
    }

    /// Aug 13 2026 — THE MEMO, and the receipts that bought it. `readableText`
    /// is a COMPUTED property, so every single access re-ran this entire
    /// chain: four strippers, roughly nine regex passes, plus a linewise
    /// split/join. `ConversationDetailView` hangs TWO `.accessibilityRotor`
    /// modifiers off the transcript, and each one filters the full message
    /// array and calls `rotorLabel(for:)` -> `readableText` on EVERY message.
    /// Those rotor bodies rebuild on every view-body evaluation, and during a
    /// live stream that is every 250ms. Amber A took FIVE 0x8BADF00D watchdog
    /// kills in 55 minutes on build 197 (bridge diagnostics ring, Aug 13
    /// 16:52–17:47Z), main thread buried up to 80 frames deep in SwiftUICore
    /// with AttributeGraph and the update cycle underneath it — a view-update
    /// storm, not a network wait. The Aug 7 fix coalesced the LIVE text flush
    /// and gated it on scene state; it never touched the rotors, which chew
    /// the whole history rather than just the growing tail.
    ///
    /// NSCache and not a Dictionary for two reasons: it is thread-safe (this
    /// is called from view bodies and from background decode alike, and a
    /// plain dictionary here would be a data race waiting to happen), and it
    /// evicts itself under memory pressure — a display cache must never be
    /// the reason iOS jetsams the app. `countLimit` is deliberately generous:
    /// a live stream burns one new key per flush as the text grows, and the
    /// history entries have to survive that churn to be worth anything. They
    /// do — the rotors touch them constantly, so they stay hot and NSCache
    /// sheds the cold streaming intermediates first.
    ///
    /// Semantics are unchanged: same input, same output, same call sites.
    /// This is purely "stop recomputing the identical answer."
    private static let displayCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 1024
        // Aug 13 review pass: a count limit alone lets 1024 ENTRIES mean
        // anything from kilobytes to tens of megabytes — live streaming
        // caches every growing snapshot of the reply, so a long essay can
        // stack hundreds of near-duplicate prefixes at full length each. A
        // cost ceiling bounds the worst case; NSCache sheds cold entries
        // first, and streaming intermediates go cold the instant the next
        // snapshot supersedes them.
        cache.totalCostLimit = 4_000_000
        return cache
    }()

    /// The one function call sites should actually use for anything a
    /// human reads or VoiceOver speaks. Mirrors the web client's own
    /// `stripGameSoundTags(stripVoiceTags(text))` call order
    /// (`Content/Parts/Text.tsx`, `MessageContent.tsx`) — plus the
    /// session-23 citation-anchor pass, which the web client doesn't need
    /// (it RENDERS those anchors as citation chips instead).
    static func forDisplay(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let key = text as NSString
        if let cached = displayCache.object(forKey: key) {
            return cached as String
        }
        let cleaned = stripMarkdownDecoration(stripCitationAnchors(stripGameSoundTags(stripVoiceTags(text))))
        displayCache.setObject(cleaned as NSString, forKey: key, cost: cleaned.utf16.count)
        return cleaned
    }

    /// See the regex block above — display twin of the proxy's speech scrub.
    /// Cheap guard first: the overwhelming majority of messages carry none
    /// of these markers and skip every pass.
    static func stripMarkdownDecoration(_ text: String) -> String {
        guard text.contains("#") || text.contains("**") || text.contains("__")
            || text.contains("~~") || text.contains("](") else { return text }
        var result = text
        result = replacingLinewise(of: mdHeaderRegex, in: result)
        result = replacingLinewise(of: mdBulletRegex, in: result)
        result = removingMatches(of: mdBoldRegex, in: result, replacement: "$1")
        result = removingMatches(of: mdUnderlineRegex, in: result, replacement: "$1")
        result = removingMatches(of: mdStrikeRegex, in: result, replacement: "$1")
        result = removingMatches(of: mdLinkRegex, in: result, replacement: "$1")
        result = removingMatches(of: mdInlineHashRunRegex, in: result)
        result = removingMatches(of: mdInlineStarRunRegex, in: result)
        result = removingMatches(of: doubledSpaceOrTabRegex, in: result, replacement: " ")
        return result
    }

    /// NSRegularExpression has no multiline-anchor default; run the
    /// line-anchored decoration rules per line so ^ means line start.
    private static func replacingLinewise(of regex: NSRegularExpression, in text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let s = String(line)
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
            }
            .joined(separator: "\n")
    }
}
