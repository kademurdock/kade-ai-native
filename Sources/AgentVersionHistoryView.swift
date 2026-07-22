import SwiftUI
import UIKit

/// Agent Builder Phase 4 — version history + restore. Pushed from the
/// editor (the editor sheet owns its own NavigationStack, so a push gets a
/// real back chevron for free — no close-button trap possible here).
///
/// Server truth this view leans on (read off the fork's own
/// `revertAgentVersionHandler` + `updateAgent`): every save pushes the
/// PRE-save snapshot onto `versions` (oldest first), and a restore is
/// itself a new save — so restoring can never destroy anything; the state
/// being replaced just becomes the newest history entry.
struct AgentVersionHistoryView: View {
    let apiClient: KadeAPIClient
    let agentId: String
    /// Oldest-first, exactly as the server stores them — rows display
    /// newest-first, and `version_index` sent on restore is the TRUE index
    /// into this array, not the display order.
    let versions: [AgentVersion]
    /// Tells the editor to reload its fields after a successful restore.
    let onReverted: () -> Void

    @StateObject private var service: AgentBuilderService
    @Environment(\.dismiss) private var dismiss

    init(
        apiClient: KadeAPIClient,
        agentId: String,
        versions: [AgentVersion],
        onReverted: @escaping () -> Void
    ) {
        self.apiClient = apiClient
        self.agentId = agentId
        self.versions = versions
        self.onReverted = onReverted
        _service = StateObject(wrappedValue: AgentBuilderService(client: apiClient))
    }

    @State private var confirmingIndex: Int?
    @State private var isReverting = false
    @State private var revertError: String?

    var body: some View {
        List {
            if versions.isEmpty {
                Section {
                    Text("No earlier versions yet. Every time you save changes, the version you replaced lands here.")
                }
            } else {
                Section {
                    // Newest first for reading; the tag carries the real index.
                    ForEach(Array(versions.enumerated()).reversed(), id: \.offset) { index, version in
                        Button {
                            confirmingIndex = index
                        } label: {
                            row(index: index, version: version)
                        }
                        .buttonStyle(.plain)
                        .disabled(isReverting)
                        // Session 26, the Amber rule (build 139 / df915e2): no
                        // children:.ignore on a Button — costs direct VoiceOver
                        // activation. Label + hint stay; native flatten.
                        .accessibilityLabel(accessibleLabel(index: index, version: version))
                        .accessibilityHint("Restores this version. Your current setup becomes a new history entry, so nothing is lost.")
                    }
                } footer: {
                    Text("Tap a version to restore it. The setup you're replacing is kept as the newest entry here, so restoring is always undoable.")
                }
            }
            if let revertError {
                Section { Text(revertError).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Version history")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Restore this version?",
            isPresented: Binding(
                get: { confirmingIndex != nil },
                set: { if !$0 { confirmingIndex = nil } }
            ),
            presenting: confirmingIndex
        ) { index in
            Button("Restore") {
                Task { await revert(to: index) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { index in
            Text("Restores \(label(for: index)). Your current setup is saved as a new history entry first.")
        }
    }

    private func row(index: Int, version: AgentVersion) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label(for: index))
                .font(.body)
            Text(summary(for: version))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func label(for index: Int) -> String {
        "Version \(index + 1)\(index == versions.count - 1 ? " (most recent)" : "")"
    }

    private func summary(for version: AgentVersion) -> String {
        var parts: [String] = []
        if let name = version.name, !name.isEmpty { parts.append(name) }
        if let model = version.model, !model.isEmpty { parts.append(model) }
        if let when = Self.friendlyDate(version.updatedAt) { parts.append(when) }
        return parts.isEmpty ? "No details recorded" : parts.joined(separator: " · ")
    }

    private func accessibleLabel(index: Int, version: AgentVersion) -> String {
        "\(label(for: index)). \(summary(for: version))"
    }

    private func revert(to index: Int) async {
        guard !isReverting else { return }
        isReverting = true
        revertError = nil
        defer { isReverting = false }
        do {
            _ = try await service.revertAgent(id: agentId, versionIndex: index)
            UIAccessibility.post(
                notification: .announcement,
                argument: "Restored \(label(for: index)). Going back to the editor."
            )
            onReverted()
            dismiss()
        } catch {
            revertError = (error as? AgentBuilderService.AgentBuilderError)?.message ?? "Couldn't restore that version. Try again."
        }
        confirmingIndex = nil
    }

    /// ISO date string -> "July 20 at 2:15 PM" (device locale/zone). Falls
    /// back to nothing rather than showing a raw ISO stamp.
    static func friendlyDate(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: iso) ?? {
            parser.formatOptions = [.withInternetDateTime]
            return parser.date(from: iso)
        }()
        guard let date else { return nil }
        let out = DateFormatter()
        out.dateFormat = "MMMM d 'at' h:mm a"
        return out.string(from: date)
    }
}
