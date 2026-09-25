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
    @Environment(\.scenePhase) private var scenePhase

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
        // A song link copied in another app fills the jukebox box once per
        // copy. The 2 s wait lets the join announcements finish first.
        .onChange(of: service.phase) { _, phase in
            if phase == .inRoom { fillCopiedSongLink(after: 2) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, service.phase == .inRoom { fillCopiedSongLink(after: 0.5) }
        }
        .onDisappear { service.leave() }
    }

    // ── the picker ──
    private var pickerScreen: some View {
        List {
            // Part 292: the listening lounge. Silent here; Help's "What the
            // app looks like" carries its words.
            Section {
                KadePaintedHeader(imageName: "ArtClubhouseLounge", symbol: "hifispeaker.2.fill", tint: .pink, height: 110)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                Text(service.statusLine)
                    .font(.callout)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Section {
                if service.publicRooms.isEmpty {
                    // Two chairs by the fire while no room is showing (silent).
                    KadeArtSpot(imageName: "ArtEmptyFireside", fallbackSymbol: "flame", width: 120, height: 120)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
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
                Text("Live family voice rooms with a shared jukebox. Person to person on Kade's own room server — a character only ever hears a room you invited them into.")
            }
            Section {
                KadePaintedHeader(imageName: "ArtClubhouseHotel", symbol: "key.fill", tint: .brown, height: 90)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
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
            // Part 292: music night on the lawn (silent).
            Section {
                KadePaintedHeader(imageName: "ArtClubhouseMusicNight", symbol: "music.note.house", tint: .pink, height: 90)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
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
                        Text("\(botName) — character guest, invited by \(service.botAnchorName)\(service.botBusy ? " — thinking" : "")")
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
                TextField("Or paste a song link: YouTube, Spotify, SoundCloud, or an audio file", text: $songLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .accessibilityLabel("Song link")
                    .accessibilityHint("A YouTube or Spotify song, SoundCloud, Bandcamp, or a link to an audio file. A song link you copied fills in by itself.")
                Button("Fetch from the link") { showLinkChoice = true }
                    .disabled(songLink.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityHint("The server pulls the song, up to 15 minutes long, then you choose to cut in or queue it.")
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
                Toggle("Headphones clarity and stereo", isOn: Binding(
                    get: { service.clearMic },
                    set: { service.setClearMic($0) }
                ))
                Text(service.musicOutputStatus)
                    .font(.footnote)
            } header: {
                Text("My mic")
            } footer: {
                Text("With headphones connected, uses the phone microphone and a separate stereo music path. Bluetooth headset microphones are not used in this mode. Stereo depends on the song and output device. Disconnect headphones to restore speaker echo protection automatically.")
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
                            Text(service.agents.first(where: { $0.id == pickedAgentId })?.name ?? "Pick a character")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel(
                        pickedAgentId.isEmpty
                            ? "Who to invite. Nobody picked yet."
                            : "Who to invite. Currently \(service.agents.first(where: { $0.id == pickedAgentId })?.name ?? "someone")."
                    )
                    .accessibilityHint("Opens a searchable list of characters.")
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
                Text("Invite one character as a guest. Press their talk button when it's their turn and they answer out loud in their own voice; between turns they follow along by rough transcription. Anyone can show them the door.")
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

    /// A song link copied in another app, once per copy. Says so; fetches nothing by itself.
    private func fillCopiedSongLink(after seconds: Double) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard songLink.isEmpty, service.phase == .inRoom,
                  let link = await CopiedLink.take("clubhouse-song-link", where: CopiedLink.isSongLink),
                  songLink.isEmpty else { return }
            songLink = link
            service.say("Filled in the song link you copied. Choose Fetch from the link to play it or queue it.")
        }
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
                        ? "\(agents.count) characters — search above to shorten the list."
                        : "Showing \(hits.count) of \(agents.count).")
                }
            }
            .searchable(text: $search, prompt: "Search characters")
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
