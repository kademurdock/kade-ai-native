import SwiftUI

/// Sep 23 2026 redesign (A3, "search everything"). One field that finds a
/// place in the app ("ringtone" finds Settings; "games" finds The Parlor), a
/// character ("Harley" starts a chat with him), your own chats by title, and
/// the family Library (the server's own search).
///
/// VoiceOver shape: the field first; results under real headings ("In the
/// app", "Characters", "Your chats", "Library") so the Headings rotor jumps
/// between groups; a one-line summary after each change of the query says how
/// much was found, so typing never meets silence. Plain `List` — no lazy
/// stacks anywhere in this path.
struct KadeSearchView: View {
    let apiClient: KadeAPIClient
    @Environment(\.kadeNavigation) private var nav
    @EnvironmentObject private var agentsService: AgentsService
    @EnvironmentObject private var conversationsService: ConversationsService
    @State private var query = ""
    @FocusState private var fieldFocused: Bool
    @State private var libraryResults: [RRItem] = []
    @State private var librarySearching = false
    @State private var libraryError: String?
    @State private var libraryTask: Task<Void, Never>?
    @State private var announceTask: Task<Void, Never>?

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Search everything", text: $query)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        .focused($fieldFocused)
                        .accessibilityLabel("Search everything")
                        .accessibilityHint("Finds places in the app, characters, your chats and the Library.")
                    if !query.isEmpty {
                        Button {
                            query = ""
                            fieldFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
            }

            if trimmed.isEmpty {
                Section {
                    Text("Type a word you'd use yourself: ringtone, games, songs, Harley, a book title, or the name of a chat.")
                        .foregroundStyle(.secondary)
                } header: {
                    heading("Try")
                }
            } else {
                Section {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !placeMatches.isEmpty {
                    Section {
                        ForEach(placeMatches) { place in
                            Button {
                                nav.open(place.route)
                            } label: {
                                Label(place.title, systemImage: place.symbol)
                            }
                            .buttonStyle(.plain)
                            .labelStyle(KadeRowLabelStyle(tint: place.tint, caption: place.caption))
                            .accessibilityLabel("\(place.title). \(place.caption)")
                            .accessibilityHint("Takes you there.")
                        }
                        Button {
                            nav.open(.settingsSearch(trimmed))
                        } label: {
                            Label("Search Settings for “\(trimmed)”", systemImage: "gearshape")
                        }
                        .buttonStyle(.plain)
                        .labelStyle(KadeRowLabelStyle(tint: .gray))
                        .accessibilityHint("Opens Settings with this already typed in its own search.")
                    } header: {
                        heading("In the app")
                    }
                } else {
                    Section {
                        Button {
                            nav.open(.settingsSearch(trimmed))
                        } label: {
                            Label("Search Settings for “\(trimmed)”", systemImage: "gearshape")
                        }
                        .buttonStyle(.plain)
                        .labelStyle(KadeRowLabelStyle(tint: .gray))
                        .accessibilityHint("Opens Settings with this already typed in its own search.")
                    } header: {
                        heading("In the app")
                    }
                }

                if !characterMatches.isEmpty {
                    Section {
                        ForEach(characterMatches) { agent in
                            Button {
                                nav.startChat(agent.id)
                            } label: {
                                HStack(spacing: 12) {
                                    KadeCharacterFace(agentID: agent.id, name: agent.name, size: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(agent.name).font(.body.weight(.medium))
                                        if let about = agent.description, !about.isEmpty {
                                            Text(about)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Talk to \(agent.name)")
                            .accessibilityHint("Starts a new chat with \(agent.name).")
                        }
                    } header: {
                        heading("Characters")
                    }
                }

                if !chatMatches.isEmpty {
                    Section {
                        ForEach(chatMatches) { convo in
                            Button {
                                nav.openConversation(convo)
                            } label: {
                                HStack(spacing: 12) {
                                    KadeCharacterFace(agentID: convo.agentId, name: agentsService.name(for: convo.agentId) ?? convo.displayTitle, size: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(convo.displayTitle).font(.body)
                                        Text(chatDetail(convo))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(convo.displayTitle). \(chatDetail(convo))")
                            .accessibilityHint("Opens this conversation.")
                        }
                    } header: {
                        heading("Your chats")
                    }
                }

                Section {
                    if librarySearching {
                        HStack(spacing: 8) {
                            ProgressView().accessibilityHidden(true)
                            Text("Searching the Library…").foregroundStyle(.secondary)
                        }
                    } else if let libraryError {
                        Text(libraryError).foregroundStyle(.secondary)
                    } else if libraryResults.isEmpty {
                        Text(trimmed.count < 3 ? "Type at least three letters to search the Library." : "Nothing in the Library matches.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(libraryResults.prefix(25)) { item in
                            Button {
                                nav.openLibraryItem(item.id)
                            } label: {
                                Label(item.title, systemImage: item.kind == "text" ? "book.closed" : (item.kind == "video" ? "film" : "waveform"))
                            }
                            .buttonStyle(.plain)
                            .labelStyle(KadeRowLabelStyle(tint: .brown, caption: libraryDetail(item)))
                            .accessibilityLabel(libraryDetail(item).isEmpty ? item.title : "\(item.title). \(libraryDetail(item))")
                            .accessibilityHint("Opens it in the Library.")
                        }
                    }
                } header: {
                    heading("Library")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Focus the field only if nothing's typed yet; returning from a
            // result must not throw the keyboard back up.
            if query.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    fieldFocused = true
                }
            }
        }
        .task { await agentsService.loadIfNeeded() }
        .onChange(of: query) { _, _ in
            scheduleLibrarySearch()
            scheduleSummaryAnnouncement()
        }
        .onDisappear {
            libraryTask?.cancel()
            announceTask?.cancel()
        }
    }

    // MARK: - Matching

    private func heading(_ text: String) -> some View {
        Text(text).accessibilityAddTraits(.isHeader)
    }

    private func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
    }

    private var placeMatches: [KadeSearchPlace] {
        let terms = words(trimmed)
        guard !terms.isEmpty else { return [] }
        return KadeSearchPlace.all.filter { place in
            let hay = "\(place.title) \(place.caption) \(place.keywords)".lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    private var characterMatches: [KadeAgent] {
        let q = trimmed
        guard !q.isEmpty else { return [] }
        return Array(agentsService.agents.filter {
            $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }.prefix(12))
    }

    private var chatMatches: [KadeConversation] {
        let q = trimmed
        guard !q.isEmpty else { return [] }
        return Array(conversationsService.conversations.filter {
            $0.displayTitle.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }.prefix(15))
    }

    private func chatDetail(_ convo: KadeConversation) -> String {
        var parts: [String] = []
        if let name = agentsService.name(for: convo.agentId) { parts.append("with \(name)") }
        if let relative = KadeDateFormatting.relative(from: convo.updatedAt) { parts.append(relative) }
        return parts.joined(separator: ", ")
    }

    private func libraryDetail(_ item: RRItem) -> String {
        var parts: [String] = []
        if let author = item.author, !author.isEmpty { parts.append(author) }
        parts.append(RRCategory.name(item.kind == "text" ? "book" : item.category, isAudio: item.kind != "text"))
        return parts.joined(separator: ", ")
    }

    private var summary: String {
        let places = placeMatches.count
        let characters = characterMatches.count
        let chats = chatMatches.count
        var bits: [String] = []
        if places > 0 { bits.append(places == 1 ? "1 place" : "\(places) places") }
        if characters > 0 { bits.append(characters == 1 ? "1 character" : "\(characters) characters") }
        if chats > 0 { bits.append(chats == 1 ? "1 chat" : "\(chats) chats") }
        if !libraryResults.isEmpty { bits.append(libraryResults.count == 1 ? "1 Library item" : "\(min(libraryResults.count, 25)) Library items") }
        if bits.isEmpty { return librarySearching ? "Searching…" : "Nothing found yet. Try a different word." }
        return "Found " + bits.joined(separator: ", ") + "."
    }

    // MARK: - Library search (server side, debounced)

    private func scheduleLibrarySearch() {
        libraryTask?.cancel()
        let q = trimmed
        libraryError = nil
        guard q.count >= 3 else {
            libraryResults = []
            librarySearching = false
            return
        }
        librarySearching = true
        libraryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            do {
                let found = try await ReadingRoomService(client: apiClient).search(q)
                guard !Task.isCancelled, q == trimmed else { return }
                libraryResults = found
            } catch {
                guard !Task.isCancelled else { return }
                libraryResults = []
                libraryError = "The Library didn't answer. Try again in a moment."
            }
            librarySearching = false
        }
    }

    /// One quiet line after typing settles, so the ear knows what the list holds.
    private func scheduleSummaryAnnouncement() {
        announceTask?.cancel()
        guard !trimmed.isEmpty else { return }
        announceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            UIAccessibility.post(notification: .announcement, argument: summary)
        }
    }
}

/// Every place in the app, searchable offline by the words people actually
/// use. `keywords` is the synonym map (the same idea as Settings' own search).
struct KadeSearchPlace: Identifiable {
    let title: String
    let caption: String
    let symbol: String
    let tint: Color
    let route: HomeRoute
    let keywords: String
    var id: String { title }

    static let all: [KadeSearchPlace] = [
        KadeSearchPlace(title: "Your conversations", caption: "Talk tab", symbol: "bubble.left.and.bubble.right", tint: .blue, route: .conversations, keywords: "chats chat messages history talk list"),
        KadeSearchPlace(title: "Describe", caption: "Photos, videos and papers read to you", symbol: "plus.viewfinder", tint: .teal, route: .describe, keywords: "camera picture photo image document letter mail menu read describe see video"),
        KadeSearchPlace(title: "Transcribe", caption: "Turn your voice into text", symbol: "waveform", tint: .purple, route: .transcribe, keywords: "dictate dictation voice memo record recording text speech notes"),
        KadeSearchPlace(title: "Quick Dictate", caption: "Talk, and the words land on your clipboard", symbol: "mic.badge.plus", tint: .purple, route: .quickDictate, keywords: "dictate clipboard quick voice type"),
        KadeSearchPlace(title: "The Library", caption: "Books read aloud, tapes, radio and TV", symbol: "books.vertical", tint: .brown, route: .readingRoom, keywords: "books book audiobook read reading listen radio tape cassette commercials movies tv video archive donate library"),
        KadeSearchPlace(title: "The Sound Booth", caption: "Songs, scenes with voices, sound effects", symbol: "mic.square", tint: .indigo, route: .soundBooth, keywords: "song songs music sing singing make create record voice scene story sound effects audio booth"),
        KadeSearchPlace(title: "My Creations", caption: "Everything you've made", symbol: "photo.stack", tint: .yellow, route: .myCreations, keywords: "creations made pictures images songs videos mine save"),
        KadeSearchPlace(title: "Wall of Fame", caption: "What the family shared", symbol: "trophy", tint: .brown, route: .wallOfFame, keywords: "wall fame family shared share creations"),
        KadeSearchPlace(title: "Agent Builder", caption: "Make your own character", symbol: "person.crop.circle.badge.plus", tint: .cyan, route: .agentBuilder, keywords: "build make create character agent persona new edit"),
        KadeSearchPlace(title: "The Prompt Library", caption: "Saved things to say", symbol: "text.badge.star", tint: .green, route: .prompts, keywords: "prompts prompt saved templates starters"),
        KadeSearchPlace(title: "The Parlor", caption: "Card and table games", symbol: "suit.club.fill", tint: .mint, route: .parlor, keywords: "games game cards blackjack uno trivia hangman play table poker"),
        KadeSearchPlace(title: "Kade's Clubhouse", caption: "Live family voice rooms", symbol: "hifispeaker.2.fill", tint: .pink, route: .lounge, keywords: "clubhouse lounge voice rooms talk live family jukebox music hotel party"),
        KadeSearchPlace(title: "Debate Room", caption: "Characters talk it out together", symbol: "person.3.fill", tint: .indigo, route: .debateRoom, keywords: "debate argue discussion hall conversation hall group"),
        KadeSearchPlace(title: "Matchmaker", caption: "Find a character you'd like", symbol: "person.2.fill", tint: .pink, route: .matchmaker, keywords: "match matchmaker quiz find character who recommend"),
        KadeSearchPlace(title: "The Marketplace", caption: "Meet every character", symbol: "storefront", tint: .orange, route: .marketplace, keywords: "marketplace characters browse meet publish agents all"),
        KadeSearchPlace(title: "Alerts", caption: "Reminders and check-ins", symbol: "bell", tint: .orange, route: .alerts, keywords: "alerts reminders reminder check ins notifications birthday"),
        KadeSearchPlace(title: "Announcements", caption: "News about the app from Kade", symbol: "megaphone", tint: .purple, route: .announcements, keywords: "announcements news whats new updates digest"),
        KadeSearchPlace(title: "Agent work", caption: "Replies saved after a dropped connection", symbol: "checklist", tint: .indigo, route: .agentWork, keywords: "agent work saved replies requests tasks dropped connection"),
        KadeSearchPlace(title: "Bookmarks", caption: "Conversations you tagged", symbol: "bookmark.fill", tint: .red, route: .bookmarks, keywords: "bookmarks bookmark tags tagged saved favorites"),
        KadeSearchPlace(title: "Settings", caption: "Voices, ringtone, text and sound", symbol: "gearshape", tint: .gray, route: .settings, keywords: "settings preferences ringtone ring voice speed font contrast haptics sounds main character password account icon notifications"),
        KadeSearchPlace(title: "Morning brief", caption: "Your daily rundown", symbol: "sun.max", tint: .yellow, route: .brief, keywords: "brief morning daily news rundown"),
        KadeSearchPlace(title: "Help", caption: "How everything works", symbol: "questionmark.circle", tint: .mint, route: .help, keywords: "help how guide instructions where is lost gestures"),
    ]
}
