import SwiftUI

/// A stable, requested description outside the decorative animation tree.
/// Unknown or changed portraits never inherit another character's description.
struct CharacterAppearanceButton: View {
    let agentID: String?
    @EnvironmentObject private var agents: AgentsService
    private struct Notice { let name: String; let text: String }
    @State private var notice: Notice?

    private var agent: KadeAgent? { agents.agents.first { $0.id == agentID } }
    private var description: String? {
        CharacterAppearance.description(agentID: agentID, avatarPath: agent?.avatar?.filepath)
    }

    var body: some View {
        Group {
            if let agent, let description {
                Button {
                    notice = Notice(name: agent.name, text: description)
                } label: {
                    Label("Describe character", systemImage: "person.crop.square")
                }
                .accessibilityLabel("Describe \(agent.name)'s appearance")
                .accessibilityHint("Reads a description of this character's appearance.")
            }
        }
        .alert("Appearance of \(notice?.name ?? "character")", isPresented: Binding(
            get: { notice != nil }, set: { if !$0 { notice = nil } }
        ), presenting: notice) { _ in
            Button("Done", role: .cancel) { notice = nil }
        } message: { shown in
            Text(shown.text)
        }
        .onChange(of: agentID) { _, _ in notice = nil }
        .onChange(of: agent?.avatar?.filepath) { _, _ in notice = nil }
    }
}
