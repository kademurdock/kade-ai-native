import SwiftUI

/// Build 193 — MORNING BRIEF, native (the web /brief page's twin; server
/// half shipped Aug 9 2026: fork e082c54 + bridge 0149c64). Per-account by
/// construction — the fork's /api/brief lane hard-binds every call to the
/// signed-in JWT, so this screen can only ever see or change its own
/// person's brief. The bridge owns schedules and composition; this is a
/// settings-and-reader surface.
///
/// Read-or-listen, answered the same way the web answered it: TODAY'S BRIEF
/// is plain text VoiceOver reads natively, and LISTEN speaks it through the
/// same voice pipeline every chat reply uses. The push that delivers the
/// brief each morning carries the KADE_BRIEF category (bridge 3c0f2c0), so
/// its LISTEN/READ action buttons land HERE with `autoListen` set — tap
/// Listen on the lock screen, the app opens already talking.

// MARK: - Server shapes (GET/POST /api/brief — lenient throughout)

struct BriefItems: Decodable, Hashable {
    var weather: Bool
    var news: Bool
    var dayAhead: Bool

    private enum Keys: String, CodingKey { case weather, news, dayAhead }
    init(weather: Bool = true, news: Bool = true, dayAhead: Bool = true) {
        self.weather = weather; self.news = news; self.dayAhead = dayAhead
    }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: Keys.self)
        self.weather = (try? c?.decode(Bool.self, forKey: .weather)) ?? true
        self.news = (try? c?.decode(Bool.self, forKey: .news)) ?? true
        self.dayAhead = (try? c?.decode(Bool.self, forKey: .dayAhead)) ?? true
    }
}

struct BriefLast: Decodable, Hashable {
    let text: String
    let at: String?
    private enum Keys: String, CodingKey { case text, at }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.text = (try? c.decode(String.self, forKey: .text)) ?? ""
        self.at = try? c.decode(String.self, forKey: .at)
    }
}

private struct BriefPrefsWire: Decodable {
    struct Prefs: Decodable {
        let enabled: Bool?
        let time: String?
        let items: BriefItems?
        let location: String?
    }
    let prefs: Prefs?
    let linked: Bool?
    let lastBrief: BriefLast?
}

// MARK: - Screen

struct BriefView: View {
    let apiClient: KadeAPIClient
    /// True when a lock-screen LISTEN action opened this screen — the brief
    /// starts speaking the moment it loads, no second tap asked of anyone.
    var autoListen: Bool = false

    @EnvironmentObject private var voiceService: VoiceService

    @State private var enabled = false
    @State private var time = Date()
    @State private var items = BriefItems()
    @State private var location = ""
    @State private var linked = true
    @State private var lastBrief: BriefLast?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var statusLine: String?
    @State private var firing = false
    @State private var speaking = false
    /// Saves are debounced-on-change rather than gated behind a Save button
    /// — same reasoning as the rest of Settings: a blind-first settings
    /// screen shouldn't hide a required second step at the bottom.
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        List {
            if isLoading {
                Section { Text("Fetching your brief…").foregroundStyle(.secondary) }
            } else if let loadError {
                Section {
                    Text(loadError)
                    Button("Try again") { Task { await load() } }
                }
            } else {
                if let lastBrief, !lastBrief.text.isEmpty {
                    Section {
                        Text(lastBrief.text)
                            .font(.body)
                        Button {
                            toggleListen()
                        } label: {
                            Label(speaking ? "Stop" : "Listen", systemImage: speaking ? "stop.circle" : "play.circle")
                        }
                        .accessibilityHint("Reads today's brief aloud in your companion's voice.")
                    } header: {
                        Text("Today's brief")
                    }
                }

                Section {
                    Toggle("Morning brief on", isOn: $enabled)
                        .onChange(of: enabled) { _, _ in queueSave() }
                        .accessibilityHint("When on, your companion sends a brief to this phone every morning at the time below.")
                    DatePicker("Delivery time", selection: $time, displayedComponents: .hourAndMinute)
                        .onChange(of: time) { _, _ in queueSave() }
                        .accessibilityHint("What time each morning the brief arrives.")
                    if !linked {
                        Text("Heads up: no phone is linked for pushes on this account yet — open the app once signed in (this counts) and the next brief can land.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Schedule")
                }

                Section {
                    Toggle("Weather", isOn: $items.weather)
                        .onChange(of: items.weather) { _, _ in queueSave() }
                    Toggle("A little news", isOn: $items.news)
                        .onChange(of: items.news) { _, _ in queueSave() }
                    Toggle("Your day ahead", isOn: $items.dayAhead)
                        .onChange(of: items.dayAhead) { _, _ in queueSave() }
                        .accessibilityHint("Pulls from your own notes and reminders — nothing anyone else can see.")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your town").font(.subheadline)
                        TextField("Town for weather", text: $location)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { queueSave() }
                            .accessibilityLabel("Your town, for the weather")
                    }
                } header: {
                    Text("What's in it")
                } footer: {
                    Text("Your companion writes it fresh each morning from what you've checked here.")
                }

                Section {
                    Button {
                        Task { await fireTest() }
                    } label: {
                        Label(firing ? "Sending…" : "Send one right now", systemImage: "paperplane")
                    }
                    .accessibilityHint("Fires a test brief to this phone so you can hear exactly what mornings will sound like.")
                }

                if let statusLine {
                    Section { Text(statusLine).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("Morning Brief")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
            if autoListen { toggleListen() }
        }
        .onDisappear {
            saveTask?.cancel()
            Task { await save() } // whatever's pending lands before the screen goes
        }
    }

    private func toggleListen() {
        if speaking {
            voiceService.stopSpeaking() // the gentle stop — reset() is the sign-out hammer
            speaking = false
            return
        }
        guard let text = lastBrief?.text, !text.isEmpty else { return }
        speaking = true
        Task {
            await voiceService.speakLine(text: text, voiceId: nil, rate: nil)
            speaking = false
        }
    }

    private func fireTest() async {
        guard !firing else { return }
        firing = true
        defer { firing = false }
        await save() // the test should reflect what's on screen, not what was
        var req = apiClient.request(path: "api/brief/fire", method: "POST", authorized: true, timeout: 90)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        do {
            let (_, http) = try await apiClient.send(req)
            statusLine = http.statusCode == 200
                ? "Sent — check your notifications, and Today's brief refreshes below."
                : "The brief service didn't answer just now — try again in a moment."
        } catch {
            statusLine = "Couldn't fire it just now — try again in a moment."
        }
        await load()
    }

    /// Bridge schedule times run on the family's home clock (Central) —
    /// which is also this phone's clock in every real case, so the local
    /// hour-minute is the honest representation both directions.
    private static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func queueSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        var req = apiClient.request(path: "api/brief", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "enabled": enabled,
            "time": Self.hhmm.string(from: time),
            "items": ["weather": items.weather, "news": items.news, "dayAhead": items.dayAhead],
            "location": location,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await apiClient.send(req)
    }

    private func load() async {
        isLoading = lastBrief == nil && loadError == nil && !enabled
        loadError = nil
        let req = apiClient.request(path: "api/brief", authorized: true)
        do {
            let (data, http) = try await apiClient.send(req)
            guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
            let wire = try JSONDecoder().decode(BriefPrefsWire.self, from: data)
            enabled = wire.prefs?.enabled ?? false
            if let t = wire.prefs?.time, let parsed = Self.hhmm.date(from: t) {
                // Re-anchor the parsed HH:mm onto today so the DatePicker
                // shows the right hands without caring what day 1970 was.
                let comps = Calendar.current.dateComponents([.hour, .minute], from: parsed)
                time = Calendar.current.date(bySettingHour: comps.hour ?? 8, minute: comps.minute ?? 0, second: 0, of: Date()) ?? Date()
            }
            items = wire.prefs?.items ?? BriefItems()
            location = wire.prefs?.location ?? ""
            linked = wire.linked ?? true
            lastBrief = wire.lastBrief
        } catch {
            loadError = "Couldn't reach the brief service. Check the connection and try again."
        }
        isLoading = false
    }
}
