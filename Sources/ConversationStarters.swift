import Foundation

/// A new conversation owns one seed. Selecting from the saved public pool is
/// local and stable through rendering, typing and returning from a sheet.
enum ConversationStarters {
    static let maximumPoolSize = 24
    static let visibleCount = 4
    static let fallback = [
        "What's a small thing you have a surprisingly strong opinion about?",
        "Give me a strange little question we could argue about for fun.",
        "What's something you changed your mind about?",
        "Invent a place we'd want to spend a rainy afternoon.",
        "What ordinary thing deserves a much better reputation?",
        "Help me untangle something that's been on my mind.",
        "Pick a harmless hill to die on. I'll take the other side.",
        "Let's make up a story one ridiculous detail at a time."
    ]

    static func clean(_ pool: [String]) -> [String] {
        var seen = Set<String>()
        return pool.compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, seen.insert(line.lowercased()).inserted else { return nil }
            return line
        }.prefix(maximumPoolSize).map { $0 }
    }

    static func select(pool: [String]?, characterId: String, seed: String) -> [String] {
        // An explicit empty array is the author's choice to hide starters.
        let candidates = pool.map { clean($0) } ?? fallback
        return candidates.enumerated().sorted { left, right in
            let leftRank = rank(seed + "\u{1f}" + characterId + "\u{1f}" + left.element)
            let rightRank = rank(seed + "\u{1f}" + characterId + "\u{1f}" + right.element)
            return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
        }.prefix(visibleCount).map { $0.element }
    }

    /// Swift's Hasher changes each process; a fixed hash keeps one seed stable.
    private static func rank(_ text: String) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 1_099_511_628_211
        }
        return value
    }
}
