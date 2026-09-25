import SwiftUI
import UIKit

/// LIBRARY REQUESTS on the phone (Sep 25 2026). Part 289 gave the website a
/// request panel and the phone none, while a filled request's push opens the
/// phone's Library tab. So the requests live here, under Add, on the same
/// `/api/kade/reading-room/requests` route with the same rules: only you and
/// the library owner see your requests, and an account outside the family
/// collection (App Review's included) meets no section at all, the way the
/// website hides its panel.
///
/// VoiceOver shape: each request is ONE element that says its title, its
/// status and any news; double-tap opens the item that filled it, or reads
/// the details. Everything else (add details, cancel) is in the Actions
/// rotor, her standing preference, with the same buttons on screen for sight.

struct RRRequestItem: Codable, Hashable { let id: String; let title: String }
struct RRRequestEntry: Codable, Hashable { let by: String?; let statusText: String?; let note: String? }
struct RRRequest: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let media: String?
    let clues: String?
    let status: String
    let statusText: String
    let version: Int?
    let unread: Bool?
    let mine: Bool?
    let requester: String?
    let history: [RRRequestEntry]?
    let item: RRRequestItem?
    let availabilityNote: String?

    /// Open requests can still take details or be cancelled by the person who made them.
    var isOpen: Bool { ["requested", "searching", "located"].contains(status) }
    /// The newest note written about it, by the owner or the requester.
    var latestNote: String? {
        guard let last = history?.last(where: { !($0.note ?? "").isEmpty }), let note = last.note else { return nil }
        return (last.by.map { "\($0): " } ?? "") + note
    }
}
struct RRRequestList: Codable {
    let requests: [RRRequest]
    let next: String?
    let admin: Bool?
    let canRequest: Bool?
    let unread: Int?
    let review: Int?
}
struct RRRequestResult: Codable { let request: RRRequest?; let duplicate: Bool? }

/// The request list, held by the Library screen so its count can be said at
/// the top of the shelf ("One of your library requests has news").
@MainActor
final class LibraryRequestsModel: ObservableObject {
    @Published private(set) var requests: [RRRequest] = []
    @Published private(set) var canRequest = false
    @Published private(set) var admin = false
    @Published private(set) var unread = 0
    @Published private(set) var review = 0
    @Published private(set) var next: String?
    /// The library owner can switch to everyone's open requests.
    @Published var everyone = false

    /// Silent unless this account may ask, owns the library, or already has requests.
    var visible: Bool { canRequest || admin || !requests.isEmpty }

    /// A failed load keeps what was shown; nobody hears an error about a list they never asked for.
    func reload(_ service: ReadingRoomService) async {
        guard let list = try? await service.libraryRequests(scope: admin && everyone ? "open" : "mine") else { return }
        requests = list.requests
        next = list.next
        admin = list.admin ?? false
        canRequest = list.canRequest ?? false
        unread = list.unread ?? 0
        review = list.review ?? 0
    }

    func more(_ service: ReadingRoomService) async {
        guard let before = next,
              let list = try? await service.libraryRequests(scope: admin && everyone ? "open" : "mine", before: before) else { return }
        requests.append(contentsOf: list.requests.filter { row in !requests.contains { $0.id == row.id } })
        next = list.next
    }
}

struct LibraryRequestsSection: View {
    let service: ReadingRoomService
    @ObservedObject var model: LibraryRequestsModel
    let announce: (String) -> Void
    let open: (String) -> Void
    @State private var title = ""
    @State private var media = ""
    @State private var clues = ""
    @State private var saving = false
    @State private var adding: RRRequest?
    @State private var addition = ""
    @State private var cancelling: RRRequest?

    var body: some View {
        if model.visible {
            if model.canRequest {
                Section {
                    Text("Ask for any book, recording or video for the family library, even if you only remember a little about it. You can also just tell the librarian. The library owner reviews every request, and you get an alert when yours is filled. Only you and the library owner see your requests.")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("Title, or a few words about it", text: $title).textFieldStyle(.roundedBorder)
                    TextField("Kind: book, radio show, movie… (optional)", text: $media).textFieldStyle(.roundedBorder)
                    TextField("What do you remember? (optional)", text: $clues, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1 ... 5)
                    Button(saving ? "Saving…" : "Save request") { Task { await save() } }
                        .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                } header: { Text("Ask the library for something").accessibilityAddTraits(.isHeader) }
            }
            Section {
                if model.admin {
                    Toggle("Show everyone's open requests", isOn: $model.everyone)
                        .onChange(of: model.everyone) { _, _ in Task { await model.reload(service) } }
                }
                if let summary {
                    Text(summary).font(.subheadline)
                }
                if model.requests.isEmpty {
                    Text(model.admin && model.everyone ? "No open requests." : "No requests yet.").foregroundStyle(.secondary)
                }
                ForEach(model.requests) { rq in row(rq) }
                if model.next != nil {
                    Button("More requests") { Task { await model.more(service) } }
                }
            } header: { Text(model.admin ? "Library requests" : "Your requests").accessibilityAddTraits(.isHeader) }
            .alert("Add details to \(adding?.title ?? "the request")", isPresented: Binding(get: { adding != nil }, set: { if !$0 { adding = nil } })) {
                TextField("What else do you remember?", text: $addition)
                Button("Save") { if let rq = adding { adding = nil; Task { await addDetails(rq) } } }
                Button("Cancel", role: .cancel) { adding = nil }
            }
            .confirmationDialog("Cancel your request for \(cancelling?.title ?? "this")?", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }), titleVisibility: .visible) {
                Button("Cancel the request", role: .destructive) { if let rq = cancelling { cancelling = nil; Task { await cancel(rq) } } }
                Button("Keep it", role: .cancel) { cancelling = nil }
            }
        }
    }

    private var summary: String? {
        var parts: [String] = []
        if model.admin && model.review > 0 {
            parts.append(model.review == 1 ? "One request has something new for you to review." : "\(model.review) requests have something new for you to review.")
        }
        if model.unread > 0 {
            parts.append(model.unread == 1 ? "One of your requests has a new update." : "\(model.unread) of your requests have a new update.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func canChange(_ rq: RRRequest) -> Bool { rq.mine == true && rq.isOpen }

    private func spoken(_ rq: RRRequest) -> String {
        var bits: [String] = []
        if rq.unread == true { bits.append("New update") }
        bits.append(rq.title)
        bits.append(rq.statusText)
        if let who = rq.requester, rq.mine != true, !who.isEmpty { bits.append("from \(who)") }
        if let item = rq.item { bits.append("filled by \(item.title)") }
        if let note = rq.availabilityNote, !note.isEmpty { bits.append(note) }
        return bits.joined(separator: ". ")
    }

    private func detailLine(_ rq: RRRequest) -> String {
        var bits: [String] = [rq.statusText]
        if rq.mine != true, let who = rq.requester, !who.isEmpty { bits.append("from \(who)") }
        if let note = rq.latestNote { bits.append(note) }
        return bits.joined(separator: " · ")
    }

    private func row(_ rq: RRRequest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((rq.unread == true ? "New: " : "") + rq.title).font(.headline)
            Text(detailLine(rq)).font(.subheadline).foregroundStyle(.secondary)
            HStack {
                if let item = rq.item {
                    Button("Open \(item.title)") { openItem(item, of: rq) }.font(.footnote)
                }
                if canChange(rq) {
                    Button("Add details") { addition = ""; adding = rq }.font(.footnote)
                    Button("Cancel") { cancelling = rq }.font(.footnote).foregroundStyle(.red)
                }
            }
            .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(rq))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(rq.item != nil ? "Opens it." : "Reads the details.")
        .accessibilityAction {
            if let item = rq.item { openItem(item, of: rq) } else { Task { await details(rq) } }
        }
        .accessibilityActions {
            if let item = rq.item { Button("Open \(item.title)") { openItem(item, of: rq) } }
            Button("Hear the details") { Task { await details(rq) } }
            if canChange(rq) {
                Button("Add details") { addition = ""; adding = rq }
                Button("Cancel this request") { cancelling = rq }
            }
        }
    }

    private func openItem(_ item: RRRequestItem, of rq: RRRequest) {
        open(item.id)
        if rq.unread == true { Task { _ = try? await service.libraryRequest(["action": "details", "id": rq.id]); await model.reload(service) } }
    }

    /// Reading the details also marks the news as heard, as opening it on the website does.
    private func details(_ rq: RRRequest) async {
        do {
            let r = try await service.libraryRequest(["action": "details", "id": rq.id])
            let card = r.request ?? rq
            var lines = ["\(card.title): \(card.statusText)."]
            if !(card.media ?? "").isEmpty { lines.append("Kind: \(card.media ?? "").") }
            if let clues = card.clues, !clues.isEmpty { lines.append((card.mine == true ? "What you remember: " : "What they remember: ") + clues) }
            if let note = card.latestNote, card.latestNote != card.clues { lines.append("Latest note, \(note)") }
            if let item = card.item { lines.append("Filled by \(item.title). Choose Open to play it.") }
            announce(lines.joined(separator: " "))
            await model.reload(service)
        } catch { announce(error.localizedDescription) }
    }

    private func save() async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return }
        saving = true
        defer { saving = false }
        do {
            let r = try await service.libraryRequest([
                "action": "create",
                "title": t,
                "media": media.trimmingCharacters(in: .whitespacesAndNewlines),
                "clues": clues.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
            title = ""; media = ""; clues = ""
            announce(r.duplicate == true
                     ? "You already have an open request called \(t), so nothing new was saved. Use Add details on that one instead."
                     : "Saved your request for \(t). The library owner will look at it, and you get an alert when it is filled.")
            await model.reload(service)
        } catch { announce(error.localizedDescription) }
    }

    private func addDetails(_ rq: RRRequest) async {
        let note = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        do {
            _ = try await service.libraryRequest(["action": "note", "id": rq.id, "note": note])
            addition = ""
            announce("Added to your request for \(rq.title).")
            await model.reload(service)
        } catch { announce(error.localizedDescription) }
    }

    private func cancel(_ rq: RRRequest) async {
        do {
            _ = try await service.libraryRequest(["action": "cancel", "id": rq.id])
            announce("Cancelled your request for \(rq.title).")
            await model.reload(service)
        } catch { announce(error.localizedDescription) }
    }
}
