import SwiftUI

/// Phase 4: pick which agent/character answers the NEXT message in an
/// open conversation.
///
/// This does not change anything about the conversation itself server-side —
/// the fork reads `agent_id` fresh off EACH send request rather than locking
/// a conversation to whichever agent started it. Confirmed live 2026-07-19:
/// sent a second turn in the same conversationId with a different `agent_id`
/// than the first turn, and the reply came back attributed to the NEW agent
/// while the first turn's reply stayed attributed to the original one (see
/// docs/ENDPOINTS.md). So "switching" here is purely client-side state —
/// which id this view hands back to `ConversationDetailView`, which passes
/// it to `MessageSendingService.send` on the next send.
///
/// VoiceOver notes: search is a plain `TextField` (see `searchField`
/// below), not the system `.searchable` bar -- see the "Search-first" note
/// below for why. Each row is one combined element (name + description +
/// "Currently selected" when applicable) with a clear hint of what tapping
/// does, matching the row pattern used in `ConversationListView`.
///
/// Layout notes (added 2026-07-19, after Kade's real-use feedback that a
/// flat alphabetical list of her ~221 owned agents was "spammy and hard
/// to scroll through," asking for something quicker with "short
/// explanatory labels"): when NOT searching, the list is now a Recent
/// section (your last few picks, fastest path back to who you just used)
/// followed by real category sections straight off the server's own
/// `category` field. While searching, it collapses back to one flat
/// filtered list, since search already does the narrowing.
///
/// Search-first (added 2026-07-19, same day, after live-testing the Recent
/// + category layout above): Kade's follow-up was that heading navigation
/// still means browsing, and with ~221 agents that's still a sprawl --
/// "That's why I suggested a picker or something." Given a choice between
/// narrowing the default list vs. making search the immediate landing
/// point, she picked search-first: open the picker, start typing, swipe
/// to the one match, no browsing required.
///
/// First attempt used the system `.searchable` field plus `.searchFocused
/// (_:)` to auto-focus it on appear -- the clean, minimal-diff way to do
/// this. Codemagic's real compiler caught what hand-review didn't:
/// `.searchFocused(_:)` needs iOS 18, and this project targets iOS 17
/// (confirmed the hard way -- build 119 failed on exactly this line).
/// Rather than raise the whole app's deployment target for a picker
/// tweak, this now uses a plain `TextField` (`searchField` below) pinned
/// above the list instead of `.searchable`, focused via the ordinary
/// `.focused(_:)` API (iOS 15+, ordinary keyboard focus, not the search-
/// bar-specific hook). Noted honestly: this trades away the system search
/// bar's built-in "Search Fields" VoiceOver rotor category -- a plain
/// TextField shows up under the generic "Text Fields" rotor instead --
/// accepted because the entire point here is landing on the field
/// automatically, without needing the rotor at all. Moving keyboard focus
/// onto a text field reliably pulls VoiceOver's focus with it too
/// (standard first-responder behavior), so the one `@FocusState` binding
/// still covers both sighted-keyboard and VoiceOver users. Recent/
/// category browsing underneath is untouched -- this doesn't remove that
/// path, it just stops making everyone walk through it to reach search.
struct AgentPickerView: View {
    @EnvironmentObject private var agentsService: AgentsService
    let currentAgentId: String?
    let onSelect: (KadeAgent) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @FocusState private var isSearchFieldFocused: Bool

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var filtered: [KadeAgent] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return agentsService.agents }
        return agentsService.agents.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || ($0.description ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var recentAgents: [KadeAgent] {
        let byId = Dictionary(uniqueKeysWithValues: agentsService.agents.map { ($0.id, $0) })
        return RecentAgents.ids.compactMap { byId[$0] }
    }

    /// Session 26 (Kade on the marketplace: "almost a hundred pages of
    /// scrolling categorical posts... a tiny bit overwhelming" — her pick
    /// via AskUserQuestion: build the Starters shelf): a short hand-curated
    /// shelf shown FIRST when browsing. At ~117 published characters across
    /// 40-odd category sections, equal billing is billing for no one; eight
    /// deliberate picks across the platform's main lanes (companion,
    /// accessibility, advice, food, quiet support, creative, practical,
    /// pure fun) give a newcomer somewhere to start without wading. Name-
    /// matched against the live roster so an unpublished pick simply drops
    /// off the shelf instead of rendering a dead row. Search-first behavior
    /// is untouched — this only exists in the browse layout underneath.
    private static let starterNames = [
        "Kiana", "Vista", "Dr. Nora", "Chef Marcel",
        "Silas", "Ariadne", "Mac", "Doug",
    ]

    private var starterAgents: [KadeAgent] {
        Self.starterNames.compactMap { name in
            agentsService.agents.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// Groups the full agent list by their server-provided `category`
    /// (companions, roleplay, personal, expert, creative, ...), sorted
    /// alphabetically with an "Other" bucket last for anything missing a
    /// category. Each bucket is itself sorted by agent name.
    private var groupedByCategory: [(title: String, agents: [KadeAgent])] {
        var buckets: [String: [KadeAgent]] = [:]
        for agent in agentsService.agents {
            let raw = agent.category?.trimmingCharacters(in: .whitespaces) ?? ""
            let key = raw.isEmpty ? "Other" : raw
            buckets[key, default: []].append(agent)
        }
        let sortedKeys = buckets.keys.sorted { lhs, rhs in
            if lhs == "Other" { return false }
            if rhs == "Other" { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return sortedKeys.map { key in
            (
                title: key.localizedCapitalized,
                agents: buckets[key]!.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            )
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Group {
                    if agentsService.isLoading && agentsService.agents.isEmpty {
                        ProgressView("Loading agents…")
                            .accessibilityLabel("Loading agents")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = agentsService.loadError, agentsService.agents.isEmpty {
                        errorState(error)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if agentsService.agents.isEmpty {
                        Text("No agents available.")
                            .foregroundStyle(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if isSearching && filtered.isEmpty {
                        Text("No agents match \"\(searchText)\".")
                            .foregroundStyle(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        list
                    }
                }
            }
            .navigationTitle("Choose agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await agentsService.loadIfNeeded() }
            .onAppear {
                // Grabbing focus in the same tick a sheet starts
                // presenting is unreliable -- the field isn't installed
                // in the window yet, so the request gets dropped more
                // often than not. A short wait past the presentation
                // animation makes it land every time instead of
                // intermittently.
                Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    isSearchFieldFocused = true
                }
            }
        }
    }

    /// Always-visible search bar, pinned above the list rather than using
    /// `.searchable` -- see the "Search-first" doc note at the top of this
    /// file for the why (short version: `.searchFocused` needs iOS 18).
    /// Built to read sensibly by hand: the icon is decorative (hidden from
    /// the accessibility tree), the field carries its own label and hint,
    /// and the clear button is a separate reachable element with its own
    /// label rather than folded silently into the field.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search agents", text: $searchText)
                .focused($isSearchFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { isSearchFieldFocused = false }
                .accessibilityLabel("Search agents")
                .accessibilityHint("Type a name to narrow the list below.")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var list: some View {
        List {
            if isSearching {
                ForEach(filtered) { agent in
                    rowButton(for: agent)
                }
            } else {
                if !starterAgents.isEmpty {
                    Section {
                        ForEach(starterAgents) { agent in
                            rowButton(for: agent)
                        }
                    } header: {
                        Text("Starters")
                            .accessibilityAddTraits(.isHeader)
                    } footer: {
                        Text("A few good first hellos, hand-picked. Everyone else is below, by category -- or just type a name in search.")
                    }
                }
                if !recentAgents.isEmpty {
                    Section {
                        ForEach(recentAgents) { agent in
                            rowButton(for: agent)
                        }
                    } header: {
                        Text("Recent")
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                ForEach(groupedByCategory, id: \.title) { group in
                    Section {
                        ForEach(group.agents) { agent in
                            rowButton(for: agent)
                        }
                    } header: {
                        Text(group.title)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    /// One row, wired up identically everywhere it's used (Recent section,
    /// category sections, and the flat search results) so there's exactly
    /// one place that owns the accessibility contract instead of three
    /// copies that could drift apart.
    private func rowButton(for agent: KadeAgent) -> some View {
        Button {
            RecentAgents.record(agent.id)
            onSelect(agent)
            dismiss()
        } label: {
            row(for: agent)
        }
        .buttonStyle(.plain)
        // Session 26, the Amber rule (build 139 / the df915e2 sweep):
        // NO .accessibilityElement(children:.ignore) on a Button — it
        // costs the row direct VoiceOver activation (double-tap degrades
        // to a synthesized tap at a layout-dependent point; that is
        // exactly how Amber's "New Chat" row died in the conversation
        // list). The proven shape is what remains: plain Button, its own
        // explicit label, native flatten. This row was missed by the
        // df915e2 pass — its old comment even cited the broken
        // construction as the fix.
        .accessibilityLabel(accessibleLabel(for: agent, isSelected: agent.id == currentAgentId))
        .accessibilityAddTraits(agent.id == currentAgentId ? [.isSelected] : [])
        .accessibilityHint("Switches to this agent for your next message.")
    }

    private func row(for agent: KadeAgent) -> some View {
        let isSelected = agent.id == currentAgentId
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name)
                    .font(.body)
                if let description = agent.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private func accessibleLabel(for agent: KadeAgent, isSelected: Bool) -> String {
        var parts = [agent.name]
        if let description = agent.description, !description.isEmpty {
            parts.append(description.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if isSelected { parts.append("Currently selected") }
        return parts.joined(separator: ". ")
    }

    /// Kade's original ask was "short explanatory labels" -- first shipped
    /// capping to one sentence or ~90 characters (session 11); after actually
    /// using the picker with real agents, Kade reported that cap was cutting
    /// off exactly the information that decides whether to talk to someone --
    /// her example, "Bob like planting seeds in his garden he also..."
    /// trailing into nothing. Widened (session 13) to roughly 2 sentences, or
    /// ~220 characters. Session 18: after living with the 220-character cap,
    /// her ask was direct -- "show the whole description instead of cutting
    /// off, or we need to make the description more short and descriptive."
    /// Shortening the descriptions themselves means editing real agent data
    /// (a content change, not a display fix, and not something to do
    /// unsupervised against her live library) -- so this now shows the full
    /// description, uncapped, both visually (row(for:) dropped its
    /// `.lineLimit(2)`) and in the accessibility label below. A long bio
    /// means a longer swipe-and-listen for that one row; that trade is what
    /// she asked for, in preference to guessing at a THIRD cutoff number.

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message).multilineTextAlignment(.center)
            Button("Try again") { Task { await agentsService.loadIfNeeded() } }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

/// Lightweight, non-sensitive "recently used agents" tracker. Deliberately
/// backed by UserDefaults, not Keychain -- Keychain in this app is reserved
/// for sensitive data (access token, user record; see Keychain.swift), and
/// which characters you've picked recently doesn't belong there.
enum RecentAgents {
    private static let key = "kade.recentAgentIds"
    private static let maxEntries = 8

    static var ids: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ id: String) {
        var current = ids
        current.removeAll { $0 == id }
        current.insert(id, at: 0)
        if current.count > maxEntries {
            current = Array(current.prefix(maxEntries))
        }
        UserDefaults.standard.set(current, forKey: key)
    }
}

#Preview {
    let client = KadeAPIClient()
    return AgentPickerView(currentAgentId: nil, onSelect: { _ in })
        .environmentObject(AgentsService(client: client))
}
