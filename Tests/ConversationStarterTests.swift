import Foundation

var checks = 0
func check(_ passed: Bool, _ message: String) {
    checks += 1
    if !passed { fatalError(message) }
}

let pool = (1...24).map { "Let's talk about topic \($0)." }
let first = ConversationStarters.select(pool: pool, characterId: "synthetic-character", seed: "new-chat-a")
check(first.count == 4 && Set(first).count == 4, "four distinct authored starters")
check(first.allSatisfy(pool.contains), "selection stays within the character's public authored pool")
for _ in 0..<20 {
    check(ConversationStarters.select(pool: pool, characterId: "synthetic-character", seed: "new-chat-a") == first,
          "rendering and keyboard changes do not reshuffle one conversation")
}
let selections = (0..<32).map {
    ConversationStarters.select(pool: pool, characterId: "synthetic-character", seed: "new-chat-\($0)").joined(separator: "\n")
}
check(Set(selections).count > 8, "new conversation seeds vary the visible starters")
let characters = (0..<12).map {
    ConversationStarters.select(pool: pool, characterId: "character-\($0)", seed: "same-chat").joined(separator: "\n")
}
check(Set(characters).count > 1, "changing character also changes the selection")
check(ConversationStarters.clean(["", "  ", " Hello ", "hello", "Another\n"]) == ["Hello", "Another"],
      "blank and duplicate rows cannot make repeated or empty controls")
check(ConversationStarters.clean((1...50).map { "Row \($0)" }).count == 24, "oversized pools stay bounded")
check(ConversationStarters.select(pool: ["Only my authored line"], characterId: "one", seed: "a") == ["Only my authored line"],
      "short custom pools are respected without unrelated fillers")
check(ConversationStarters.select(pool: [], characterId: "empty", seed: "a").isEmpty,
      "an author's explicit empty array disables starters")
check(ConversationStarters.select(pool: [" "], characterId: "blank", seed: "a").isEmpty,
      "an authored blank pool does not invent replacement starters")
let absent = ConversationStarters.select(pool: nil, characterId: "legacy", seed: "a")
check(absent.count == 4 && absent.allSatisfy(ConversationStarters.fallback.contains), "old records without a field have usable fallbacks")
let multilingual = ["¿Qué opinas?", "話そう", "Un café?", "Tell me about 🐙."]
check(Set(ConversationStarters.select(pool: multilingual, characterId: "unicode", seed: "a")) == Set(multilingual),
      "unicode starter text is preserved")
print("Conversation starters: \(checks) checks passed")
