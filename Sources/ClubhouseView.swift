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
                    Text(rosterLine(row))
                        .fontWeight(row.talking ? .bold : .regular)
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
                Button("Leave the room", role: .destructive) { service.leave() }
            }
            Section {
                Text(service.nowPlayingLine)
                    .accessibilityAddTraits(.updatesFrequently)
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
                Toggle("Headphones clarity mode", isOn: Binding(
                    get: { service.clearMic },
                    set: { service.setClearMic($0) }
                ))
            } header: {
                Text("My mic")
            } footer: {
                Text("Sends your mic raw — no echo cancel, no noise trims, full fidelity, and incoming music stops dipping while you talk. Headphones only: on a speaker, the room will hear themselves echo off you.")
            }
            Section {
                if service.botName == nil {
                    Picker("Who to invite", selection: $pickedAgentId) {
                        Text("Pick a companion…").tag("")
                        ForEach(service.agents) { a in
                            Text(a.name).tag(a.id)
                        }
                    }
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
    }

    private func timeString(_ t: Double) -> String {
        let secs = max(0, Int(t.rounded()))
        return "\(secs / 60):" + String(format: "%02d", secs % 60)
    }

    private func rosterLine(_ row: ClubRosterRow) -> String {
        var line = row.name
        if row.isMe { line += " (you)" }
        if row.talking { line += " — talking" }
        return line
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
