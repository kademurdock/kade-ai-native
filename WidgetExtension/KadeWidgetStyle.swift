import SwiftUI

/// Sep 23 2026 redesign (C2, C3): the widget extension's colours, taken from
/// the app icon. Dark warm brown (#2E2116, the launch screen's colour) rising
/// into the icon's amber, with the K's cream for text.
///
/// Contrast, measured: cream on the brown is 12.4:1 and on the deep amber
/// 5.3:1; brown on the glow (the Talk pill) is 9.9:1. The icon's own bright
/// amber (#996E3A) only reaches 3.6:1 under cream, which is why the gradient
/// tops out at a deeper amber and text sits on the darker end or on a scrim.
enum KadeWidgetPalette {
    /// #2E2116, the icon and launch screen brown.
    static let brown = Color(red: 46.0 / 255.0, green: 33.0 / 255.0, blue: 22.0 / 255.0)
    /// #7A5530, a deeper take on the icon's amber that still carries cream text.
    static let amber = Color(red: 122.0 / 255.0, green: 85.0 / 255.0, blue: 48.0 / 255.0)
    /// #FBE3C3, the K's cream: every line of text on brown or amber.
    static let cream = Color(red: 251.0 / 255.0, green: 227.0 / 255.0, blue: 195.0 / 255.0)
    /// #F7C585, the bright end of the K: the Talk pill and running jobs.
    static let glow = Color(red: 247.0 / 255.0, green: 197.0 / 255.0, blue: 133.0 / 255.0)
    /// #8FE3A0, "Ready" on the brown card (10.1:1).
    static let ready = Color(red: 143.0 / 255.0, green: 227.0 / 255.0, blue: 160.0 / 255.0)
    /// #FF8A80, "Failed" on the brown card (6.8:1).
    static let failed = Color(red: 255.0 / 255.0, green: 138.0 / 255.0, blue: 128.0 / 255.0)

    /// The widget's container background: amber at the top, brown at the foot.
    static var background: LinearGradient {
        LinearGradient(colors: [amber, brown], startPoint: .top, endPoint: .bottom)
    }
}

/// Every place the extension sends a tap. The app side of each is the
/// integrator's (ContentView's `.onOpenURL`, which routes on `url.host`).
/// OpenSpotterIntent.swift spells its own URL on purpose, so that file can be
/// compiled into the app target on its own.
enum KadeWidgetLinks {
    /// kadeai://library/continue: pick up the Library where you left off.
    static let continueListening = URL(string: "kadeai://library/continue")!
    /// kadeai://jobs?kind=song: the Live Activity card and its Dynamic
    /// Island. The kind lets the app open the right room (the Sound Booth for
    /// a song or scene, the Library for an upload).
    static func jobs(kind: String) -> URL {
        var parts = URLComponents()
        parts.scheme = "kadeai"
        parts.host = "jobs"
        parts.queryItems = [URLQueryItem(name: "kind", value: kind)]
        return parts.url ?? URL(string: "kadeai://jobs")!
    }

    /// kadeai://talk?agent=<id>: a new chat with that character. The four ids
    /// are fixed constants made of letters, digits, "-" and "_", all of which
    /// are legal in a query, so the URL always forms.
    static func talk(agentID: String) -> URL {
        URL(string: "kadeai://talk?agent=\(agentID)")!
    }
}
