import SwiftUI

/// The Marketplace, native (July 28 2026 — Kade's pick from the roadmap:
/// "Both parler 2.1 and market"). The last big web-only storefront: browse
/// every published companion by category, hear who's who, start talking to
/// anyone in two taps — and publish/unpublish YOUR OWN creations right from
/// their card. VoiceOver-first, same house patterns as the rest of the app:
/// - Hand-built search field (same iOS 17 `.searchable` focus limitation
///   note as `ConversationListView` / `AgentPickerView`).
/// - Section headers are real VoiceOver headings (Headings-rotor hopping
///   across 40-odd categories instead of swiping hundreds of rows).
/// - Every row is a plain Button carrying its own accessibility label — no
///   `children:.ignore` anywhere (the Amber rule, builds 139/146).
/// - Avatars are decorative and accessibilityHidden; the words carry it.
///
/// Publish/unpublish rides the same wire the web sharing dialog uses:
///   GET /api/permissions/agent/{_id}        -> current sharing state
///   PUT /api/permissions/agent/{_id}        -> { public, publicAccessRoleId }
/// (contract read from the fork's accessPermissions.js + the proxy's own
/// /librechat/publish helper — publicAccessRoleId is "agent_viewer".)
/// Both are fail-soft here: a 403 (no share rights) or odd shape becomes a
/// plain spoken message, never a broken screen.
struct MarketplaceView: View {
    @EnvironmentObject private var agentsService: AgentsService
    @EnvironmentObject private var apiClient: KadeAPIClient
    let currentUserId: String

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var selectedAgent: KadeAgent?
    /// Its own wrapper TYPE for the push — `navigationDestination(item:)`
    /// registers by TYPE across the whole stack (the build-121/122
    /// invariant), and `KadeConversation`'s one registration lives in
    /// `ConversationListView`. This type exists so starting a chat from the
    /// Marketplace can never collide with it.
    private struct MarketplaceTalk: Identifiable, Hashable {
        let agentId: String
        var id: String { agentId }
    }
    @State private var talkTarget: MarketplaceTalk?

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var filtered: [KadeAgent] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return agentsService.agents.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || ($0.description ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    private var promoted: [KadeAgent] {
        agentsService.agents.filter { $0.isPromoted == true }
    }

    /// Category buckets, alphabetical, "Other" last — same grouping idea the
    /// agent picker browses with, rebuilt here over the full roster.
    private var categories: [(title: String, agents: [KadeAgent])] {
        var buckets: [String: [KadeAgent]] = [:]
        for a in agentsService.agents {
            let raw = (a.category ?? "").trimmingCharacters(in: .whitespaces)
            let key = raw.isEmpty ? "Other" : raw.replacingOccurrences(of: "_", with: " ").capitalized
            buckets[key, default: []].append(a)
        }
        let sorted = buckets.keys.sorted {
            if $0 == "Other" { return false }
            if $1 == "Other" { return true }
            return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return sorted.map { key in
            (title: key, agents: buckets[key]!.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            })
        }
    }

    var body: some View {
        Group {
            if agentsService.isLoading && agentsService.agents.isEmpty {
                ProgressView("Loading the marketplace…")
                    .accessibilityLabel("Loading the marketplace")
            } else if let error = agentsService.loadError, agentsService.agents.isEmpty {
                VStack(spacing: 12) {
                    Text(error).multilineTextAlignment(.center)
                    Button("Try again") { Task { await agentsService.loadIfNeeded() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                list
            }
        }
        .navigationTitle("Marketplace")
        .navigationBarTitleDisplayMode(.inline)
        .task { await agentsService.loadIfNeeded() }
        .sheet(item: $selectedAgent) { agent in
            MarketplaceAgentDetail(
                agent: agent,
                currentUserId: currentUserId,
                onTalk: { agentId in
                    selectedAgent = nil
                    // Small delay so the push doesn't fight the sheet's
                    // dismiss animation — the same deliberate-delay pattern
                    // ContentView's web-load alert documents.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        talkTarget = MarketplaceTalk(agentId: agentId)
                    }
                }
            )
            .environmentObject(apiClient)
        }
        .navigationDestination(item: $talkTarget) { target in
            ConversationDetailView(conversation: nil, initialAgentId: target.agentId)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                searchField
                if isSearching {
                    searchResults
                } else {
                    if !promoted.isEmpty {
                        sectionHeader("House picks")
                        ForEach(promoted) { agent in row(agent) }
                    }
                    ForEach(categories, id: \.title) { bucket in
                        sectionHeader(bucket.title)
                        ForEach(bucket.agents) { agent in row(agent) }
                    }
                }
            }
            .padding()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search characters", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($searchFocused)
                .accessibilityLabel("Search characters")
                .accessibilityHint("Type a name or anything from a character's description.")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var searchResults: some View {
        Group {
            let hits = filtered
            Text(hits.isEmpty
                 ? "No characters match. Try fewer letters."
                 : "\(hits.count) match\(hits.count == 1 ? "" : "es").")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(hits) { agent in row(agent) }
        }
    }

    private func row(_ agent: KadeAgent) -> some View {
        Button {
            selectedAgent = agent
        } label: {
            HStack(alignment: .top, spacing: 10) {
                avatarThumb(agent)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(agent.name).font(.body.weight(.semibold))
                        if agent.isPromoted == true {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                                .accessibilityHidden(true)
                        }
                    }
                    if let d = agent.description, !d.isEmpty {
                        Text(d)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(rowLabel(agent))
        .accessibilityHint("Opens \(agent.name)'s card — hear the full description, start talking, or manage publishing if they're yours.")
    }

    private func rowLabel(_ agent: KadeAgent) -> String {
        var parts: [String] = [agent.name]
        if agent.isPromoted == true { parts.append("house pick") }
        if let d = agent.description, !d.isEmpty { parts.append(d) }
        return parts.joined(separator: ". ")
    }

    @ViewBuilder
    private func avatarThumb(_ agent: KadeAgent) -> some View {
        if let path = agent.avatar?.filepath, !path.isEmpty,
           let url = URL(string: path.hasPrefix("http") ? path : "https://kademurdock.com\(path)") {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color.secondary.opacity(0.2))
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            .accessibilityHidden(true)
        } else {
            KadeSpeakerMonogram(name: agent.name)
                .frame(width: 44, height: 44)
        }
    }
}

/// One character's card: full description, Talk button, and — for the
/// signed-in owner's own creations — the publish/unpublish control.
private struct MarketplaceAgentDetail: View {
    let agent: KadeAgent
    let currentUserId: String
    let onTalk: (String) -> Void

    @EnvironmentObject private var apiClient: KadeAPIClient
    @Environment(\.dismiss) private var dismiss

    private enum PublishState: Equatable {
        case unknown, loading, published, unpublished, unavailable(String)
    }
    @State private var publishState: PublishState = .unknown
    @State private var publishBusy = false

    private var isMine: Bool {
        !currentUserId.isEmpty && agent.author == currentUserId
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Text(agent.name)
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                        if agent.isPromoted == true {
                            Text("House pick")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.yellow.opacity(0.25), in: Capsule())
                        }
                    }
                    if let cat = agent.category, !cat.isEmpty {
                        Text(cat.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text((agent.description?.isEmpty == false)
                         ? agent.description!
                         : "No description yet — they prefer to introduce themselves.")
                        .font(.body)

                    Button {
                        onTalk(agent.id)
                    } label: {
                        Label("Talk to \(agent.name)", systemImage: "bubble.left.and.bubble.right.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Starts a fresh conversation with \(agent.name).")

                    if isMine {
                        publishSection
                    }
                    Spacer(minLength: 0)
                }
                .padding()
            }
            .navigationTitle(agent.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                        .accessibilityHint("Closes this character's card.")
                }
            }
            .task { if isMine { await readPublishState() } }
        }
    }

    private var publishSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your creation")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            switch publishState {
            case .unknown, .loading:
                Text("Checking marketplace status…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .unavailable(let why):
                Text(why)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .published:
                Text("Published — anyone on the platform can find and talk to \(agent.name).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    Task { await setPublished(false) }
                } label: {
                    if publishBusy { ProgressView() } else { Text("Take off the marketplace") }
                }
                .disabled(publishBusy)
                .accessibilityHint("Makes \(agent.name) private again — only you will see them.")
            case .unpublished:
                Text("Private — only you can see and talk to \(agent.name).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await setPublished(true) }
                } label: {
                    if publishBusy { ProgressView() } else { Text("Publish to the marketplace") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(publishBusy)
                .accessibilityHint("Puts \(agent.name) on the marketplace for everyone to find.")
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// GET the sharing state; leniently read a `public` flag from whatever
    /// shape comes back (top-level bool, or a principals list containing a
    /// "public" entry). Anything else -> honest "unavailable" copy.
    private func readPublishState() async {
        guard let mongoId = agent.mongoId, !mongoId.isEmpty else {
            publishState = .unavailable("Publishing controls aren't available for this character.")
            return
        }
        publishState = .loading
        let req = apiClient.request(path: "api/permissions/agent/\(mongoId)", authorized: true)
        guard let (data, http) = try? await apiClient.send(req), http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            publishState = .unavailable("Couldn't check marketplace status right now.")
            return
        }
        if let flag = obj["public"] as? Bool {
            publishState = flag ? .published : .unpublished
            return
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        publishState = text.contains("\"public\"") && text.contains("true") ? .published : .unpublished
    }

    private func setPublished(_ publish: Bool) async {
        guard let mongoId = agent.mongoId, !mongoId.isEmpty else { return }
        publishBusy = true
        defer { publishBusy = false }
        var req = apiClient.request(path: "api/permissions/agent/\(mongoId)", method: "PUT", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "public": publish,
            "publicAccessRoleId": "agent_viewer",
        ])
        guard let (_, http) = try? await apiClient.send(req), (200...299).contains(http.statusCode) else {
            UIAccessibility.post(notification: .announcement,
                                 argument: "That didn't go through. Publishing may not be enabled for your account.")
            return
        }
        publishState = publish ? .published : .unpublished
        UIAccessibility.post(notification: .announcement,
                             argument: publish
                                 ? "\(agent.name) is on the marketplace."
                                 : "\(agent.name) is private again.")
    }
}
