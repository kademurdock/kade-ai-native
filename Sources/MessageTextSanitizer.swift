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
        guard text.contains("%%") else { return text }
        var result = text
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

    /// The one function call sites should actually use for anything a
    /// human reads or VoiceOver speaks. Mirrors the web client's own
    /// `stripGameSoundTags(stripVoiceTags(text))` call order
    /// (`Content/Parts/Text.tsx`, `MessageContent.tsx`).
    static func forDisplay(_ text: String) -> String {
        stripGameSoundTags(stripVoiceTags(text))
    }
}
