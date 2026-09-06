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
    @AppStorage("kade.world.ambience") private var ambienceOn = true
    @AppStorage("kade.world.live") private var liveOn = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var latestReply = ""
    @State private var hud: WorldHUD?
    @State private var choices: [WorldAction] = []
    @State private var actions: [WorldAction] = []
    @State private var exits: [WorldExit] = []
    @State private var people: [WorldPerson] = []
    @State private var creationStep: String?
    @State private var mode = "play"
    @State private var logExpanded = false
    @State private var isVisible = false
    @AccessibilityFocusState private var focusedChoice: String?
    /// Build 195: the sound manifest — district (ward-bed) ambience urls and
    /// the district she currently stands in.
    @State private var districtSounds: [String: String] = [:]
    /// Build 197 — layer two: room-scoped tones, keyed by the roomId the
    /// engine now sends. The manifest has always had this scope; nothing
    /// could reach it until the room started saying its own name.
    @State private var roomSounds: [String: String] = [:]
    @State private var soundVersions: [String: String] = [:]
    @State private var currentRoomId: String?
    @State private var currentDistrict: String?
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
        ("Inventory", "inventory", "What you are carrying"),
        ("Who", "who", "Who is here with you"),
        // Build 195 — the Reverie verbs, one tap each (Aug 10 city).
        ("Map", "map", "How this ward hangs together"),
        ("Status", "status", "How you are doing — fed, rested, coin"),
        ("Weather", "weather", "What the sky is doing"),
        ("Recap", "recap", "Replay your last meanwhile"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { _ in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if !latestReply.isEmpty {
                            Text("Latest reply").font(.headline).accessibilityAddTraits(.isHeader)
                            Text(latestReply).textSelection(.enabled)
                            Button("Read latest reply") { announce(latestReply) }
                                .buttonStyle(.bordered)
                        }
                        worldControls
                        DisclosureGroup("World log, \(log.count) entries", isExpanded: $logExpanded) {
                            ForEach(log) { line in
                                Text(line.text)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(color(for: line.role))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .accessibilityLabel("Reverie")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(quickCommands, id: \.cmd) { item in
                        Button(item.label) {
                            Task { await send(item.cmd) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(service.isSending)
                        .accessibilityHint(item.hint)
                    }
                    Button(soundsOn ? "Sounds on" : "Sounds off") {
                        soundsOn.toggle()
                        UserDefaults.standard.set(soundsOn, forKey: "kade.world.sounds")
                        if soundsOn {
                            WorldTones.shared.play("say")
                            Task {
                                await refreshAmbience()
                                await refreshRoomTone()
                            }
                        } else {
                            WorldTones.shared.setAmbience(key: nil, fileURL: nil)
                            WorldTones.shared.setRoomTone(key: nil, fileURL: nil)
                        }
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
            isVisible = true
            if log.isEmpty {
                append("The gate knows you. Type look, or press the Look button.", .world)
                await send("look")
                startLiveIfNeeded()
                await loadWorldSounds()
            } else { startLiveIfNeeded() }
        }
        .onChange(of: liveOn) { _, enabled in if enabled { startLiveIfNeeded() } else { service.stopListening() } }
        .onChange(of: ambienceOn) { _, _ in Task { await refreshAmbience(); await refreshRoomTone() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && isVisible {
                startLiveIfNeeded()
                Task { if let result = await service.here() { updateControls(result) }; await refreshAmbience(); await refreshRoomTone() }
            } else { service.stopListening(); WorldTones.shared.stop() }
        }
        .onDisappear {
            isVisible = false
            service.stopListening()
            WorldTones.shared.stop()
        }
    }

    private var worldControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !choices.isEmpty {
                Text("Choose").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(choices) { action in
                    Button(action.label) { Task { await send(action.cmd) } }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityFocused($focusedChoice, equals: action.id)
                        .disabled(service.isSending)
                }
            }
            if mode != "create" {
                if let hud {
                    DisclosureGroup("Your character: \(hud.name ?? "you"), $\(hud.coin ?? 0), feeling \(hud.mood ?? "okay")") {
                        VStack(alignment: .leading, spacing: 10) {
                            if let clock = hud.clock { Text(clock) }
                            ForEach(hud.meters ?? []) { meter in
                                VStack(alignment: .leading) {
                                    Text("\(meter.key.capitalized): \(meter.spokenValue)")
                                    ProgressView(value: min(100, max(0, meter.value)), total: 100).accessibilityHidden(true)
                                }
                            }
                            if let hint = hud.hint { Text(hint) }
                            if let home = hud.home { Text("Home: \(home)") }
                            if let partner = hud.partner { Text("Partner: \(partner)") }
                        }
                    }
                }
                if !exits.isEmpty {
                    Text("Move").font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(exits) { exit in
                        Button(exit.spokenLabel) { Task { await send(exit.command) } }
                            .buttonStyle(.bordered).disabled(service.isSending)
                    }
                }
                if !actions.isEmpty {
                    Text("Things you can do").font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(actions) { action in
                        Button(action.label) { perform(action) }
                            .buttonStyle(.bordered)
                            .accessibilityHint(action.hint ?? "")
                            .disabled(service.isSending)
                    }
                }
                if !people.isEmpty {
                    Text("Here with you").font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(people) { person in
                        Menu {
                            ForEach(person.cmds ?? []) { action in
                                Button(action.label) { perform(action) }
                            }
                        } label: { Text(person.line ?? person.name) }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Actions with \(person.name)")
                        .disabled(service.isSending)
                    }
                }
            }
            DisclosureGroup("World settings") {
                Toggle("Hear the room live", isOn: $liveOn)
                Text(service.liveStatus).font(.footnote)
                Toggle("Background ambience", isOn: $ambienceOn)
            }
        }
        .padding(.vertical, 8)
    }

    private func perform(_ action: WorldAction) {
        if action.cmd == "cab" || action.cmd == "pawn" || action.cmd.hasPrefix("whisper ") || action.cmd.hasPrefix("teach ") {
            command = action.cmd + " "
            inputFocused = true
            announce("\(action.label). Add the details in the command field, then press go.")
        } else { Task { await send(action.cmd) } }
    }

    private func updateControls(_ result: WorldService.WorldResult) {
        if mode == "create" && result.step == nil && result.mode == "create" { return }
        if let h = result.hud { hud = h }
        if let m = result.mode { mode = m }
        actions = result.actions ?? actions
        exits = result.exits ?? exits
        people = result.people ?? people
        choices = result.choices ?? []
        if result.step != creationStep {
            creationStep = result.step
            if result.freeText == true && choices.isEmpty { inputFocused = true }
            else if let first = choices.first { Task { await Task.yield(); focusedChoice = first.id } }
        }
    }

    private func announce(_ text: String) {
        guard isVisible, scenePhase == .active, !text.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func startLiveIfNeeded() {
        guard liveOn, isVisible, scenePhase == .active else { return }
        service.startListening { events in
            guard isVisible else { return }
            for event in events { append(event.text, .meanwhile); playFeedback(event.sound ?? event.kind ?? "say") }
            announce(events.map(\.text).joined(separator: " "))
            if events.contains(where: { $0.kind == "enter" || $0.kind == "leave" }) {
                Task { if let result = await service.here() { updateControls(result) } }
            }
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
        guard !cmd.isEmpty, !service.isSending else { return }
        command = ""
        await send(cmd)
        inputFocused = true
    }

    private func send(_ cmd: String) async {
        guard !service.isSending else { return }
        append("> \(cmd)", .you)
        history.append(cmd)
        if history.count > 60 { history.removeFirst(history.count - 60) }
        do {
            let result = try await service.send(command: cmd)
            updateControls(result)
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
            let d = result.district ?? result.room?.district
            if let d, d != currentDistrict {
                currentDistrict = d
                await refreshAmbience()
            }
            if let r = result.room?.roomId, r != currentRoomId {
                currentRoomId = r
                await refreshRoomTone()
            }
            let kinds = result.kinds ?? []
            if result.ok != true && kinds.isEmpty {
                playFeedback("err")
            }
            for (i, kind) in kinds.prefix(6).enumerated() {
                let delay = Double(i) * 0.14
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    playFeedback(kind)
                }
            }
            let announcement = spoken.joined(separator: " ")
            latestReply = announcement
            if !announcement.isEmpty {
                announce(announcement)
            }
        } catch {
            append(error.localizedDescription, .error)
            playFeedback("err")
            if command.isEmpty { command = cmd }
            announce(error.localizedDescription)
        }
    }

    /// Build 195 — the sound manifest lands on native (the queued "195
    /// material"): fetch once per screen open, cache files locally, swap
    /// synth earcons for her real sounds where they exist, and start the
    /// ward-bed ambience for wherever she is standing.
    private func loadWorldSounds() async {
        guard let manifest = await service.fetchSoundManifest() else { return }
        soundVersions = manifest.versions ?? [:]
        for (kind, urlStr) in manifest.event ?? [:] {
            if Task.isCancelled || !isVisible { return }
            if let local = await WorldService.cachedSoundFile(for: urlStr, revision: soundVersions["event:" + kind]) {
                WorldTones.shared.installEventSound(kind: kind, fileURL: local)
                // Build 197: the same file, measured for its haptic shape.
                // Sound and touch are installed together from one source, so
                // they can never end up describing two different events.
                await WorldHapticsEngine.shared.installEnvelope(kind: kind, fileURL: local)
            }
        }
        districtSounds = manifest.district ?? [:]
        roomSounds = manifest.room ?? [:]
        await refreshAmbience()
        await refreshRoomTone()
    }

    private func refreshAmbience() async {
        guard soundsOn, ambienceOn, isVisible, scenePhase == .active, let d = currentDistrict, let urlStr = districtSounds[d] else {
            WorldTones.shared.setAmbience(key: nil, fileURL: nil)
            return
        }
        let local = await WorldService.cachedSoundFile(for: urlStr, revision: soundVersions["district:" + d])
        guard soundsOn, ambienceOn, isVisible, scenePhase == .active, currentDistrict == d else { return }
        WorldTones.shared.setAmbience(key: d, fileURL: local)
    }

    private func refreshRoomTone() async {
        guard soundsOn, ambienceOn, isVisible, scenePhase == .active, let r = currentRoomId, let urlStr = roomSounds[r] else {
            WorldTones.shared.setRoomTone(key: nil, fileURL: nil)
            return
        }
        let local = await WorldService.cachedSoundFile(for: urlStr, revision: soundVersions["room:" + r])
        guard soundsOn, ambienceOn, isVisible, scenePhase == .active, currentRoomId == r else { return }
        WorldTones.shared.setRoomTone(key: r, fileURL: local)
    }

    private func playFeedback(_ kind: String) {
        guard isVisible, scenePhase == .active else { return }
        if soundsOn {
            WorldTones.shared.play(kind)
        }
        WorldHaptics.play(kind)
    }
}
