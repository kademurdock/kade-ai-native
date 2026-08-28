import SwiftUI
import UniformTypeIdentifiers

/// Aug 28 2026 (her word, same session the /import web page shipped: "make
/// sure the import memories and any other new features are accessible
/// natively on the apps too") — the ChatGPT move-in door, native. Two lanes,
/// same four routes the web page rides (/api/kade/gpt-import/*):
///   1. Paste the memory list ChatGPT kept about you → one keeper pass →
///      shared memory cards.
///   2. Pick your ChatGPT export zip → conversations stored server-side →
///      optional toggle reads them into the logbook, dated to the days they
///      really happened.
/// VoiceOver-first: every state change lands in one polite live region, the
/// long-running read announces progress, and nothing here auto-fires — every
/// lane is a deliberate button press.
struct GptImportView: View {
    let apiClient: KadeAPIClient

    @State private var pastedMemories = ""
    @State private var pasteStatus = ""
    @State private var pasteBusy = false

    @State private var showPicker = false
    @State private var alsoMine = false
    @State private var zipStatus = ""
    @State private var zipBusy = false
    @State private var pollTask: Task<Void, Never>? = nil

    var body: some View {
        List {
            Section {
                Text("Moving in from ChatGPT? Your companions here can start out already knowing you. Two ways — use either or both.")
                    .font(.body)
            }

            Section("1. Paste your saved memories") {
                Text("In ChatGPT: Settings, Personalization, Manage memories — or just ask it to list everything it remembers about you. Copy it all, paste it here.")
                    .font(.callout)
                TextEditor(text: $pastedMemories)
                    .frame(minHeight: 140)
                    .accessibilityLabel("Your ChatGPT memory list")
                    .accessibilityHint("Paste the whole list here.")
                Button {
                    saveMemories()
                } label: {
                    Text(pasteBusy ? "Saving…" : "Save these as my memories")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(pasteBusy || pastedMemories.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
                if !pasteStatus.isEmpty {
                    Text(pasteStatus)
                        .font(.callout)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }

            Section("2. Upload your ChatGPT export") {
                Text("In ChatGPT: Settings, Data controls, Export data. ChatGPT emails you a zip — download it to this phone, then pick it here.")
                    .font(.callout)
                Toggle(isOn: $alsoMine) {
                    Text("Also read my old conversations into my logbook")
                }
                .accessibilityHint("Your companions will remember your life from back then. It takes a while and keeps going in the background.")
                Button {
                    showPicker = true
                } label: {
                    Text(zipBusy ? "Working…" : "Pick the zip and import")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(zipBusy)
                if !zipStatus.isEmpty {
                    Text(zipStatus)
                        .font(.callout)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }

            Section {
                Text("Your memories become the same kind of cards you can hear, fix, or forget on the Memories screen. Old conversations are read once by the platform's own memory keeper — no person reads them.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Bring ChatGPT memories")
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [UTType.zip]) { result in
            switch result {
            case .success(let url): Task { await uploadZip(url) }
            case .failure: announce(&zipStatus, "Couldn't open that file. Try again.")
            }
        }
        .onDisappear { pollTask?.cancel() }
    }

    private func announce(_ target: inout String, _ text: String) {
        target = text
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func saveMemories() {
        pasteBusy = true
        pasteStatus = "Saving…"
        let text = pastedMemories
        Task {
            defer { pasteBusy = false }
            do {
                var req = apiClient.request(path: "api/kade/gpt-import/memories", method: "POST", authorized: true)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
                let (data, http) = try await apiClient.send(req)
                if http.statusCode == 200 {
                    announce(&pasteStatus, "Saved. Your companions know you now — the cards are on the Memories screen.")
                } else {
                    let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                    announce(&pasteStatus, msg ?? "That didn't work. Try again.")
                }
            } catch {
                announce(&pasteStatus, "That didn't work. Try again.")
            }
        }
    }

    private func uploadZip(_ url: URL) async {
        zipBusy = true
        defer { zipBusy = false }
        announce(&zipStatus, "Uploading your export…")
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            announce(&zipStatus, "Couldn't read that file. Try again.")
            return
        }
        if data.count > 80 * 1024 * 1024 {
            announce(&zipStatus, "That export is bigger than 80 megabytes. Paste your memories instead, and tell Kade — a bigger door can be opened.")
            return
        }
        do {
            var req = apiClient.request(path: "api/kade/gpt-import/zip", method: "POST", authorized: true, timeout: 300)
            req.setValue("application/zip", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            let (respData, http) = try await apiClient.send(req)
            guard http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
                announce(&zipStatus, "The upload didn't go through. Try again.")
                return
            }
            let stored = obj["conversationsStored"] as? Int ?? 0
            let had = obj["alreadyHad"] as? Int ?? 0
            var msg = "\(stored) conversations stored." + (had > 0 ? " \(had) were already here." : "")
            if let memText = obj["memoryText"] as? String, !memText.isEmpty {
                var mreq = apiClient.request(path: "api/kade/gpt-import/memories", method: "POST", authorized: true)
                mreq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                mreq.httpBody = try JSONSerialization.data(withJSONObject: ["text": memText])
                _ = try? await apiClient.send(mreq)
                msg += " Found a memory file inside and saved it as cards."
            }
            if alsoMine && (stored > 0 || had > 0) {
                let sreq = apiClient.request(path: "api/kade/gpt-import/mine", method: "POST", authorized: true)
                _ = try? await apiClient.send(sreq)
                announce(&zipStatus, msg + " Now reading them into your logbook — you can leave this screen, it keeps going.")
                startPolling()
            } else {
                announce(&zipStatus, msg)
            }
        } catch {
            announce(&zipStatus, "The upload didn't go through. Try again.")
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                let req = apiClient.request(path: "api/kade/gpt-import/status", authorized: true)
                guard let (data, http) = try? await apiClient.send(req), http.statusCode == 200,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let run = obj["run"] as? [String: Any] else { continue }
                let running = run["running"] as? Bool ?? false
                let processed = run["processed"] as? Int ?? 0
                let total = run["total"] as? Int ?? 0
                let logged = run["entriesLogged"] as? Int ?? 0
                if running {
                    zipStatus = "Reading your conversations: \(processed) of \(total), \(logged) journal entries written so far."
                } else {
                    announce(&zipStatus, "All done reading. \(logged) journal entries written.")
                    break
                }
            }
        }
    }
}
