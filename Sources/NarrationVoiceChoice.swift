import Foundation

/// Visibility in a picker must never silently change a saved video's narrator.
enum NarrationVoiceChoice {
    static func retaining(_ stored: String?, fallback: String?, choices: [String]) -> String {
        if let stored, !stored.isEmpty { return stored }
        if let fallback, !fallback.isEmpty { return fallback }
        return choices.first ?? ""
    }

    static func isKnown(_ voice: String, choices: [String], retained: [String]) -> Bool {
        choices.contains(voice) || retained.contains(voice)
    }
}
