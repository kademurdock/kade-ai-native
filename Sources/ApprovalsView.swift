import SwiftUI
import UIKit

private struct ApprovalErrorReply: Decodable {
    let error: String?
}

/// Oct 16 2026: Kade's yes before Forge ships. ADMIN ONLY: the More tab shows
/// the row only to the admin seat, the "approvals" push opens it only there,
/// and the server answers 403 to anyone else (shown in plain words, never a
/// list).
///
/// Same shape as Agent work: a status line VoiceOver re-reads as it changes,
/// a Refresh button, one card per request. Each card is ONE VoiceOver element
/// (status words first, then the summary, what happened, the way to undo it,
/// and when), with Approve and Not now in the Actions rotor while it waits.
/// The visible buttons step aside for VoiceOver only, her standing rule;
/// Voice Control still reaches them by name.
struct ApprovalsView: View {
    let apiClient: KadeAPIClient
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn

    /// One alert for both questions (never two presentations on one view).
    private struct Decision: Identifiable {
        let item: KadeApproval
        let approve: Bool
        var id: String { item.id + (approve ? "-yes" : "-no") }
    }

    @State private var items: [KadeApproval] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var refused = false
    @State private var status = "Loading approvals…"
    @State private var asking: Decision?
    @State private var decidingId: String?
    @State private var loadWork: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Forge asks here before it ships: merging or committing code, deploying, or changing settings on Railway. Nothing happens until you say yes.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(status)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
                if !refused {
                    Button("Refresh") { refresh() }
                        .buttonStyle(.borderedProminent)
                        .disabled(loading || decidingId != nil)
                        .accessibilityLabel("Refresh approvals")
                        .accessibilityHint("Checks for new requests and how earlier ones went.")
                }

                if loaded && items.isEmpty && !refused {
                    Text("Nothing has been asked yet. When Forge needs your yes, it shows up here and you get a notification.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(items) { item in
                    card(item)
                }
                if !refused {
                    Text("About approvals").font(.headline).accessibilityAddTraits(.isHeader)
                    Text("A request you don't answer expires on its own, and nothing changes. Not now tells Forge no. Approving a merge can take a minute or two.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Approvals")
        .navigationBarTitleDisplayMode(.inline)
        .task { if !loaded { await load() } }
        .onDisappear { loadWork?.cancel() }
        .alert(
            askingTitle,
            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
            presenting: asking
        ) { decision in
            if decision.approve {
                Button("Approve") { decide(decision.item, approve: true) }
            } else {
                Button("Tell Forge no", role: .destructive) { decide(decision.item, approve: false) }
            }
            Button("Cancel", role: .cancel) { asking = nil }
        } message: { decision in
            Text(decision.approve
                 ? KadeApprovalWords.confirmMessage(decision.item)
                 : (decision.item.summary.isEmpty ? "Nothing will change." : decision.item.summary))
        }
    }

    private var askingTitle: String {
        asking?.approve == false ? "Tell Forge no?" : "Approve this?"
    }

    private func card(_ item: KadeApproval) -> some View {
        let waiting = item.isPending && decidingId != item.id
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(decidingId == item.id ? "Running…" : KadeApprovalWords.statusWords(item.status))
                    .font(.headline)
                Text(item.summary.isEmpty ? "A request from Forge" : item.summary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach([item.resultWords, item.deployWords, item.error].filter { !$0.isEmpty }, id: \.self) { line in
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
                if let undo = KadeApprovalWords.undoLine(item.revert) {
                    Text(undo)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let when = KadeApprovalWords.whenWords(item) {
                    Text(when).font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(decidingId == item.id
                ? "Running. " + KadeApprovalWords.spoken(item)
                : KadeApprovalWords.spoken(item))
            .accessibilityAddTraits(.isHeader)
            .accessibilityActions {
                if waiting && decidingId == nil {
                    Button("Approve") { asking = Decision(item: item, approve: true) }
                    Button("Not now") { asking = Decision(item: item, approve: false) }
                }
            }

            if waiting {
                HStack(spacing: 12) {
                    Button("Approve") { asking = Decision(item: item, approve: true) }
                        .buttonStyle(.borderedProminent)
                    Button("Not now") { asking = Decision(item: item, approve: false) }
                        .buttonStyle(.bordered)
                }
                .disabled(decidingId != nil)
                .accessibilityHidden(voiceOverOn)
            } else if decidingId == item.id {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Running. This can take a minute or two.").font(.subheadline)
                }
                .accessibilityHidden(true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func refresh() {
        loadWork = Task { await load() }
    }

    @MainActor
    private func load(quiet: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        status = loaded ? "Checking approvals…" : "Loading approvals…"
        if !quiet { KadeSoulSpeech.polite(status) }
        let request = apiClient.request(path: "api/kade/approvals", authorized: true)
        do {
            let (data, http) = try await apiClient.send(request)
            if http.statusCode == 403 {
                refused = true
                items = []
                status = "Approvals are only for the admin account."
                if !quiet { KadeSoulSpeech.polite(status) }
                return
            }
            guard http.statusCode == 200 else {
                status = http.statusCode == 401
                    ? "Please sign in again to check approvals."
                    : "Couldn't check approvals." + (loaded ? " The list below may be out of date." : "") + " Try Refresh."
                if !quiet { KadeSoulSpeech.polite(status) }
                return
            }
            guard let list = try? JSONDecoder().decode(KadeApprovalList.self, from: data) else {
                status = "Couldn't read approvals. Try Refresh."
                if !quiet { KadeSoulSpeech.polite(status) }
                return
            }
            items = list.approvals
            loaded = true
            status = KadeApprovalWords.statusLine(items)
            if !quiet { KadeSoulSpeech.polite(status) }
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                status = "Check approvals when you are ready."
                return
            }
            status = "Connection lost." + (loaded ? " The list below may be out of date." : "") + " Try Refresh when you are online."
            if !quiet { KadeSoulSpeech.polite(status) }
        }
    }

    /// Not cancelled when the screen goes away: a yes that is already on its
    /// way still gets its answer said.
    private func decide(_ item: KadeApproval, approve: Bool) {
        asking = nil
        guard decidingId == nil else { return }
        decidingId = item.id
        if approve {
            status = "Running. This can take a minute or two."
            KadeSoulSpeech.result(status)
        }
        Task { @MainActor in
            var request = apiClient.request(
                path: "api/kade/approvals/\(item.approvalId)/decide",
                method: "POST",
                authorized: true,
                timeout: 200
            )
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["decision": approve ? "approve" : "deny"])
            let spoken: String
            do {
                let (data, http) = try await apiClient.send(request)
                if http.statusCode == 200,
                   let updated = try? JSONDecoder().decode(KadeApproval.self, from: data),
                   !updated.approvalId.isEmpty {
                    if let index = items.firstIndex(where: { $0.id == updated.id }) { items[index] = updated }
                    spoken = approve ? KadeApprovalWords.approveOutcome(updated) : "Okay. Nothing changed."
                } else if http.statusCode == 409 {
                    let reply = try? JSONDecoder().decode(ApprovalErrorReply.self, from: data)
                    spoken = KadeApprovalWords.conflictWords(reply?.error)
                } else if http.statusCode == 403 {
                    spoken = "Only the admin account can answer approvals."
                } else {
                    spoken = approve
                        ? "Couldn't send your yes. Nothing was approved. Try again."
                        : "Couldn't send that. Forge is still waiting. Try again."
                }
            } catch {
                if approve && (error as? URLError)?.code == .timedOut {
                    spoken = "No answer yet. It may still be running. Refresh in a minute to see how it went."
                } else {
                    spoken = approve
                        ? "Couldn't reach the server. Refresh to see whether it went through."
                        : "Couldn't reach the server. Forge is still waiting. Try again."
                }
            }
            decidingId = nil
            await load(quiet: true)
            KadeSoulSpeech.result(spoken)
        }
    }
}
