import SwiftUI
import UIKit

/// Session 26, leftovers item 9: share / export a conversation. Two honest
/// halves, both server-contract-read off the fork's share.js:
///
/// PUBLIC LINK -- POST /api/share/:conversationId mints (GET
/// /api/share/link/:conversationId reads, DELETE /api/share/:shareId
/// revokes). The link shows the conversation as it stands when opened --
/// the web's own share semantics, said plainly in the status line so
/// nobody thinks they shared a frozen snapshot.
///
/// EXPORT -- a plain-text transcript (speaker: line, timestamped),
/// written to a temp file and handed to the proven ShareSheet, so it
/// lands wherever she points it: Files, AirDrop, Messages, mail.
/// readableText per line -- what VoiceOver reads is what exports.
///
/// Presented as a SHEET from the conversation list's row actions. Root of
/// its own NavigationStack, so it carries an explicit Close button -- the
/// session-17 rule: no screen without an accessible way out.
struct ShareExportView: View {
    @EnvironmentObject private var conversationsService: ConversationsService
    @EnvironmentObject private var apiClient: KadeAPIClient
    @Environment(\.dismiss) private var dismiss

    let conversation: KadeConversation

    @State private var shareId: String?
    @State private var checked = false
    @State private var working = false
    @State private var exportItem: ShareItem?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(statusLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(statusLine)

                    Button {
                        Task { await copyLink() }
                    } label: {
                        Label(shareId == nil ? "Create and copy a public link" : "Copy the public link",
                              systemImage: "link")
                    }
                    .disabled(working || !checked)
                    .accessibilityHint("Anyone you give the link to can read this conversation in a browser, no account needed.")

                    if shareId != nil {
                        Button(role: .destructive) {
                            Task { await stopSharing() }
                        } label: {
                            Label("Stop sharing", systemImage: "link.badge.plus")
                        }
                        .disabled(working)
                        .accessibilityHint("Turns the public link off. Anyone holding it loses access.")
                    }
                } header: {
                    Text("Public link")
                }

                Section {
                    Button {
                        Task { await exportText() }
                    } label: {
                        Label("Export as a text file", systemImage: "square.and.arrow.up")
                    }
                    .disabled(working)
                    .accessibilityHint("Builds a plain-text transcript and opens the share sheet — save it to Files, AirDrop it, or send it.")
                } header: {
                    Text("Export")
                } footer: {
                    Text("The transcript reads exactly like the chat does: who spoke, what they said, and when.")
                }
            }
            .navigationTitle(conversation.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                        .accessibilityHint("Closes sharing options. Nothing else changes.")
                }
            }
            .task {
                shareId = await conversationsService.existingShare(conversationId: conversation.id)
                checked = true
            }
            .sheet(item: $exportItem) { item in
                ShareSheet(item: item)
            }
        }
    }

    private var statusLine: String {
        if !checked { return "Checking whether this conversation is shared…" }
        if shareId != nil {
            return "This conversation HAS a public link. Anyone with it sees the conversation as it stands when they open it, newest messages included."
        }
        return "Not shared. Only you can read this conversation."
    }

    private func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func copyLink() async {
        working = true
        defer { working = false }
        var id = shareId
        if id == nil {
            id = await conversationsService.createShare(conversationId: conversation.id)
        }
        guard let id else {
            KadeHaptics.error()
            announce("Couldn't create the link. Try again.")
            return
        }
        shareId = id
        let url = apiClient.baseURL.appendingPathComponent("share/\(id)")
        UIPasteboard.general.string = url.absoluteString
        KadeHaptics.success()
        announce("Public link copied to the clipboard.")
    }

    private func stopSharing() async {
        guard let id = shareId else { return }
        working = true
        defer { working = false }
        if await conversationsService.revokeShare(shareId: id) {
            shareId = nil
            KadeHaptics.success()
            announce("Sharing stopped. The link no longer works.")
        } else {
            KadeHaptics.error()
            announce("Couldn't stop sharing. Try again.")
        }
    }

    private func exportText() async {
        working = true
        defer { working = false }
        guard let messages = try? await conversationsService.fetchMessages(conversationId: conversation.id) else {
            KadeHaptics.error()
            announce("Couldn't load the conversation to export it. Try again.")
            return
        }
        var lines: [String] = []
        lines.append("Conversation: \(conversation.displayTitle)")
        lines.append("Exported from Kade-AI")
        lines.append("")
        for message in messages {
            let body = message.readableText
            guard !body.isEmpty else { continue }
            let time = KadeDateFormatting.time(from: message.createdAt).map { " (\($0))" } ?? ""
            lines.append("\(message.speakerLabel)\(time): \(body)")
            lines.append("")
        }
        let text = lines.joined(separator: "\n")
        let safeName = conversation.displayTitle
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
            .prefix(60)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName.isEmpty ? "Conversation" : String(safeName)).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportItem = ShareItem(fileURL: url)
        } catch {
            KadeHaptics.error()
            announce("Couldn't write the transcript file. Try again.")
        }
    }
}
