import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor final class FixtureClient {
    var defaults = ["kiana": "old voice", "forge": "forge voice"]
    var rates: [String: Double] = [:]
    var voiceless: Set<String> = []
    var prefs: [String: String] = [:]
    var delay: UInt64 = 0
    var reads = 0
    func request(path: String, method: String = "GET", authorized: Bool) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://fixture.invalid/" + path)!)
        request.httpMethod = method
        return request
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        reads += 1
        let payload: Data
        if request.httpMethod == "POST" {
            let body = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
            prefs[body["agentId"]!] = body["voice"]!.isEmpty ? nil : body["voice"]!
            payload = Data("{}".utf8)
        } else if request.url!.path.hasSuffix("voice-prefs") {
            payload = try JSONEncoder().encode(["prefs": prefs])
        } else {
            let agent = request.url!.lastPathComponent
            var tts: [String: Any] = voiceless.contains(agent) ? [:] : ["voiceId": defaults[agent] ?? "fallback"]
            if let rate = rates[agent] { tts["speakingRate"] = rate }
            payload = try JSONSerialization.data(withJSONObject: ["tts": tts])
        }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// The one VoiceCatalog call the production methods make: no renames here.
actor VoiceCatalog {
    static let shared = VoiceCatalog()
    func cachedLabel(_ stored: String) -> String { stored }
}

@MainActor final class Selection {
    let client: FixtureClient
    var voiceSelectionRevision = 0
    var agentVoiceCache: [String: (voice: String?, speed: Double?)] = [:]
    var agentTTSCache: [String: AgentTTSDetail.TTS?] = [:]
    var userVoicePrefs: [String: String]?
    struct AgentTTSDetail: Codable {
        struct TTS: Codable { let voiceId: String?; let speakingRate: Double? }
        let tts: TTS?
    }
    init(_ client: FixtureClient) { self.client = client }
    func refresh() { invalidateVoiceSelections() }
    func lookup(_ id: String) async -> String? { await resolveVoice(agentId: id, agentName: id).voice }
    func lookupSpeed(_ id: String) async -> Double? { await resolveVoice(agentId: id, agentName: id).speed }
    func fetchVoicesList() async -> [String] { ["fallback"] }
    static func hashVoice(for name: String, voices: [String]) -> String? { voices.first }
    // PRODUCTION_METHODS
}

@main struct Tests {
    @MainActor static func main() async {
        var count = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); count += 1
        }
        let client = FixtureClient()
        let selection = Selection(client)
        let original = await selection.lookup("kiana")
        check(original == "old voice", "original default")
        client.defaults["kiana"] = "new voice"
        selection.refresh()
        let replay = await selection.lookup("kiana")
        check(replay == "new voice", "replaying old text resolves current builder voice")
        let reads = client.reads
        _ = await selection.lookup("kiana")
        check(client.reads == reads, "streamed pieces reuse the resolved voice")
        client.prefs["kiana"] = "personal voice"
        selection.refresh()
        let personal = await selection.lookup("kiana")
        check(personal == "personal voice", "fresh personal choice wins over builder")
        let other = await selection.lookup("forge")
        check(other == "forge voice", "other speaker keeps their own current voice")
        await selection.setUserVoiceOverride(agentId: "kiana", voice: nil)
        let cleared = await selection.lookup("kiana")
        check(cleared == "new voice", "clearing override returns to current builder voice")
        selection.refresh()
        client.delay = 60_000_000
        let pending = Task { await selection.lookup("kiana") }
        try? await Task.sleep(nanoseconds: 20_000_000)
        client.prefs["kiana"] = "newest personal voice"
        selection.refresh()
        let raced = await pending.value
        check(raced == "newest personal voice", "stale in-flight prefs cannot repopulate refreshed cache")
        selection.refresh()
        client.delay = 0
        client.prefs = [:]
        let reset = await selection.lookup("kiana")
        check(reset == "new voice", "invalidated personal picks are not retained")
        client.rates["kiana"] = 1.3
        selection.refresh()
        let builderSpeed = await selection.lookupSpeed("kiana")
        check(builderSpeed == 1.3, "the builder's voice carries the character's speed")
        client.prefs["kiana"] = "personal voice"
        selection.refresh()
        let personalSpeed = await selection.lookupSpeed("kiana")
        check(personalSpeed == nil, "a voice the listener picked does not get the character's speed")
        client.prefs["kiana"] = "new voice"
        selection.refresh()
        let sameVoiceSpeed = await selection.lookupSpeed("kiana")
        check(sameVoiceSpeed == 1.3, "picking the builder's own voice keeps the character's speed")
        client.prefs = [:]
        client.voiceless = ["kiana"]
        selection.refresh()
        let hashedVoice = await selection.lookup("kiana")
        check(hashedVoice == "fallback", "a character with no builder voice gets the fallback voice")
        let hashedSpeed = await selection.lookupSpeed("kiana")
        check(hashedSpeed == nil, "the fallback voice does not get the character's speed")
        client.prefs["kiana"] = "personal voice"
        selection.refresh()
        let voicelessPickSpeed = await selection.lookupSpeed("kiana")
        check(voicelessPickSpeed == nil, "a listener's voice on a voice-less character does not get its speed")
        print("Voice selection: \(count) checks passed using production methods; no audio requested.")
    }
}
