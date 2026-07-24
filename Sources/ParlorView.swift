import SwiftUI
import UIKit

/// THE PARLOR, native (July 24 2026 — her ask the same night the web page
/// shipped: "Can you make that native? Like part of the native game
/// parler?"). Same /api/kade/parlor routes, same tables as chat/phone/web:
/// menu of all the games, options you set yourself, optional character
/// seats, YOUR moves as real buttons, a house narrator in Kade's or Miss
/// A's clone voices, table talk, and a shareable transcript.
///
/// One VIEW, three phases (menu → setup → table) swapped in place — no
/// navigationDestination types added to the stack (the build-121 collision
/// class), no more than one sheet in the file (the seats picker).
struct ParlorView: View {
    let apiClient: KadeAPIClient

    @StateObject private var service: ParlorService
    @StateObject private var narrator: ParlorNarrator
    @StateObject private var roomService: RoomService

    private enum Phase {
        case menu
        case setup
        case table
    }

    @State private var phase: Phase = .menu
    @State private var statusLine = "Loading the Parlor…"
    @State private var loadFailed = false

    // Menu
    @State private var games: [ParlorService.ParlorGame] = []
    @State private var openTables: [ParlorService.OpenTable] = []

    // Setup
    @State private var chosen: ParlorService.ParlorGame?
    @State private var optOpponents = 1
    @State private var optRounds = 5
    @State private var optDifficulty = ""
    @State private var optCategory = ""
    @State private var optBet = 10
    @State private var optClean = false
    @State private var seats: [String] = []
    @State private var showingSeatPicker = false
    @State private var seatFilter = ""
    @State private var roster: [RoomCastAgent] = []
    @State private var narratorPick = "Voice 466"
    @State private var narratorCustom = ""
    @State private var narratorMode: ParlorNarrator.Mode = .events

    // Table
    @State private var table: ParlorService.Table?
    @State private var lastNews = ""
    @State private var talkText = ""
    @State private var talkLog: [String] = []
    @State private var transcriptText: String?
    @State private var busy = false

    private static let narratorVoices: [(String, String)] = [
        ("Voice 466", "Kade Candid"),
        ("Voice 464", "Kade conversational"),
        ("Voice 327", "Kade calm and casual"),
        ("Voice 424", "Kade's child impression"),
        ("Voice 385", "Miss A Irish"),
        ("Voice 391", "Miss A animated"),
        ("Voice 393", "Miss A pro reading"),
        ("Voice 463", "Miss A casual"),
    ]

    init(apiClient: KadeAPIClient) {
        self.apiClient = apiClient
        _service = StateObject(wrappedValue: ParlorService(client: apiClient))
        _narrator = StateObject(wrappedValue: ParlorNarrator(client: apiClient))
        _roomService = StateObject(wrappedValue: RoomService(client: apiClient))
    }

    var body: some View {
        Group {
            switch phase {
            case .menu: menuScreen
            case .setup: setupScreen
            case .table: tableScreen
            }
        }
        .navigationTitle("The Parlor")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadMenu() }
        .onDisappear { narrator.stop() }
    }

    // MARK: - Menu

    private var menuScreen: some View {
        List {
            Section {
                Text("Every game on a menu. Pick one, set the table your way, and play your own cards — characters are optional company, never the referee.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !openTables.isEmpty {
                Section("Your open tables") {
                    ForEach(openTables) { t in
                        Button {
                            Task { await resume(t.gameId) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Resume \(t.name)")
                                Text("Table \(t.gameId) — \(t.turns) turns in")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel("Resume \(t.name), table \(t.gameId), \(t.turns) turns in")
                        .accessibilityHint("Puts you right back at this table.")
                    }
                }
            }
            Section("Deal something new") {
                if loadFailed {
                    Button("Couldn't load the menu — try again") { Task { await loadMenu() } }
                } else {
                    ForEach(games) { g in
                        Button {
                            openSetup(g)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(g.name)
                                Text("\(g.blurb) (\(g.players) player\(g.players == "1" ? "" : "s")\(g.seatAware ? " — characters can sit in" : ""))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel(g.name)
                        .accessibilityHint("\(g.blurb) \(g.seatAware ? "Characters can sit in." : "")")
                    }
                }
            }
        }
    }

    private func loadMenu() async {
        narrator.stop()
        loadFailed = false
        openTables = await service.openTables()
        if games.isEmpty {
            do {
                games = try await service.games()
            } catch {
                loadFailed = true
            }
        }
        statusLine = "Pick a game from the menu."
    }

    // MARK: - Setup

    private func openSetup(_ g: ParlorService.ParlorGame) {
        chosen = g
        seats = []
        if let o = g.options?.opponents, o.count == 3 { optOpponents = o[2] }
        if let r = g.options?.rounds, r.count == 3 { optRounds = r[2] }
        optDifficulty = ""
        optCategory = ""
        if let b = g.options?.bet, b.count == 3 { optBet = b[2] }
        optClean = false
        phase = .setup
        UIAccessibility.post(notification: .screenChanged, argument: "Set the table — \(g.name).")
    }

    private var setupScreen: some View {
        Form {
            Section {
                Text(chosen?.blurb ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text(chosen?.name ?? "Set the table")
            }

            if let o = chosen?.options {
                Section("The table") {
                    if chosen?.seatAware == true {
                        Button {
                            showingSeatPicker = true
                        } label: {
                            Text(seats.isEmpty ? "Seat characters (optional, up to 3)" : "Seated: \(seats.joined(separator: ", "))")
                        }
                        .accessibilityHint("Their real personalities play their own hands and talk at the table.")
                    }
                    if seats.isEmpty, let opp = o.opponents, opp.count == 3 {
                        Picker("House players", selection: $optOpponents) {
                            ForEach(opp[0]...opp[1], id: \.self) { n in
                                Text(n == 0 ? "Just me" : "\(n)").tag(n)
                            }
                        }
                    }
                    if let r = o.rounds, r.count == 3 {
                        Picker("Length", selection: $optRounds) {
                            ForEach(r[0]...r[1], id: \.self) { n in Text("\(n)").tag(n) }
                        }
                    }
                    if let d = o.difficulty, !d.isEmpty {
                        Picker("Difficulty", selection: $optDifficulty) {
                            Text("Mixed").tag("")
                            ForEach(d, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                    }
                    if let c = o.category, !c.isEmpty {
                        Picker("Topic", selection: $optCategory) {
                            Text("Any topic").tag("")
                            ForEach(c, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) }
                        }
                    }
                    if let b = o.bet, b.count == 3 {
                        Stepper("Chip bet: \(optBet)", value: $optBet, in: b[0]...b[1], step: 5)
                    }
                    if o.clean == true {
                        Toggle("Family-clean deck", isOn: $optClean)
                    }
                }
            }

            Section("The house narrator") {
                Picker("Voice", selection: $narratorPick) {
                    ForEach(Self.narratorVoices, id: \.0) { v in
                        Text(v.1).tag(v.0)
                    }
                    Text("Another voice by number").tag("__custom")
                }
                if narratorPick == "__custom" {
                    TextField("Voice label, like Voice 52", text: $narratorCustom)
                        .textInputAutocapitalization(.words)
                }
                Picker("Narrator speaks", selection: $narratorMode) {
                    ForEach(ParlorNarrator.Mode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
            }

            Section {
                Button {
                    Task { await deal() }
                } label: {
                    Text(busy ? "Dealing…" : "Deal the table")
                        .frame(maxWidth: .infinity)
                        .font(.body.weight(.semibold))
                }
                .accessibilityHint("Deals the cards and opens your table.")
                Button("Back to the menu") {
                    phase = .menu
                }
            }
        }
        .sheet(isPresented: $showingSeatPicker) {
            seatPickerSheet
        }
    }

    private var seatPickerSheet: some View {
        NavigationStack {
            List {
                if !seats.isEmpty {
                    Section("Seated (\(seats.count) of 3)") {
                        ForEach(seats, id: \.self) { name in
                            Button("Remove \(name)") {
                                seats.removeAll { $0 == name }
                            }
                        }
                    }
                }
                Section("Characters") {
                    ForEach(filteredRoster, id: \.id) { a in
                        Button {
                            toggleSeat(a.name)
                        } label: {
                            HStack {
                                Text(a.name)
                                if seats.contains(a.name) {
                                    Spacer()
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityLabel(a.name)
                        .accessibilityValue(seats.contains(a.name) ? "Seated" : "")
                        .accessibilityHint("Seats or unseats this character.")
                    }
                }
            }
            .searchable(text: $seatFilter, prompt: "Search characters")
            .navigationTitle("Seat characters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingSeatPicker = false }
                }
            }
            .task {
                if roster.isEmpty {
                    roster = await roomService.loadCastableAgents()
                }
            }
        }
    }

    private var filteredRoster: [RoomCastAgent] {
        let q = seatFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return roster }
        return roster.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private func toggleSeat(_ name: String) {
        if seats.contains(name) {
            seats.removeAll { $0 == name }
        } else if seats.count < 3 {
            seats.append(name)
        } else {
            UIAccessibility.post(notification: .announcement, argument: "Three seats is the table limit — remove someone first.")
        }
    }

    private func deal() async {
        guard let g = chosen, !busy else { return }
        busy = true
        defer { busy = false }
        narrator.voice = narratorPick == "__custom"
            ? (narratorCustom.trimmingCharacters(in: .whitespaces).isEmpty ? "Voice 466" : narratorCustom.trimmingCharacters(in: .whitespaces))
            : narratorPick
        narrator.mode = narratorMode
        var reqBody = ParlorService.NewTableRequest(game: g.key)
        if g.seatAware && !seats.isEmpty { reqBody.agentSeats = seats }
        else if g.options?.opponents != nil { reqBody.opponents = optOpponents }
        if g.options?.rounds != nil { reqBody.rounds = optRounds }
        if g.options?.difficulty != nil { reqBody.difficulty = optDifficulty }
        if g.options?.category != nil { reqBody.category = optCategory }
        if g.options?.bet != nil { reqBody.bet = optBet }
        if g.options?.clean == true { reqBody.clean = optClean }
        do {
            let t = try await service.newTable(reqBody)
            talkLog = []
            transcriptText = nil
            narrator.say("New table. \(g.name).")
            applyTable(t, announcePrefix: "Table dealt.")
        } catch {
            statusLine = error.localizedDescription
            UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
        }
    }

    // MARK: - Table

    private var tableScreen: some View {
        List {
            Section {
                Text(lastNews.isEmpty ? "Your table is ready." : lastNews)
                    .font(.callout)
            } header: {
                Text("\(table?.name ?? "Table") — table \(table?.gameId ?? "")")
            }

            Section("The table") {
                ForEach(Array((table?.lines ?? []).enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
            }

            Section(movesHeader) {
                if table?.over == true {
                    Button("Deal a rematch") {
                        if let g = chosen { openSetup(g) } else { phase = .menu }
                    }
                } else if let legal = table?.legal, !legal.isEmpty {
                    ForEach(legal) { m in
                        Button {
                            Task { await play(m.token) }
                        } label: {
                            Text(m.label)
                                .font(.body.weight(.semibold))
                        }
                        .accessibilityHint("Plays this move.")
                    }
                } else {
                    Text("No moves for you right now.")
                        .foregroundStyle(.secondary)
                }
            }

            if let cast = table?.seatAgents, !cast.isEmpty {
                Section("Table talk") {
                    ForEach(Array(talkLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                    }
                    TextField("Say something to the table", text: $talkText)
                        .onSubmit { Task { await sendTalk() } }
                    Button("Say it") { Task { await sendTalk() } }
                        .accessibilityHint("Sends your line to whoever's seated.")
                }
            }

            Section {
                Button("Read the table again") {
                    let text = (table?.lines ?? []).joined(separator: " ")
                    narrator.say(text)
                    UIAccessibility.post(notification: .announcement, argument: text)
                }
                if let transcriptText {
                    ShareLink("Share the transcript", item: transcriptText)
                } else {
                    Button("Get the transcript") { Task { await fetchTranscript() } }
                        .accessibilityHint("Fetches the whole game log for saving or sharing.")
                }
                Button("Quit this table", role: .destructive) { Task { await quitTable() } }
                Button("Back to the menu") { Task { phase = .menu; await loadMenu() } }
            }
        }
    }

    private var movesHeader: String {
        guard let t = table else { return "Your moves" }
        if t.over { return "This table is finished" }
        return "Your moves"
    }

    private func applyTable(_ t: ParlorService.Table, announcePrefix: String) {
        table = t
        phase = .table
        let news = (t.log ?? []).joined(separator: " ")
        lastNews = news.isEmpty ? (t.over ? "Game over." : "Your move.") : news
        ParlorSounds.shared.play(t.sounds ?? [], client: apiClient)
        narrator.narrate(t.log ?? [])
        let announcement = "\(announcePrefix) \(lastNews)"
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }

    private func resume(_ gameId: String) async {
        do {
            let t = try await service.state(gameId: gameId)
            chosen = games.first { $0.key == t.gameKey }
            talkLog = []
            transcriptText = nil
            applyTable(t, announcePrefix: "Back at your \(t.name) table.")
        } catch {
            statusLine = error.localizedDescription
            UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
        }
    }

    private func play(_ token: String) async {
        guard let t = table, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let next = try await service.move(gameId: t.gameId, token: token)
            transcriptText = nil // stale the moment a new move lands
            applyTable(next, announcePrefix: "")
        } catch {
            UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
            if let fresh = try? await service.state(gameId: t.gameId) {
                applyTable(fresh, announcePrefix: error.localizedDescription)
            }
        }
    }

    private func sendTalk() async {
        guard let t = table else { return }
        let text = talkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        talkText = ""
        talkLog.append("You: \(text)")
        do {
            let reply = try await service.talk(gameId: t.gameId, text: text, to: nil)
            talkLog.append("\(reply.name): \(reply.line)")
            if narrator.mode == .everything {
                narrator.say("\(reply.name) says, \(reply.line)")
            }
            UIAccessibility.post(notification: .announcement, argument: "\(reply.name) says: \(reply.line)")
        } catch {
            talkLog.append("(no reply — \(error.localizedDescription))")
            UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
        }
    }

    private func fetchTranscript() async {
        guard let t = table else { return }
        if let text = await service.transcript(gameId: t.gameId) {
            transcriptText = text
            UIAccessibility.post(notification: .announcement, argument: "Transcript ready — the share button is right here.")
        } else {
            UIAccessibility.post(notification: .announcement, argument: "Couldn't fetch the transcript just now.")
        }
    }

    private func quitTable() async {
        guard let t = table else { return }
        await service.quit(gameId: t.gameId)
        narrator.stop()
        UIAccessibility.post(notification: .announcement, argument: "Table closed.")
        phase = .menu
        await loadMenu()
    }
}
