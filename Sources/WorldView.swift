import SwiftUI
import UIKit
import AVFoundation

/// Aug 8 2026 â€” THE WORLD SCREEN: her MUSHclient on the phone. A scrolling
/// log, a command line, quick buttons, earcons and haptics per event kind â€”
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
    /// Part 295: the expanded log shows the newest 80 lines; "Show earlier"
    /// reveals 80 more (the admin log's shape). The eager VStack lays out
    /// every shown line on each live append, so the window keeps that small.
    @State private var logWindow = 80
    private let logWindowStep = 80
    @State private var isVisible = false
    @AccessibilityFocusState private var focusedChoice: String?
    /// Build 195: the sound manifest â€” district (ward-bed) ambience urls and
    /// the district she currently stands in.
    @State private var districtSounds: [String: String] = [:]
    /// Build 197 â€” layer two: room-scoped tones, keyed by the roomId the
    /// engine now sends. The manifest has always had this scope; nothing
    /// could reach it until the room started saying its own name.
    @State private var roomSounds: [String: String] = [:]
    @State private var eventSounds: [String: String] = [:]
    @State private var soundProblem = false
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
        ("Town guide", "town", "Find activities and walking directions"),
        ("My notebook", "notebook", "Continue the free canal trail and your projects"),
        ("Inventory", "inventory", "What you are carrying"),
        ("Who", "who", "Who is here with you"),
        // Build 195 â€” the Reverie verbs, one tap each (Aug 10 city).
        ("Map", "map", "How this ward hangs together"),
        ("Status", "status", "How you are doing â€” fed, rested, coin"),
        ("Weather", "weather", "What the sky is doing"),
        ("Recap", "recap", "Replay your last meanwhile"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { _ in
                ScrollView {
                    /* Sep 26 2026 (Part 295, Amber A, build 316): this was a
                     * LazyVStack, the last one on a VoiceOver screen that also
                     * mutates its rows live. Half an hour into Reverie the
                     * main thread froze for over a minute and iOS killed the
                     * app (0x8BADF00D, stack all AttributeGraph/SwiftUICore
                     * inside a layout commit, no app frames). That is the
                     * build-225 transcript freeze exactly: radar FB21851974 /
                     * forums thread 814208, a lazy container allocating rows
                     * while a state write lands (the picture's onAppear, the
                     * live feed's appends) and VoiceOver walks the tree. Same
                     * medicine as the transcript, the admin log and the
                     * logbook: an eager VStack, a bounded log window, and no
                     * state write inside a layout pass. */
                    VStack(alignment: .leading, spacing: 6) {
                        if pictureOn, let picture, mode == "play" {
                            WorldPictureView(snapshot: picture,
                                motion: pictureMotion && !reduceMotion && !lowPowerMode && pictureVisible && scenePhase == .active && isVisible,
                                description: $pictureDescription)
                                .frame(height: 300)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .accessibilityHidden(true)
                                .allowsHitTesting(false)
                                .onAppear { DispatchQueue.main.async { pictureVisible = true } }
                                .onDisappear { DispatchQueue.main.async { pictureVisible = false } }
                                .modifier(WorldPictureScrollPause(visible: $pictureVisible))
                        }
                        if !latestReply.isEmpty {
                            Text("Latest reply").font(.headline).accessibilityAddTraits(.isHeader)
                            Text(latestReply).textSelection(.enabled)
                            Button("Read latest reply") { announce(latestReply) }
                                .buttonStyle(.bordered)
                        }
                        worldControls
                        DisclosureGroup("World log, \(log.count) entries", isExpanded: $logExpanded) {
                            if log.count > logWindow {
                                Button("Show \(min(logWindowStep, log.count - logWindow)) earlier entries") {
                                    logWindow += logWindowStep
                                }
                                .buttonStyle(.bordered)
                            }
                            ForEach(Array(log.suffix(logWindow))) { line in
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

            worldToolbar

            HStack(spacing: 8) {
                TextField("Command â€” look, n, take lantern, say hello", text: $command)
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
            WorldTones.shared.activate()
            if log.isEmpty {
                append("The gate knows you. Type look, or press the Look button.", .world)
                await send("look")
                startLiveIfNeeded()
            } else { startLiveIfNeeded() }
            await loadWorldSounds()
        }
        .onChange(of: liveOn) { _, enabled in if enabled { startLiveIfNeeded() } else { service.stopListening() } }
        .onChange(of: ambienceOn) { _, _ in Task { await refreshAmbience(); await refreshRoomTone() } }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && isVisible {
                WorldTones.shared.activate()
                startLiveIfNeeded()
                Task { if let result = await service.here() { updateControls(result) }; await loadWorldSounds() }
            } else { service.stopListening(); WorldTones.shared.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)) { _ in
            guard isVisible, scenePhase == .active else { return }
            Task { WorldTones.shared.activate(); await loadWorldSounds() }
        }
        .onDisappear {
            isVisible = false
            service.stopListening()
            WorldTones.shared.stop()
        }
    }

    private var worldToolbar: some View {
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
                    WorldTones.shared.activate()
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
            if soundProblem && soundsOn {
                Button("Retry sounds") {
                    Task { WorldTones.shared.activate(); await loadWorldSounds() }
                }.buttonStyle(.bordered)
                .accessibilityHint("Try loading the sounds for your current place again")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
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
            currentDistrict = room.district ?? result.district
            Task { await refreshAmbience(); await refreshRoomTone() }
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

    /// Build 195 â€” the sound manifest lands on native (the queued "195
    /// material"): fetch once per screen open, cache files locally, swap
    /// synth earcons for her real sounds where they exist, and start the
    /// ward-bed ambience for wherever she is standing.
    private func loadWorldSounds() async {
        guard let manifest = await service.fetchSoundManifest(), isVisible, !Task.isCancelled else { soundProblem = true; return }
        soundProblem = false
        soundVersions = manifest.versions ?? [:]
        eventSounds = manifest.event ?? [:]
        districtSounds = manifest.district ?? [:]
        roomSounds = manifest.room ?? [:]
        await refreshAmbience()
        await refreshRoomTone()
    }

    private func refreshAmbience() async {
        guard soundsOn, ambienceOn, isVisible, scenePhase == .active, let d = currentDistrict else {
            WorldTones.shared.setAmbience(key: nil, fileURL: nil)
            return
        }
        let room = currentRoomId
        let specific = picture?.room.sensory?.ambience
        let scope = specific.flatMap { eventSounds[$0] == nil ? nil : "event:" + $0 } ?? "district:" + d
        guard let urlStr = specific.flatMap({ eventSounds[$0] }) ?? districtSounds[d] else { return }
        let revision = soundVersions[scope]
        let local = await WorldService.cachedSoundFile(for: urlStr, revision: revision)
        guard soundsOn, ambienceOn, isVisible, scenePhase == .active, currentRoomId == room, currentDistrict == d else { return }
        if local == nil { soundProblem = true }
        WorldTones.shared.setAmbience(key: scope + urlStr + (revision ?? ""), fileURL: local)
    }

    private func refreshRoomTone() async {
        guard soundsOn, ambienceOn, isVisible, scenePhase == .active, let r = currentRoomId, let urlStr = roomSounds[r] else {
            WorldTones.shared.setRoomTone(key: nil, fileURL: nil)
            return
        }
        if let specific = picture?.room.sensory?.ambience, eventSounds[specific] == urlStr {
            WorldTones.shared.setRoomTone(key: nil, fileURL: nil)
            return
        }
        let local = await WorldService.cachedSoundFile(for: urlStr, revision: soundVersions["room:" + r])
        guard soundsOn, ambienceOn, isVisible, scenePhase == .active, currentRoomId == r else { return }
        if local == nil { soundProblem = true }
        WorldTones.shared.setRoomTone(key: r + urlStr + (soundVersions["room:" + r] ?? ""), fileURL: local)
    }

    private func playFeedback(_ kind: String) {
        guard isVisible, scenePhase == .active else { return }
        if soundsOn {
            if let url = eventSounds[kind] {
                let requested = Date()
                let room = currentRoomId
                Task {
                    let local = await WorldService.cachedSoundFile(for: url, revision: soundVersions["event:" + kind])
                    guard isVisible, scenePhase == .active, soundsOn, room == currentRoomId else { return }
                    if let local {
                        WorldTones.shared.installEventSound(kind: kind, fileURL: local)
                        if Date().timeIntervalSince(requested) < 2.5 { WorldTones.shared.play(kind) }
                        await WorldHapticsEngine.shared.installEnvelope(kind: kind, fileURL: local)
                    } else {
                        soundProblem = true
                        if Date().timeIntervalSince(requested) < 2.5 { WorldTones.shared.play(kind) }
                    }
                }
            } else { WorldTones.shared.play(kind) }
        }
        WorldHaptics.play(kind)
    }
}

/// Part 295: the room picture's motion still pauses once it scrolls out of
/// sight. The LazyVStack used to do that through onAppear/onDisappear; an
/// eager VStack fires those only when the picture is added or removed, so on
/// iOS 18 and later the scroll view says when it is on screen. iOS 17 keeps
/// animating while scrolled away, which costs battery, never a freeze. The
/// write waits for the next main-queue turn, never inside a layout pass.
private struct WorldPictureScrollPause: ViewModifier {
    @Binding var visible: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollVisibilityChange(threshold: 0.2) { shown in
                DispatchQueue.main.async { visible = shown }
            }
        } else {
            content
        }
    }
}
