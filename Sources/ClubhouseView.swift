import SwiftUI
import WebKit
import UniformTypeIdentifiers

/// KADE'S CLUBHOUSE — the pure-native room (July 24 2026, replacing the
/// WebKit doorway from build 154). SwiftUI end to end: rooms, roster with
/// talking states, the shared jukebox, the Hotel's hidden passcode rooms,
/// and companion guests. The only WebKit left is the invisible 1-point
/// ClubhouseEngine that publishes music/bot audio (see its header for the
/// libwebrtc why) — it renders nothing and VoiceOver never meets it.
struct ClubhouseView: View {
    @StateObject private var service: ClubhouseService

    @State private var hotelCode = ""
    @State private var newRoomName = ""
    @State private var newRoomCode = ""
    @State private var tableCode = ""
    @State private var pickedAgentId = ""
    @State private var showFilePicker = false
    @State private var pendingSongURL: URL?
    @State private var showAddChoice = false
    @State private var roomPendingClose: ClubHotelRoom?
    @State private var showCloseConfirm = false
    @State private var showClearConfirm = false
    @State private var seekPos: Double = 0
    @State private var seekEditing = false
    @State private var showLeaveWhileTaping = false
    @State private var showCompanionPicker = false
    @State private var songLink = ""
    @State private var showLinkChoice = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(apiClient: KadeAPIClient) {
        _service = StateObject(wrappedValue: ClubhouseService(client: apiClient))
    }

    var body: some View {
        Group {
            if service.phase == .inRoom {
                roomScreen
            } else {
                pickerScreen
            }
        }
        .navigationTitle("Kade's Clubhouse")
        .navigationBarTitleDisplayMode(.inline)
        .background(
            EngineHostView(engine: service.engine, up: service.engineUp)
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .accessibilityHidden(true)
        )
        .task { await service.loadConfig() }
        .onDisappear { service.leave() }
    }

    // ── the picker ──
    private var pickerScreen: some View {
        List {
            Section {
                Text(service.statusLine)
                    .font(.callout)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Section {
                ForEach(service.publicRooms) { room in
                    Button {
                        Task { await service.join(roomKey: room.key, label: room.name, code: nil) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(room.name)
                            Text(room.blurb)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(service.phase == .joining)
                    .accessibilityLabel("\(room.name). \(room.blurb)")
                    .accessibilityHint("Joins the room with your mic live.")
                }
            } header: {
                Text("Rooms")
            } footer: {
                Text("Live family voice rooms with real stereo. Person to person on Kade's own room server — a companion only ever hears a room you invited them into.")
            }
            Section {
                TextField("Your group's passcode", text: $hotelCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Check in") {
                    let code = hotelCode
                    hotelCode = ""
                    Task { await service.checkIn(code: code) }
                }
                .disabled(service.phase == .joining)
                .accessibilityHint("Finds the private room that answers to that passcode and walks you in.")
                ForEach(service.myHotelRooms) { r in
                    HStack {
                        Text(r.name)
                        Spacer()
                        Button("Close", role: .destructive) {
                            roomPendingClose = r
                            showCloseConfirm = true
                        }
                        .accessibilityLabel("Close \(r.name) for good")
                    }
                }
            } header: {
                Text("The Hotel — private rooms")
            } footer: {
                Text("Rooms stay off the list on purpose — the code is the key. Check in with your group's passcode, or open a room below and pass the code around. A Parlor party's table code can be a passcode too.")
            }
            Section("Open a room") {
                TextField("Room name", text: $newRoomName)
                TextField("Passcode — letters and numbers, easy to say", text: $newRoomCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Open the room") {
                    let name = newRoomName
                    let code = newRoomCode
                    newRoomName = ""
                    newRoomCode = ""
                    Task { await service.openHotelRoom(name: name, code: code) }
                }
                .disabled(service.phase == .joining)
            }
            Section("Join a game table's room") {
                TextField("The Parlor party code", text: $tableCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Join that table's voices") {
                    let code = tableCode
                    tableCode = ""
                    Task { await service.joinTable(code: code) }
                }
                .disabled(service.phase == .joining)
            }
        }
        .confirmationDialog(
            "Close this room for good?",
            isPresented: $showCloseConfirm,
            titleVisibility: .visible,
            presenting: roomPendingClose
        ) { room in
            Button("Close \(room.name)", role: .destructive) {
                Task { await service.closeHotelRoom(key: room.key) }
            }
            Button("Keep it", role: .cancel) {}
        }
    }

    // ── the room ──
    private var roomScreen: some View {
        List {
            if !service.roomSay.isEmpty {
                Section {
                    Text(service.roomSay)
                        .font(.callout)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            Section("Who's here — \(service.roomLabel)") {
                ForEach(service.roster) { row in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(row.talking ? Color.green : Color.clear)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(rosterLine(row))
                            .fontWeight(row.talking ? .bold : .regular)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let botName = service.botName {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(botName) — companion guest, invited by \(service.botAnchorName)\(service.botBusy ? " — thinking" : "")")
                        HStack {
                            Button("Your turn, \(botName)") { service.cueBot() }
                                .buttonStyle(.borderedProminent)
                                .disabled(service.botBusy)
                            Button("Ask them to leave") { service.kickBot() }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            Section {
                Button(service.micMuted ? "Unmute my mic" : "Mute my mic") { service.toggleMic() }
                Button("Say who's here") { service.sayWhosHere() }
                Button("Leave the room", role: .destructive) {
                    if service.recording { showLeaveWhileTaping = true } else { service.leave() }
                }
            }
            Section {
                Button {
                    if service.recording { service.stopRecording() } else { service.startRecording() }
                } label: {
                    HStack(spacing: 8) {
                        if service.recording {
                            Circle().fill(.red).frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                        }
                        Text(service.recording ? "Stop the recording — \(clock(service.recElapsed))" : "Record this conversation")
                    }
                }
                .tint(service.recording ? Color.red : nil)
                if let url = service.recFileURL {
                    ShareLink("Share the recording", item: url)
                    Text(service.recFileLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !service.tapersLine.isEmpty {
                    Text(service.tapersLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("The tape deck")
            } footer: {
                Text("Tapes the whole room — every voice, the jukebox, the bot — into one audio file you can share or save, like a Parlor transcript. The room is always told when a tape starts and stops.")
            }
            Section {
                HStack(spacing: 10) {
                    Text(service.nowPlayingLine)
                        .accessibilityAddTraits(.updatesFrequently)
                    if service.isPlaying {
                        Spacer()
                        EqBars(animated: !reduceMotion)
                            .accessibilityHidden(true)
                    }
                }
                Button(service.isPlaying ? "Pause the music" : "Play") { service.togglePlay() }
                Button("Back a song") { service.back() }
                    .accessibilityHint("Goes back to the song before this one — radio fights are allowed.")
                Button("Skip ahead") { service.skip() }
                if service.hasSong {
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(
                            value: $seekPos,
                            in: 0...max(1, service.songDur)
                        ) {
                            Text("Song position")
                        } onEditingChanged: { editing in
                            seekEditing = editing
                            if !editing { service.seek(to: seekPos) }
                        }
                        .accessibilityValue("\(timeString(seekPos)) of \(timeString(service.songDur))")
                        Text("\(timeString(seekPos)) of \(timeString(service.songDur))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    HStack {
                        Button("Back 15 seconds") { service.seekRelative(-15) }
                            .buttonStyle(.bordered)
                        Button("Ahead 15 seconds") { service.seekRelative(15) }
                            .buttonStyle(.bordered)
                    }
                }
                Button("Add a song") { showFilePicker = true }
                    .accessibilityHint("Pick an audio file, then choose to cut in or queue it politely.")
                TextField("Or paste a link — YouTube, Spotify, SoundCloud, a direct MP3…", text: $songLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Fetch from the link") { showLinkChoice = true }
                    .disabled(songLink.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityHint("Pulls the song from the link, then choose to cut in or queue it. Spotify songs arrive by name-match; if YouTube's gate is closed, I keep knocking and holler when it opens.")
                if !service.knockLine.isEmpty {
                    Text(service.knockLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.updatesFrequently)
                    Button("Stop knocking") { service.stopKnocking() }
                }
                Button("Clear the queue", role: .destructive) { showClearConfirm = true }
            } header: {
                Text("The jukebox")
            } footer: {
                Text("One player for the whole room — anybody can drive it. Your volume below is yours alone; voices always come through full.")
            }
            .onChange(of: service.songPos) { _, newPos in
                if !seekEditing { seekPos = newPos }
            }
            if !service.queueRows.isEmpty {
                Section("Up next") {
                    ForEach(service.queueRows) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                Text(row.byName + (row.marker.isEmpty ? "" : " — \(row.marker)"))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button("Play this now") { service.jump(to: row.id) }
                                Button("Take it off", role: .destructive) { service.removeSong(row.id) }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .accessibilityLabel("Actions for \(row.title)")
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(row.title), from \(row.byName)\(row.marker.isEmpty ? "" : ", \(row.marker)")")
                        .accessibilityHint("The actions button can play it now or take it off the list.")
                    }
                }
            }
            Section("My music volume") {
                Slider(
                    value: Binding(
                        get: { service.musicVolume },
                        set: { service.setMusicVolume($0) }
                    ),
                    in: 0...1,
                    step: 0.05
                ) {
                    Text("My music volume")
                }
                .accessibilityValue("\(Int(service.musicVolume * 100)) percent")
                Text("Starts low so talk rides over the music. Changing it changes only your ears.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Host voices read the announcements", isOn: Binding(
                    get: { service.paOn },
                    set: { service.setPAOn($0) }
                ))
                Slider(
                    value: Binding(
                        get: { service.paVolume },
                        set: { service.setPAVolume($0) }
                    ),
                    in: 0...1,
                    step: 0.05
                ) {
                    Text("Announcement volume")
                }
                .accessibilityValue("\(Int(service.paVolume * 100)) percent")
                .disabled(!service.paOn)
            } header: {
                Text("The house PA")
            } footer: {
                Text("Two host voices read the room out loud for everybody — Miss A works the front desk (comings, goings, taping notices) and Kade's calm narrator runs the booth (jukebox news). Real audio, no screen reader needed; volume is yours alone.")
            }
            Section {
                Toggle("Headphones clarity mode", isOn: Binding(
                    get: { service.clearMic },
                    set: { service.setClearMic($0) }
                ))
            } header: {
                Text("My mic")
            } footer: {
                Text("Sends your mic raw — no echo cancel, no noise trims, full fidelity, and incoming music stops dipping while you talk. It also unlocks STEREO music on this phone: Apple's echo-cancel engine is mono-only (the same wall TeamTalk hits), so with this off, the jukebox arrives folded to one channel. Headphones only: on a speaker, the room will hear themselves echo off you.")
            }
            Section {
                if service.botName == nil {
                    // Her catch: a 200-name Picker renders as one giant menu —
                    // unscrollable misery, worse with VoiceOver. A sheet with a
                    // real List + search scrolls and rotors like anything else.
                    Button {
                        showCompanionPicker = true
                    } label: {
                        HStack {
                            Text("Who to invite")
                            Spacer()
                            Text(service.agents.first(where: { $0.id == pickedAgentId })?.name ?? "Pick a companion")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel(
                        pickedAgentId.isEmpty
                            ? "Who to invite. Nobody picked yet."
                            : "Who to invite. Currently \(service.agents.first(where: { $0.id == pickedAgentId })?.name ?? "someone")."
                    )
                    .accessibilityHint("Opens a searchable list of companions.")
                    Button("Invite them in") {
                        if let agent = service.agents.first(where: { $0.id == pickedAgentId }) {
                            service.inviteBot(agent)
                        }
                    }
                    .disabled(pickedAgentId.isEmpty)
                }
                if !service.botLastLine.isEmpty {
                    Text(service.botLastLine)
                        .font(.callout)
                }
            } header: {
                Text("Company")
            } footer: {
                Text("Invite one companion as a guest. Press their talk button when it's their turn and they answer out loud in their own voice; between turns they follow along by rough transcription. Anyone can show them the door.")
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.audio]) { result in
            if case let .success(url) = result {
                pendingSongURL = url
                showAddChoice = true
            }
        }
        .confirmationDialog("Clear the whole queue, for everybody?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear it", role: .destructive) { service.clearQueue() }
            Button("Keep it", role: .cancel) {}
        }
        .confirmationDialog("How should it land?", isPresented: $showAddChoice, titleVisibility: .visible) {
            Button("Cut in and play it now") {
                if let url = pendingSongURL { service.addSong(url: url, interrupt: true) }
                pendingSongURL = nil
            }
            Button("Add it to the queue") {
                if let url = pendingSongURL { service.addSong(url: url, interrupt: false) }
                pendingSongURL = nil
            }
            Button("Never mind", role: .cancel) { pendingSongURL = nil }
        }
        .confirmationDialog("How should it land?", isPresented: $showLinkChoice, titleVisibility: .visible) {
            Button("Cut in and play it now") {
                service.addSong(fromLink: songLink, interrupt: true)
                songLink = ""
            }
            Button("Add it to the queue") {
                service.addSong(fromLink: songLink, interrupt: false)
                songLink = ""
            }
            Button("Never mind", role: .cancel) {}
        }
        .confirmationDialog("You're still taping this room.", isPresented: $showLeaveWhileTaping, titleVisibility: .visible) {
            Button("Stop the tape, keep it, then leave") { service.stopRecordingThenLeave() }
            Button("Leave and lose the tape", role: .destructive) { service.leave() }
            Button("Stay", role: .cancel) {}
        }
        .sheet(isPresented: $showCompanionPicker) {
            CompanionPickerSheet(agents: service.agents, selectedId: $pickedAgentId)
        }
    }

    private func timeString(_ t: Double) -> String {
        let secs = max(0, Int(t.rounded()))
        return "\(secs / 60):" + String(format: "%02d", secs % 60)
    }

    private func clock(_ t: TimeInterval) -> String {
        timeString(t)
    }

    private func rosterLine(_ row: ClubRosterRow) -> String {
        var line = row.name
        if row.isMe { line += " (you)" }
        if row.talking { line += " — talking" }
        return line
    }
}

/// The companion picker as a real, searchable, scrollable list — replacing
/// a 200-name Picker menu that could not be scrolled (her catch, July 24).
/// Plain List rows read and rotor cleanly under VoiceOver; the search field
/// shortens the walk.
private struct CompanionPickerSheet: View {
    let agents: [ClubAgent]
    @Binding var selectedId: String
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var hits: [ClubAgent] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return agents }
        return agents.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(hits) { a in
                        Button {
                            selectedId = a.id
                            dismiss()
                        } label: {
                            HStack {
                                Text(a.name)
                                    .foregroundStyle(.primary)
                                if a.id == selectedId {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .accessibilityLabel(a.id == selectedId ? "\(a.name), current pick" : a.name)
                        .accessibilityHint("Picks them and closes the list.")
                    }
                } footer: {
                    Text(search.isEmpty
                        ? "\(agents.count) companions — search above to shorten the list."
                        : "Showing \(hits.count) of \(agents.count).")
                }
            }
            .searchable(text: $search, prompt: "Search companions")
            .navigationTitle("Who to invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

/// Decorative EQ bars for the now-playing line — pure eye candy, hidden
/// from VoiceOver, honest sine-wave motion (not audio-reactive), and it
/// sits politely still when Reduce Motion is on.
private struct EqBars: View {
    let animated: Bool

    var body: some View {
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: 0.12)) { context in
                    bars(at: context.date.timeIntervalSinceReferenceDate)
                }
            } else {
                bars(at: 1.7)
            }
        }
        .frame(width: 34, height: 18)
    }

    private func bars(at t: Double) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(Color.green.opacity(0.85))
                    .frame(width: 4, height: 4 + 13 * abs(sin(t * (1.3 + Double(i) * 0.35) + Double(i))))
            }
        }
    }
}

/// Keeps the engine's invisible WKWebView inside the live view hierarchy —
/// WebKit throttles pages that are not attached to a window.
private struct EngineHostView: UIViewRepresentable {
    let engine: ClubhouseEngine
    let up: Bool

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isAccessibilityElement = false
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        if up, let web = engine.webView {
            if web.superview !== v {
                v.subviews.forEach { $0.removeFromSuperview() }
                web.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
                v.addSubview(web)
            }
        } else {
            v.subviews.forEach { $0.removeFromSuperview() }
        }
    }
}
