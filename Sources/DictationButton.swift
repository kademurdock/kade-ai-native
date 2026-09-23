import SwiftUI
import UIKit

struct DictationButton: View {
    let apiClient: KadeAPIClient
    @Binding var text: String
    var fieldName: String
    @State private var showingRecorder = false

    var body: some View {
        Button { showingRecorder = true } label: {
            Label("Dictate", systemImage: "mic")
                .frame(minHeight: 32)
        }
        .accessibilityLabel("Dictate \(fieldName)")
        .accessibilityHint("Uses Kade-AI's voice transcription. Adds to your text so you can review it before saving.")
        .sheet(isPresented: $showingRecorder) {
            DictationSheet(apiClient: apiClient, fieldName: fieldName) { transcript in
                let current = text.trimmingCharacters(in: .whitespacesAndNewlines)
                text = current.isEmpty ? transcript : current + " " + transcript
            }
        }
    }
}

private struct DictationSheet: View {
    let fieldName: String
    let onTranscript: (String) -> Void
    @StateObject private var voice: VoiceService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var busy = false
    @State private var active = true
    @State private var status = "Tap Record, then Stop and transcribe."
    @State private var operation: Task<Void, Never>?
    @State private var timeLimit: Task<Void, Never>?

    init(apiClient: KadeAPIClient, fieldName: String, onTranscript: @escaping (String) -> Void) {
        self.fieldName = fieldName
        self.onTranscript = onTranscript
        _voice = StateObject(wrappedValue: VoiceService(client: apiClient))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text("Try this if your phone's keyboard mishears you. It uses the same transcription as Kade-AI voice messages. Review names before saving.")
                Text(status).accessibilityAddTraits(.updatesFrequently)
                Button {
                    guard !busy else { return }
                    busy = true
                    operation = Task {
                        if voice.isRecording { await finish() }
                        else {
                            let started = await voice.startRecording()
                            guard active, !Task.isCancelled else { discard(); return }
                            status = started ? "Recording. Tap Stop and transcribe when you're done." : voice.recordError ?? "Couldn't start recording."
                            busy = false
                            if started {
                                timeLimit = Task {
                                    try? await Task.sleep(for: .seconds(120))
                                    guard active, !Task.isCancelled, voice.isRecording, !busy else { return }
                                    timeLimit = nil
                                    busy = true
                                    await finish()
                                }
                            }
                        }
                    }
                } label: {
                    Label(voice.isRecording ? "Stop and transcribe" : busy ? "Transcribing…" : "Record",
                          systemImage: voice.isRecording ? "stop.fill" : "mic.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                Spacer()
            }
            .padding()
            .navigationTitle("Dictate \(fieldName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { active = false; discard(); dismiss() }
                }
            }
        }
        .onDisappear { active = false; discard() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { active = false; discard(); dismiss() }
        }
    }

    private func finish() async {
        timeLimit?.cancel()
        timeLimit = nil
        guard let url = voice.stopRecording() else { busy = false; return }
        status = "Transcribing…"
        do {
            let transcript = try await voice.transcribe(fileURL: url).trimmingCharacters(in: .whitespacesAndNewlines)
            guard active, !Task.isCancelled else { return }
            guard !transcript.isEmpty else { status = "Didn't catch that. Try again."; busy = false; return }
            onTranscript(transcript)
            UIAccessibility.post(notification: .announcement, argument: "Added to \(fieldName). Review it before saving.")
            dismiss()
        } catch {
            guard active, !Task.isCancelled else { return }
            status = "Couldn't transcribe that. Your draft is still here. Try again."
            busy = false
        }
    }

    private func discard() {
        operation?.cancel()
        timeLimit?.cancel()
        if let url = voice.stopRecording() { try? FileManager.default.removeItem(at: url) }
    }
}
