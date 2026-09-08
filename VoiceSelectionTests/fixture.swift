import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor final class FixtureClient {
    var defaults = ["kiana": "old voice", "forge": "forge voice"]
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
            payload = try JSONEncoder().encode(["tts": ["voiceId": defaults[request.url!.lastPathComponent] ?? "fallback"]])
        }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return (payload, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor final class Selection {
    let client: FixtureClient
    var voiceSelectionRevision = 0
    var agentVoiceCache: [String: (voice: String?, speed: Double?)] = [:]
    var userVoicePrefs: [String: String]?
    struct AgentTTSDetail: Codable {
        struct TTS: Codable { let voiceId: String?; let speakingRate: Double? }
        let tts: TTS?
    }
    init(_ client: FixtureClient) { self.client = client }
    func refresh() { invalidateVoiceSelections() }
    func lookup(_ id: String) async -> String? { await resolveVoice(agentId: id, agentName: id).voice }
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
        print("Voice selection: \(count) checks passed using production methods; no audio requested.")
    }
}
