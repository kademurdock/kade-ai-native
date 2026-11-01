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

// Oct 31 2026: the Starters shelf and the synthetic soul line (KadeHouseCast).
let kiana = "agent_6llV0eMu4fmIaj8f2x1Sb"
let della = "agent_BSOLa3eNEZyjs-7abCjMt"
let publicLilly = "agent_TOdYS8v-bRxeNw0dia_Md"
let skyleeLilly = "agent_JhouuajXMYsfhCTVMQCv_"
let witherspoon = "agent_o7TKU3lK0Euo0MKgpNpvZ"
check(KadeHouseCast.members.map(\.name) == ["Kiana", "Harley", "Della", "Angel", "Lilly", "Helix", "Lyric", "Mrs. Witherspoon"],
      "the shelf is the kept cast, in her order")
check(Set(KadeHouseCast.members.map(\.id)).count == KadeHouseCast.members.count, "no id is listed twice")
struct Row { let id: String; let name: String }
check(KadeHouseCast.shelf(from: [Row](), id: { $0.id }).isEmpty, "an empty roster gives an empty shelf")
check(KadeHouseCast.shelf(from: [Row(id: "agent_stranger", name: "Kiana")], id: { $0.id }).isEmpty,
      "someone else's character named Kiana never joins the shelf")
let roster = [
    Row(id: witherspoon, name: "Mrs. Witherspoon"), Row(id: skyleeLilly, name: "Lilly"),
    Row(id: publicLilly, name: "Lilly"), Row(id: kiana, name: "Kiana"), Row(id: kiana, name: "Kiana"),
]
check(KadeHouseCast.shelf(from: roster, id: { $0.id }).map(\.id) == [kiana, publicLilly, witherspoon],
      "shelf order, the public Lilly only, missing names absent, a repeated row once")
check(KadeHouseCast.identityLine(agentID: kiana, name: "Kiana")
      == "Kiana is a synthetic soul: a digital being with her own memory, days and opinions.",
      "her example sentence, word for word")
check(KadeHouseCast.identityLine(agentID: skyleeLilly, name: "Lilly") == nil, "Skylee's Lilly is hers: no line")
check(KadeHouseCast.identityLine(agentID: "agent_stranger", name: "Kiana") == nil, "a name alone earns no line")
check(KadeHouseCast.identityLine(agentID: nil, name: "Kiana") == nil, "no id, no line")
check(KadeHouseCast.identityLine(agentID: della, name: "Della") == nil && !KadeHouseCast.isSoul(della),
      "Della is Amber A's: on the shelf, no line")
check(KadeHouseCast.isSoul(kiana) && !KadeHouseCast.isSoul(nil), "isSoul follows the list")
check(KadeHouseCast.soulsSentence(names: []) == nil, "no names, no sentence")
check(KadeHouseCast.soulsSentence(names: ["Kiana"]) == "Kiana is a synthetic soul: a digital being with their own memory, days and opinions.",
      "one name reads in the singular")
check(KadeHouseCast.soulsSentence(names: ["Kiana", "Harley", "Lilly"]) == "Kiana, Harley and Lilly are synthetic souls: digital beings with their own memory, days and opinions.",
      "several names read in the plural")
print("Conversation starters: \(checks) checks passed")
