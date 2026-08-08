import SwiftUI
import UIKit

/// Aug 8 2026 — THE WORLD SCREEN: her MUSHclient on the phone. A scrolling
/// log, a command line, quick buttons, earcons and haptics per event kind —
/// and no model between her and the ground (POST /api/world/command hits the
/// deterministic engine raw). VoiceOver-first the BASSLINE way: each reply
/// is announced ONCE as a compact sentence, the log stays quiet history for
/// browsing, earcons carry the texture. Dictation types into the command
/// field like anywhere else, so "take lantern" can be said, not typed.
struct WorldView: View {
    @StateObject private var service: WorldService
    @State private var log: [LogLine] = []
    @State private var command = ""
    @State private var history: [String] = []
    @State private var soundsOn = UserDefaults.standard.object(forKey: "kade.world.sounds") as? Bool ?? true
    @FocusState private var inputFocused: Bool

    init(apiClient: KadeAPIClient) {
        _service = StateObject(wrappedValue: WorldService(client: apiClient))
    }

    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let role: Role
        enum Role { case you, world, meanwhile, error }
    }

    private let quickCommands: [(label: String, cmd: String, hint: String)] = [
        ("Look", "look", "Describe where you are"),
        ("North", "n", "Go north"),
        ("South", "s", "Go south"),
        ("East", "e", "Go east"),
        ("West", "w", "Go west"),
        ("Inventory", "inventory", "What you are carrying"),
        ("Who", "who", "Who is here with you"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(log) { line in
                            Text(line.text)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(color(for: line.role))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .accessibilityLabel("World log")
                .onChange(of: log) { _, newValue in
                    if let last = newValue.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickCommands, id: \.cmd) { item in
                        Button(item.label) {
                            Task { await send(item.cmd) }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint(item.hint)
                    }
                    Button(soundsOn ? "Sounds on" : "Sounds off") {
                        soundsOn.toggle()
                        UserDefaults.standard.set(soundsOn, forKey: "kade.world.sounds")
                        if soundsOn { WorldTones.shared.play("say") }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Earcons that mark movement, pickups, speech, and arrivals.")
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }

            HStack(spacing: 8) {
                TextField("Command — look, n, take lantern, say hello", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .focused($inputFocused)
                    .onSubmit { Task { await sendTyped() } }
                    .accessibilityHint("Type or dictate one world command, then press go.")
                Button {
                    Task { await sendTyped() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || service.isSending)
                .accessibilityLabel("Do it")
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
        .navigationTitle("The World")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if log.isEmpty {
                append("The gate knows you. Type look, or press the Look button.", .world)
                await send("look")
            }
        }
        .onDisappear {
            WorldTones.shared.stop()
        }
    }

    private func color(for role: LogLine.Role) -> Color {
        switch role {
        case .you: return .blue
        case .world: return .primary
        case .meanwhile: return .orange
        case .error: return .red
        }
    }

    private func append(_ text: String, _ role: LogLine.Role) {
        log.append(LogLine(text: text, role: role))
        if log.count > 250 {
            log.removeFirst(log.count - 250)
        }
    }

    private func sendTyped() async {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        command = ""
        await send(cmd)
        inputFocused = true
    }

    private func send(_ cmd: String) async {
        append("> \(cmd)", .you)
        history.append(cmd)
        do {
            let result = try await service.send(command: cmd)
            var spoken: [String] = []
            for line in result.lines ?? [] {
                let isMeanwhile = line.hasPrefix("MEANWHILE")
                append(line, isMeanwhile ? .meanwhile : .world)
                spoken.append(
                    isMeanwhile
                        ? line.replacingOccurrences(of: "MEANWHILE (since your last turn): ", with: "While you were away: ")
                        : line
                )
            }
            if let room = result.room {
                let exits = room.exits.isEmpty ? "none" : room.exits.joined(separator: ", ")
                append("\(room.name). \(room.desc)", .world)
                var extras = "Exits: \(exits)."
                if !room.items.isEmpty {
                    extras += " Here: \(room.items.joined(separator: ", "))."
                }
                extras += room.people.isEmpty
                    ? " No one else here."
                    : " Present: \(room.people.joined(separator: ", "))."
                append(extras, .world)
                spoken.append("\(room.name). \(room.desc) \(extras)")
            }
            let kinds = result.kinds ?? []
            if result.ok != true && kinds.isEmpty {
                playFeedback("err")
            }
            for (i, kind) in kinds.enumerated() {
                let delay = Double(i) * 0.14
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    playFeedback(kind)
                }
            }
            let announcement = spoken.joined(separator: " ")
            if !announcement.isEmpty {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        } catch {
            append(error.localizedDescription, .error)
            playFeedback("err")
            UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
        }
    }

    private func playFeedback(_ kind: String) {
        if soundsOn {
            WorldTones.shared.play(kind)
        }
        WorldHaptics.play(kind)
    }
}
