import Foundation

let choices = ["Clear warm voice · cedarbrook", "Bright voice · silversky"]
precondition(NarrationVoiceChoice.retaining("Voice 1", fallback: choices[0], choices: choices) == "Voice 1")
precondition(NarrationVoiceChoice.retaining("Old Fish voice", fallback: choices[0], choices: []) == "Old Fish voice")
precondition(NarrationVoiceChoice.retaining(nil, fallback: "Voice 1", choices: choices) == "Voice 1")
precondition(NarrationVoiceChoice.retaining(nil, fallback: nil, choices: choices) == choices[0])
precondition(NarrationVoiceChoice.isKnown("Voice 1", choices: choices, retained: ["Voice 1"]))
precondition(!NarrationVoiceChoice.isKnown("Unknown", choices: choices, retained: ["Voice 1"]))
precondition(choices == ["Clear warm voice · cedarbrook", "Bright voice · silversky"])
print("Narration voice retention: 7 checks passed")

let currentCatalog = VoiceCatalog.Snapshot(
    categories: [
        .init(name: "Women, Warm & Soothing", voices: [choices[0]]),
        .init(name: "Men, Clear & Neutral", voices: [choices[1]]),
        .init(name: "Kids and teens, Bright & Lively", voices: ["Young voice"]),
        .init(name: "Characters, Characters & Distinctive", voices: ["Character voice"])
    ], renames: [:], describe: [:], tags: [:]
)
let previousCatalog = VoiceCatalog.Snapshot(
    categories: [.init(name: "Women, Warm & Soothing", voices: ["Old Fish voice"])],
    renames: [:], describe: [:], tags: [:]
)
precondition(!previousCatalog.hasCategories(matching: choices))
precondition(currentCatalog.hasCategories(matching: choices))
precondition(currentCatalog.hasCategories(matching: [choices[1]]))
precondition(!currentCatalog.hasCategories(matching: []))

actor CatalogFetches {
    private var count = 0
    private let values: [VoiceCatalog.Snapshot]
    init(_ values: [VoiceCatalog.Snapshot]) { self.values = values }
    func next() -> VoiceCatalog.Snapshot {
        let value = values[min(count, values.count - 1)]
        count += 1
        return value
    }
    func total() -> Int { count }
}
let fetches = CatalogFetches([previousCatalog, currentCatalog])
let cache = VoiceCatalog(fetchSnapshot: { await fetches.next() })
let before = await cache.snapshot()
precondition(before.categories == previousCatalog.categories)
let refreshed = await cache.snapshot(matching: choices)
precondition(refreshed.categories == currentCatalog.categories)
let afterRefresh = await fetches.total()
precondition(afterRefresh == 2)
let kept = await cache.snapshot(matching: choices)
precondition(kept.categories == currentCatalog.categories)
let afterCacheHit = await fetches.total()
precondition(afterCacheHit == 2)
let emptyFetches = CatalogFetches([.empty, currentCatalog])
let recovering = VoiceCatalog(fetchSnapshot: { await emptyFetches.next() })
let recovered = await recovering.snapshot(matching: choices)
precondition(recovered.categories == currentCatalog.categories)
let failureFetches = CatalogFetches([.empty])
let unavailable = VoiceCatalog(fetchSnapshot: { await failureFetches.next() })
let fallback = await unavailable.snapshot(matching: choices)
precondition(fallback.isEmpty)
let attempts = await failureFetches.total()
precondition(attempts == 2)
print("Voice catalog replacement and recovery: 12 checks passed")

// Oct 16 2026: speech reads only what is already cached and never retries a
// failed catalog on every sentence; a failed picker refresh keeps the old one.
let speechFetches = CatalogFetches([.empty, currentCatalog])
let speechCatalog = VoiceCatalog(fetchSnapshot: { await speechFetches.next() })
let coldProviders = await speechCatalog.cachedProviders()
precondition(coldProviders == nil)
_ = await speechCatalog.snapshot()
await speechCatalog.prefetch()
let speechAttempts = await speechFetches.total()
precondition(speechAttempts == 1)
let providerCatalog = VoiceCatalog.Snapshot(categories: currentCatalog.categories, renames: [:],
    describe: [:], tags: [:], providers: ["Cedar (Classic)": "inworld"])
let warmCatalog = VoiceCatalog(fetchSnapshot: { providerCatalog })
_ = await warmCatalog.snapshot()
let warmProviders = await warmCatalog.cachedProviders()
precondition(warmProviders?["Cedar (Classic)"] == "inworld")
let flakyFetches = CatalogFetches([previousCatalog, .empty])
let keepingCatalog = VoiceCatalog(fetchSnapshot: { await flakyFetches.next() })
let keptOld = await keepingCatalog.snapshot(matching: choices)
precondition(keptOld.categories == previousCatalog.categories)
let keptAgain = await keepingCatalog.snapshot()
precondition(keptAgain.categories == previousCatalog.categories)
print("Voice catalog speech cache and failed refresh: 5 checks passed")
