import SwiftUI

/// The Matchmaker — see `MatchmakerService` for the server contract. Five
/// quick questions, three matches, and a straight line into a new
/// conversation with whoever you pick. Kade's own framing, straight off the
/// web page: "Five quick questions, three friends on the other side.
/// Nothing is saved, nothing costs anything, and you can retake it as many
/// times as you like." — this port keeps every bit of that: no answers are
/// ever sent anywhere, and scoring happens entirely on-device.
///
/// VoiceOver notes: each question is a real heading (rotor jump-between);
/// each option is a Button styled as a selectable row with `.isSelected`
/// when chosen — the same accessible-row pattern as `AgentPickerView`'s
/// `rowButton(for:)` — rather than a native `Picker`/`Toggle`, because a
/// single-page, five-question form reads far more predictably by ear as a
/// list of clearly labeled buttons than as several different control types
/// competing for rotor attention. Each match card is TWO accessibility
/// stops, not one: the name/why/description as a read-only combined
/// element, then "Start talking to X" as its own real Button — this app
/// avoids `.combine` and avoids burying an activatable control inside an
/// `.ignore`d subtree, on the same principle documented in `HelpView`.
struct MatchmakerView: View {
    @StateObject private var service: MatchmakerService

    init(apiClient: KadeAPIClient) {
        _service = StateObject(wrappedValue: MatchmakerService(client: apiClient))
    }

    @State private var roster: [MatchmakerAgent] = []
    @State private var hasLoaded = false

    @State private var purpose: String?
    @State private var vibe: String?
    @State private var age: String?
    @State private var topics: Set<String> = []
    @State private var style: String?

    @State private var results: [ScoredMatch]?
    @State private var luckyPick: MatchmakerAgent?
    @State private var startHandoff: MatchmakerStartHandoff?
    // Session 22: results fade in for sighted eyes; VoiceOver focus (which
    // already jumps to the results heading onAppear) is unaffected. Gated on
    // both reduce-motion signals like every other animation in the app.
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var resultsAnimation: Animation? {
        (systemReduceMotion || FeedbackPrefs.shared.forceReduceMotion)
            ? nil : .easeOut(duration: 0.3)
    }

    private enum Focus: Hashable { case status, results }
    @AccessibilityFocusState private var a11yFocus: Focus?

    private var canSubmit: Bool {
        purpose != nil && vibe != nil && age != nil && style != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error = service.loadError {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityFocused($a11yFocus, equals: .status)
                } else if service.isLoading || !hasLoaded {
                    ProgressView("Loading the roster…")
                        .accessibilityLabel("Loading the character roster")
                } else if let results {
                    resultsSection(results)
                        .transition(.opacity)
                } else if let luckyPick {
                    luckySection(luckyPick)
                        .transition(.opacity)
                } else {
                    intro
                    quiz
                }
            }
            .padding()
        }
        .navigationTitle("Matchmaker")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !hasLoaded else { return }
            roster = await service.loadRoster()
            hasLoaded = true
            if service.loadError != nil { a11yFocus = .status }
        }
        .navigationDestination(item: $startHandoff) { handoff in
            ConversationDetailView(conversation: nil, initialAgentId: handoff.agentId)
        }
    }

    private var intro: some View {
        Text("Five quick questions, three friends on the other side. Nothing is saved, nothing costs anything, and you can retake it as many times as you like.")
            .font(.body)
            .foregroundStyle(.secondary)
    }

    // MARK: - Quiz

    private var quiz: some View {
        VStack(alignment: .leading, spacing: 24) {
            questionSection(
                title: "1. What are you in the mood for?",
                options: MatchOptions.purpose,
                selected: purpose.map { [$0] } ?? []
            ) { purpose = $0 }

            questionSection(
                title: "2. What energy fits you best right now?",
                options: MatchOptions.vibe,
                selected: vibe.map { [$0] } ?? []
            ) { vibe = $0 }

            questionSection(
                title: "3. Whose company do you usually enjoy?",
                options: MatchOptions.age,
                selected: age.map { [$0] } ?? []
            ) { age = $0 }

            questionSection(
                title: "4. Pick anything you love talking about (as many as you like)",
                options: MatchOptions.topics,
                selected: topics,
                multi: true
            ) { tag in
                if topics.contains(tag) { topics.remove(tag) } else { topics.insert(tag) }
            }

            questionSection(
                title: "5. How do you like people to talk to you?",
                options: MatchOptions.style,
                selected: style.map { [$0] } ?? []
            ) { style = $0 }

            Button {
                findMatches()
            } label: {
                Text("Find my people")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
            .accessibilityHint(
                canSubmit
                    ? "Shows your three best matches."
                    : "Answer questions 1, 2, 3, and 5 first — question 4 is optional."
            )
        }
    }

    private func questionSection(
        title: String,
        options: [(key: String, label: String)],
        selected: Set<String>,
        multi: Bool = false,
        onPick: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(options, id: \.key) { option in
                let isSelected = selected.contains(option.key)
                Button {
                    onPick(option.key)
                } label: {
                    HStack {
                        Text(option.label)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityHint(multi ? "Toggles this choice." : "Selects this choice.")
            }
        }
    }

    // MARK: - Scoring (mirrors kadeMatchmaker.js's inline <script> exactly)

    private func findMatches() {
        guard let purpose, let vibe, let age, let style else { return }
        let picks = Picks(purpose: purpose, vibe: vibe, age: age, topics: topics, style: style)
        let scored = roster
            .map { agent -> ScoredMatch in
                let (score, hits) = Self.score(agent: agent, picks: picks)
                return ScoredMatch(agent: agent, score: score + Double.random(in: 0..<0.5), hits: hits)
            }
            .sorted { $0.score > $1.score }
        withAnimation(resultsAnimation) {
            luckyPick = nil
            results = Array(scored.prefix(3))
        }
        // Session 22: matches arriving is a small "done" moment.
        Earcons.shared.play(.actionDone)
        KadeHaptics.success()
    }

    private struct Picks {
        let purpose: String
        let vibe: String
        let age: String
        let topics: Set<String>
        let style: String
    }

    /// Weights match the web page's own `score()` exactly: purpose 3, vibe
    /// 2, age 2, each picked topic 1, style 1. `hits` collects which tags
    /// actually landed, deduplicated, in hit order — used for the "why"
    /// line, same as the web page.
    private static func score(agent: MatchmakerAgent, picks: Picks) -> (Double, [String]) {
        var total = 0.0
        var hits: [String] = []
        func hit(_ tag: String?, weight: Double) {
            guard let tag, agent.tags.contains(tag) else { return }
            total += weight
            if !hits.contains(tag) { hits.append(tag) }
        }
        hit(picks.purpose, weight: 3)
        hit(picks.vibe, weight: 2)
        hit(picks.age, weight: 2)
        for topic in picks.topics { hit(topic, weight: 1) }
        hit(picks.style, weight: 1)
        return (total, hits)
    }

    // MARK: - Results

    private func resultsSection(_ matches: [ScoredMatch]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your matches")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($a11yFocus, equals: .results)

            ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in
                matchCard(rank: index + 1, match: match)
            }

            HStack {
                Button("Retake the quiz") { withAnimation(resultsAnimation) { results = nil } }
                    .buttonStyle(.bordered)
                Button("Surprise me") { surpriseMe() }
                    .buttonStyle(.bordered)
            }
        }
        .onAppear { a11yFocus = .results }
    }

    private func luckySection(_ agent: MatchmakerAgent) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fate says…")
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($a11yFocus, equals: .results)
            matchCard(rank: nil, match: ScoredMatch(agent: agent, score: 0, hits: []))
            HStack {
                Button("Spin again") { surpriseMe() }
                    .buttonStyle(.bordered)
                Button("Take the quiz instead") { withAnimation(resultsAnimation) { luckyPick = nil } }
                    .buttonStyle(.bordered)
            }
        }
        .onAppear { a11yFocus = .results }
    }

    private func surpriseMe() {
        guard !roster.isEmpty else { return }
        withAnimation(resultsAnimation) {
            results = nil
            luckyPick = roster.randomElement()
        }
        Earcons.shared.play(.actionDone)
        KadeHaptics.success()
    }

    private func matchCard(rank: Int?, match: ScoredMatch) -> some View {
        let why = match.hits.prefix(3).map { MatchOptions.why[$0] ?? $0 }.joined(separator: " · ")
        let nameLine = rank != nil ? "\(rank!). \(match.agent.name)" : match.agent.name
        let infoLabel = [nameLine, why, match.agent.description]
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(nameLine).font(.headline)
                if !why.isEmpty {
                    Text(why).font(.subheadline).foregroundStyle(.secondary)
                }
                if !match.agent.description.isEmpty {
                    Text(match.agent.description).font(.body)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(infoLabel)

            Button {
                startHandoff = MatchmakerStartHandoff(agentId: match.agent.id)
            } label: {
                Text("Start talking to \(firstName(match.agent.name))")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Starts a new conversation with \(match.agent.name).")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}

/// The five question sets and the "why" phrase for each tag — transcribed
/// verbatim from `kadeMatchmaker.js`'s `MATCH_HTML` template and its `WHY`
/// map, so the quiz asks the exact same things in the exact same words as
/// the web version.
enum MatchOptions {
    static let purpose: [(key: String, label: String)] = [
        ("chat", "Good company — somebody to just talk with"),
        ("laughs", "Laughs — make me cackle"),
        ("games", "Games — deal me in"),
        ("stories", "Stories and adventures"),
        ("deep", "A real heart-to-heart"),
        ("help", "Help getting something done"),
    ]
    static let vibe: [(key: String, label: String)] = [
        ("calm", "Calm and gentle"),
        ("warm", "Warm and nurturing"),
        ("bold", "Big and loud"),
        ("witty", "Dry and quick"),
        ("mysterious", "A little mysterious"),
    ]
    static let age: [(key: String, label: String)] = [
        ("elder", "Grandparent energy — stories and no hurry"),
        ("adult", "Steady grown-folks energy"),
        ("peer", "Somebody on my level"),
        ("young", "Youthful chaos"),
        ("timeless", "Odd and timeless — surprise me"),
    ]
    static let topics: [(key: String, label: String)] = [
        ("music", "Music"),
        ("food", "Food and cooking"),
        ("outdoors", "The outdoors — fishing, gardens, critter reports"),
        ("sports", "Sports"),
        ("faith", "Faith"),
        ("tech", "Tech and games"),
        ("books", "Books and stories"),
        ("gossip", "People and gossip"),
        ("travel", "Travel and far-off places"),
        ("animals", "Animals"),
        ("art", "Art and making things"),
        ("family", "Family life"),
    ]
    static let style: [(key: String, label: String)] = [
        ("straight", "Tell it to me straight"),
        ("gentle", "Gentle with me"),
        ("funny", "Keep it funny"),
        ("weird", "The weirder the better"),
    ]

    static let why: [String: String] = [
        "chat": "good company", "laughs": "brings the jokes", "games": "always up for a game",
        "stories": "a born storyteller", "deep": "listens for real", "help": "gets things done",
        "calm": "calm and gentle", "warm": "warm as a porch light", "bold": "big energy",
        "witty": "quick and dry", "mysterious": "a little mysterious", "elder": "seasoned and unhurried",
        "adult": "steady grown-folks energy", "peer": "right on your level", "young": "youthful chaos",
        "timeless": "one of a kind", "music": "talks music", "food": "talks food and cooking",
        "outdoors": "lives for the outdoors", "sports": "talks sports", "faith": "talks faith",
        "tech": "into tech and games", "books": "loves books and stories", "gossip": "brings the tea",
        "travel": "full of far-off places", "animals": "an animal person", "art": "makes things",
        "family": "all about family", "straight": "tells it straight", "gentle": "gentle with you",
        "funny": "keeps it funny", "weird": "wonderfully weird",
    ]
}

struct ScoredMatch: Identifiable {
    let agent: MatchmakerAgent
    let score: Double
    let hits: [String]
    var id: String { agent.id }
}

/// A brand-new conversation's target agent, handed from a match card to
/// `ConversationDetailView`'s new `initialAgentId` param. Its OWN dedicated
/// `Identifiable` type, declared and routed exactly once, right here --
/// same rule this app enforces everywhere `.navigationDestination(item:)`
/// appears (see `SpotterTranscriptHandoff`'s doc comment in ContentView.swift
/// for the collision this pattern exists to prevent).
struct MatchmakerStartHandoff: Identifiable, Hashable {
    let agentId: String
    var id: String { agentId }
}
