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
    @State private var picture: WorldPictureSnapshot?
    @State private var pictureDescription = ""
    @State private var pictureVisible = false
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @AppStorage("kade.world.picture") private var pictureOn = true
    @AppStorage("kade.world.motion") private var pictureMotion = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hud: WorldHUD?
    @State private var choices: [WorldAction] = []
    @State private var actions: [WorldAction] = []
    @State private var exits: [WorldExit] = []
    @State private var people: [WorldPerson] = []
    @State private var creationStep: String?
    @State private var mode = "play"
    @State private var logExpanded = false
    @State private var isVisible = false
    @State private var speechBuffer = WorldSpeechBuffer()
    private var replying: Bool { speechBuffer.replying }
    @AccessibilityFocusState private var focusedChoice: String?
    /// Build 195: the sound manifest — district (ward-bed) ambience urls and
    /// the district she currently stands in.
    @State private var districtSounds: [String: String] = [:]
    @State private var eventSounds: [String: String] = [:]
    @State private var currentAmbience: String?
    /// Build 197 — layer two: room-scoped tones, keyed by the roomId the
    /// engine now sends. The manifest has always had this scope; nothing
    /// could reach it until the room started saying its own name.
    @State private var roomSounds: [String: String] = [:]
    @State private var soundVersions: [String: String] = [:]
    @State private var currentRoomId: String?
    @State private var currentDistrict: String?
    @FocusState private var inputFocused: Bool
    // Disabling the focused button makes VoiceOver announce its changed state
    // over the reply. Commands still serialize through the replying guard.
    private var controlsDisabled: Bool { replying && !UIAccessibility.isVoiceOverRunning }

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
                        if pictureOn, let picture, mode == "play" {
                            WorldPictureView(snapshot: picture,
                                motion: pictureMotion && !reduceMotion && !lowPowerMode && pictureVisible && scenePhase == .active && isVisible,
                                description: $pictureDescription)
                                .frame(height: 300)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .accessibilityHidden(true)
                                .allowsHitTesting(false)
                                .onAppear { pictureVisible = true }
                                .onDisappear { pictureVisible = false }
                        }
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
                        .disabled(controlsDisabled)
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
                .disabled(!UIAccessibility.isVoiceOverRunning && (command.trimmingCharacters(in: .whitespaces).isEmpty || replying))
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
            } else {
                startLiveIfNeeded()
                if let result = await service.here() { updateControls(result) }
                await loadWorldSounds()
            }
        }
        .onChange(of: liveOn) { _, enabled in if enabled { startLiveIfNeeded() } else { service.stopListening() } }
        .onChange(of: ambienceOn) { _, _ in Task { await refreshAmbience(); await refreshRoomTone() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && isVisible {
                startLiveIfNeeded()
                Task { if let result = await service.here() { updateControls(result) }; await refreshAmbience(); await refreshRoomTone() }
            } else { service.stopListening(); WorldTones.shared.stop() }
        }
        .onDisappear {
            isVisible = false
            speechBuffer.clearLive()
            service.stopListening()
            WorldTones.shared.stop()
        }
        .speechAnnouncementsQueued()
    }

    private var worldControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !choices.isEmpty {
                Text("Choose").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(choices) { action in
                    Button(action.label) { perform(action) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityFocused($focusedChoice, equals: action.id)
                        .disabled(controlsDisabled)
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
                            .buttonStyle(.bordered).disabled(controlsDisabled)
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
                        .disabled(controlsDisabled)
                    }
                }
                if !actions.isEmpty {
                    Text("Things you can do").font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(actions) { action in
                        Button(action.label) { perform(action) }
                            .buttonStyle(.bordered)
                            .accessibilityHint(action.hint ?? "")
                            .disabled(controlsDisabled)
                    }
                }
            }
            DisclosureGroup("World settings") {
                Toggle("Hear the room live", isOn: $liveOn)
                Text(service.liveStatus).font(.footnote)
                Toggle("Background ambience", isOn: $ambienceOn)
                Toggle("Room picture", isOn: $pictureOn)
                Toggle("World motion", isOn: $pictureMotion)
                    .disabled(reduceMotion)
                if reduceMotion { Text("World motion follows your Reduce Motion setting.").font(.footnote) }
                if pictureOn && !pictureDescription.isEmpty {
                    Button("Describe the picture") { announce(pictureDescription) }
                    Text(pictureDescription).font(.footnote)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func perform(_ action: WorldAction) {
        guard !replying else { return }
        if action.compose == true || action.cmd == "cab" || action.cmd == "pawn" || action.cmd.hasPrefix("whisper ") || action.cmd.hasPrefix("teach ") {
            guard command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                inputFocused = true
                announce("Your command field has a draft. Send or clear it first.")
                return
            }
            command = action.cmd.hasSuffix(" ") ? action.cmd : action.cmd + " "
            inputFocused = true
            announce("\(action.label). Add the details in the command field, then press go.")
        } else { Task { await send(action.cmd) } }
    }

    private func updateControls(_ result: WorldService.WorldResult) {
        if mode == "create" && result.step == nil && result.mode == "create" { return }
        if let h = result.hud { hud = h }
        if let room = result.room {
            picture = WorldPictureSnapshot(room: room.picture, hud: result.hud ?? hud)
            currentRoomId = room.roomId
            currentDistrict = room.district
            currentAmbience = room.sensory?.ambience
        }
        else if picture != nil {
            if let h = result.hud { picture?.hud = h }
            if let occupants = result.people { picture?.room.peopleDetail = occupants }
        }
        if let m = result.mode, m != "play" { picture = nil; pictureDescription = "" }
        if let m = result.mode { mode = m }
        actions = result.actions ?? actions
        exits = result.exits ?? exits
        people = result.people ?? people
        choices = result.choices ?? []
        if result.step != creationStep {
            creationStep = result.step
            // VoiceOver must finish the reply without a forced focus announcement.
            if !UIAccessibility.isVoiceOverRunning {
                if result.freeText == true && choices.isEmpty { inputFocused = true }
                else if let first = choices.first { Task { await Task.yield(); focusedChoice = first.id } }
            }
        }
    }

    private func announce(_ text: String) {
        guard isVisible, scenePhase == .active, !text.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
            string: text, attributes: [.accessibilitySpeechQueueAnnouncement: NSNumber(value: true)]))
    }

    private func startLiveIfNeeded() {
        guard liveOn, isVisible, scenePhase == .active else { return }
        service.startListening { events in
            guard isVisible else { return }
            for event in events { append(event.text, .meanwhile); playFeedback(event.sound ?? event.kind ?? "say") }
            let text = events.map(\.text).joined(separator: " ")
            // WorldService may flush its stream immediately before send returns.
            // The requested reply goes first; live speech queues behind it.
            if let ready = speechBuffer.receiveLive(text) { announce(ready) }
            if events.contains(where: { $0.kind == "enter" || $0.kind == "leave" }) {
                Task {
                    let roomId = currentRoomId
                    if let result = await service.here(), !replying, currentRoomId == roomId {
                        updateControls(result)
                    }
                }
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
        guard !cmd.isEmpty, !replying else { return }
        command = ""
        await send(cmd)
        if !UIAccessibility.isVoiceOverRunning { inputFocused = true }
    }

    private func send(_ cmd: String) async {
        guard speechBuffer.beginReply() else { return }
        var replySpeech = ""
        defer {
            announce(speechBuffer.finishReply(replySpeech))
        }
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
                let routes = result.exits ?? self.exits
                let destinations = routes.isEmpty ? room.exits : routes.map(\.spokenLabel)
                let exits = destinations.isEmpty ? "none" : destinations.joined(separator: "; ")
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
            if let d = result.district { currentDistrict = d }
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
            replySpeech = announcement
            // Downloads never hold up the command's spoken reply.
            Task { await refreshAmbience(); await refreshRoomTone() }
        } catch {
            append(error.localizedDescription, .error)
            playFeedback("err")
            if command.isEmpty { command = cmd }
            replySpeech = error.localizedDescription
        }
    }

    /// Build 195 — the sound manifest lands on native (the queued "195
    /// material"): fetch once per screen open, cache files locally, swap
    /// synth earcons for her real sounds where they exist, and start the
    /// ward-bed ambience for wherever she is standing.
    private func loadWorldSounds() async {
        guard let manifest = await service.fetchSoundManifest() else { return }
        soundVersions = manifest.versions ?? [:]
        eventSounds = manifest.event ?? [:]
        districtSounds = manifest.district ?? [:]
        roomSounds = manifest.room ?? [:]
        // Start the place before prewarming the 80+ incidental event sounds.
        await refreshAmbience()
        await refreshRoomTone()
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
    }

    private func refreshAmbience() async {
        let profile = currentAmbience
        let d = currentDistrict
        let specific = profile.flatMap { eventSounds[$0] }
        let urlStr = specific ?? d.flatMap { districtSounds[$0] }
        let key = specific != nil ? "event:" + (profile ?? "") : "district:" + (d ?? "")
        guard soundsOn, ambienceOn, isVisible, scenePhase == .active, let urlStr else {
            WorldTones.shared.setAmbience(key: nil, fileURL: nil)
            return
        }
        let local = await WorldService.cachedSoundFile(for: urlStr, revision: soundVersions[key])
        guard soundsOn, ambienceOn, isVisible, scenePhase == .active, currentDistrict == d, currentAmbience == profile else { return }
        WorldTones.shared.setAmbience(key: key, fileURL: local)
    }

    private func refreshRoomTone() async {
        guard soundsOn, ambienceOn, isVisible, scenePhase == .active, let r = currentRoomId, let urlStr = roomSounds[r], urlStr != currentAmbience.flatMap({ eventSounds[$0] }) else {
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
