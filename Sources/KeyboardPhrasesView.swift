import SwiftUI

/// Aug 4 2026 — MY KEYBOARD PHRASES (her redesign of Kade Keys: "people
/// should be able to customise their own prompt library just like their
/// own dictionary, specific to things they say all the time instead of
/// canned crap"). Each account keeps its own short list; the Kade Keys
/// keyboard shows up to 12 of them as one-tap type-ins. Server contract:
/// GET/POST/DELETE /api/kade/keyboard-phrases (kadeKeyboardPhrase.js —
/// same pattern as the pronunciation dictionary, cap 30). Every
/// successful load or edit re-mirrors the list into the App Group so the
/// keyboard (which can never touch the network) always has the current
/// copy on its next activation.
///
/// Service folded into this file deliberately: it is three tiny calls
/// with exactly one consumer — splitting it out à la
/// PronunciationDictionaryService would be ceremony without benefit. If a
/// second consumer ever appears, lift it out then.
///
/// VoiceOver notes mirror PronunciationDictionaryView's proven patterns:
/// `.ignore` + explicit labels, Delete as both a rotor action and a
/// swipe action, one add field with a clearly-labeled Add button.
struct KeyboardPhrasesView: View {
    @MainActor
    final class PhrasesService: ObservableObject {
        struct Phrase: Identifiable, Decodable {
            let id: String
            let text: String
        }

        @Published var phrases: [Phrase] = []
        @Published var isLoading = false
        @Published var loadError: String?

        private let client: KadeAPIClient
        init(client: KadeAPIClient) { self.client = client }

        private struct ListResponse: Decodable { let phrases: [Phrase] }
        private struct AddResponse: Decodable { let phrase: Phrase }
        private struct ErrorResponse: Decodable { let error: String? }

        func load() async {
            isLoading = true
            defer { isLoading = false }
            do {
                let req = client.request(path: "api/kade/keyboard-phrases", authorized: true)
                let (data, http) = try await client.send(req)
                guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
                phrases = try JSONDecoder().decode(ListResponse.self, from: data).phrases
                loadError = nil
                mirror()
            } catch {
                loadError = "Couldn't load your phrases. Check your connection and try again."
            }
        }

        /// Returns a user-facing error message, or nil on success.
        func add(_ text: String) async -> String? {
            var req = client.request(path: "api/kade/keyboard-phrases", method: "POST", authorized: true)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
            do {
                let (data, http) = try await client.send(req)
                guard http.statusCode == 200 else {
                    let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data)
                    return decoded?.error ?? "Couldn't save that phrase."
                }
                let added = try JSONDecoder().decode(AddResponse.self, from: data).phrase
                if !phrases.contains(where: { $0.id == added.id }) {
                    phrases.append(added)
                }
                mirror()
                return nil
            } catch {
                return "Couldn't save that phrase. Check your connection."
            }
        }

        func delete(_ phrase: Phrase) async -> Bool {
            let req = client.request(
                path: "api/kade/keyboard-phrases/\(phrase.id)",
                method: "DELETE",
                authorized: true
            )
            guard let (_, http) = try? await client.send(req), http.statusCode == 200 else {
                return false
            }
            phrases.removeAll { $0.id == phrase.id }
            mirror()
            return true
        }

        /// The keyboard's offline copy — every mutation lands here too.
        private func mirror() {
            KadeKeysSharedStore.writeCustomPhrases(phrases.map(\.text))
        }
    }

    @StateObject private var service: PhrasesService
    @State private var draftPhrase = ""
    @State private var addError: String?
    @State private var hasLoaded = false
    @FocusState private var draftFocused: Bool

    init(apiClient: KadeAPIClient) {
        _service = StateObject(wrappedValue: PhrasesService(client: apiClient))
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    TextField("A phrase you say a lot", text: $draftPhrase)
                        .focused($draftFocused)
                        .submitLabel(.done)
                        .onSubmit { Task { await add() } }
                        .accessibilityLabel("New phrase")
                        .accessibilityHint("Type something you say all the time, then use the Add button.")
                    Button {
                        Task { await add() }
                    } label: {
                        Text("Add").bold()
                    }
                    .disabled(draftPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("Saves this phrase to your keyboard.")
                }
                if let addError {
                    Text(addError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Your phrases show up as one-tap buttons on the Kade Keys keyboard — the first twelve, in the order you added them. They're saved to your account, so a new phone keeps them.")
            }

            Section {
                if service.phrases.isEmpty && hasLoaded {
                    Text("No phrases yet. Until you add some, the keyboard shows its six starter phrases.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(service.phrases) { phrase in
                        Text(phrase.text)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(phrase.text)
                            .accessibilityActions {
                                Button("Delete phrase") { Task { await remove(phrase) } }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { await remove(phrase) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                Text("Your phrases")
            }
        }
        .navigationTitle("My Keyboard Phrases")
        .task {
            guard !hasLoaded else { return }
            await service.load()
            hasLoaded = true
        }
        .refreshable { await service.load() }
        .overlay {
            if service.isLoading && !hasLoaded {
                ProgressView("Loading your phrases…")
            } else if let error = service.loadError, service.phrases.isEmpty {
                VStack(spacing: 12) {
                    Text(error).multilineTextAlignment(.center)
                    Button("Try again") { Task { await service.load() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
    }

    private func add() async {
        let text = draftPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        addError = nil
        if let error = await service.add(text) {
            addError = error
            UIAccessibility.post(notification: .announcement, argument: error)
        } else {
            draftPhrase = ""
            draftFocused = true
            UIAccessibility.post(notification: .announcement, argument: "Added. It's on your keyboard now.")
        }
    }

    private func remove(_ phrase: PhrasesService.Phrase) async {
        if await service.delete(phrase) {
            UIAccessibility.post(notification: .announcement, argument: "Deleted.")
        } else {
            UIAccessibility.post(notification: .announcement, argument: "Couldn't delete that one. Try again.")
        }
    }
}
