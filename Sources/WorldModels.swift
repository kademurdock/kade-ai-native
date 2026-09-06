import Foundation

struct WorldAction: Decodable, Equatable, Identifiable {
    let label: String
    let cmd: String
    let group: String?
    let hint: String?
    var id: String { cmd }
}

struct WorldExit: Decodable, Equatable, Identifiable {
    let dir: String
    let label: String
    let to: String
    let locked: Bool?
    var id: String { dir }
    var command: String { "go \(dir)" }
    var spokenLabel: String { "\(label.capitalized) to \(to)\(locked == true ? ", locked" : "")" }
}

struct WorldPerson: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let kind: String
    let line: String?
    let cmds: [WorldAction]?
}

struct WorldHUD: Decodable, Equatable {
    struct Meter: Decodable, Equatable, Identifiable {
        let key: String
        let value: Double
        let word: String
        var id: String { key }
        var spokenValue: String { "\(Int(value)) out of 100, \(word)" }
    }
    let name: String?
    let coin: Int?
    let clock: String?
    let ward: String?
    let mood: String?
    let hint: String?
    let home: String?
    let partner: String?
    let meters: [Meter]?
}

struct WorldEvent: Decodable, Equatable {
    let seq: Int?
    let kind: String?
    let text: String
    let sound: String?
}

struct WorldStreamUpdate: Decodable {
    let cursor: Int?
    let events: [WorldEvent]?
    let end: String?
}

enum WorldSoundIdentity {
    static func cacheIdentity(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        let kept = (parts.queryItems ?? []).filter { item in
            let key = item.name.lowercased()
            return !key.hasPrefix("x-amz-") && !["awsaccesskeyid", "signature", "expires"].contains(key)
        }.sorted { $0.name == $1.name ? ($0.value ?? "") < ($1.value ?? "") : $0.name < $1.name }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.string ?? url.absoluteString
    }
}
