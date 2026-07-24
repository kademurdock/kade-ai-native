import Foundation
import SwiftUI
import UIKit
import LiveKit

/// KADE'S CLUBHOUSE, pure native (July 24 2026 — her call: "can you build
/// all that native instead of just web shell?").
///
/// This service is the room's brain on the phone: the LiveKit Swift
/// connection (mic, roster, personal volume, data channel), the SHARED
/// JUKEBOX state machine, the Hotel's hidden-room API, and the bot guest's
/// anchor logic. The one thing iOS cannot do natively — publish extra audio
/// tracks — lives in ClubhouseEngine (see its header for the why).
///
/// PROTOCOL CONTRACT: the data-channel messages here mirror the web page's
/// (topic 'club', same JSON shapes, same authority rules) BYTE-COMPATIBLY —
/// web and native members share one room, one queue, one radio fight. Change
/// one side only ever in lockstep with the other.
struct ClubEntry: Equatable {
    let id: String
    let title: String
    let by: String
    let byName: String

    var dict: [String: Any] {
        ["id": id, "title": title, "by": by, "byName": byName]
    }

    static func from(_ d: [String: Any]) -> ClubEntry? {
        guard let id = d["id"] as? String,
              let title = d["title"] as? String,
              let by = d["by"] as? String else { return nil }
        return ClubEntry(id: id, title: title, by: by, byName: (d["byName"] as? String) ?? "Somebody")
    }
}

struct ClubBot: Equatable {
    let agentId: String
    let name: String
    let anchor: String
    let anchorName: String

    var dict: [String: Any] {
        ["agentId": agentId, "name": name, "anchor": anchor, "anchorName": anchorName]
    }

    static func from(_ d: [String: Any]) -> ClubBot? {
        guard let agentId = d["agentId"] as? String,
              let name = d["name"] as? String,
              let anchor = d["anchor"] as? String else { return nil }
        return ClubBot(agentId: agentId, name: name, anchor: anchor,
                       anchorName: (d["anchorName"] as? String) ?? "somebody")
    }
}

struct ClubPublicRoom: Identifiable, Equatable {
    let key: String
    let name: String
    let blurb: String
    var id: String { key }
}

struct ClubHotelRoom: Identifiable, Equatable {
    let key: String
    let name: String
    var id: String { key }
}

struct ClubAgent: Identifiable, Equatable {
    let id: String
    let name: String
}

struct ClubRosterRow: Identifiable, Equatable {
    let id: String
    let name: String
    let isMe: Bool
    let talking: Bool
}

struct ClubQueueRow: Identifiable, Equatable {
    let id: String
    let title: String
    let byName: String
    let marker: String
}

@MainActor
final class ClubhouseService: NSObject, ObservableObject {
    enum Phase { case picker, joining, inRoom }

    @Published var phase: Phase = .picker
    @Published var statusLine = "Opening the Clubhouse…"
    @Published var roomSay = ""
    @Published var serverReady = false
    @Published var publicRooms: [ClubPublicRoom] = []
    @Published var myHotelRooms: [ClubHotelRoom] = []
    @Published var roomLabel = ""
    @Published var roster: [ClubRosterRow] = []
    @Published var micMuted = false
    @Published var nowPlayingLine = "Nothing playing yet."
    @Published var isPlaying = false
    @Published var queueRows: [ClubQueueRow] = []
    @Published var musicVolume: Double
    @Published var agents: [ClubAgent] = []
    @Published var botName: String?
    @Published var botAnchorName = ""
    @Published var botBusy = false
    @Published var botLastLine = ""
    @Published var engineUp = false

    private let client: KadeAPIClient
    let engine = ClubhouseEngine()

    private var room: Room?
    private var myIdentity = ""
    private var myName = "Me"
    private var joinedRoomKey = ""
    private var joinedCode: String?
    private var speakingIds: Set<String> = []

    // ── the shared CLUB state (mirror of the web page, field for field) ──
    private struct ClubState {
        var v = 0
        var actn = 0
        var act = ""
        var queue: [ClubEntry] = []
        var curId: String?
        var playing = false
        var pos: Double = -1
    }

    private var club = ClubState()
    private var lastActn = 0
    private var myPos: [String: Double] = [:]
    private var songData: [String: Data] = [:]
    private var bot: ClubBot?
    private var trans = ""

    // engine bookkeeping
    private var engineReadyFlag = false
    private var engineWaiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
    private var enginePlayingId: String?
    private var engineLastPos: Double = 0
    private var engineLastPosAt = Date()
    private var pendingInviteAgent: ClubAgent?
    private var pendingResume: [String: Double] = [:]
    private var feedingSongs: Set<String> = []
    private var tick: Timer?

    init(client: KadeAPIClient) {
        let saved = UserDefaults.standard.object(forKey: "kadeClubMusicVol") as? Double
        musicVolume = saved.map { max(0, min(1, $0)) } ?? 0.25
        self.client = client
        super.init()
        engine.onEvent = { [weak self] event in
            self?.handleEngine(event)
        }
    }

    // ── helpers ──
    private func isDj(_ identity: String) -> Bool { identity.hasSuffix("-dj") }

    private func announce(_ text: String) {
        roomSay = text
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func realRemotes() -> [RemoteParticipant] {
        guard let room else { return [] }
        return room.remoteParticipants.values.filter { !isDj($0.identity?.stringValue ?? "") }
    }

    private func present(_ identity: String) -> Bool {
        if identity == myIdentity { return true }
        return realRemotes().contains { $0.identity?.stringValue == identity }
    }

    private func stewardId() -> String {
        var ids = realRemotes().compactMap { $0.identity?.stringValue }
        ids.append(myIdentity)
        return ids.sorted().first ?? myIdentity
    }

    private func curIndex() -> Int {
        guard let curId = club.curId else { return -1 }
        return club.queue.firstIndex { $0.id == curId } ?? -1
    }

    private func curEntry() -> ClubEntry? {
        let i = curIndex()
        return i >= 0 ? club.queue[i] : nil
    }

    private func entryById(_ id: String) -> ClubEntry? {
        club.queue.first { $0.id == id }
    }

    private func authorityId() -> String {
        if let cur = curEntry(), present(cur.by) { return cur.by }
        return stewardId()
    }

    private func iAmAuthority() -> Bool { room != nil && authorityId() == myIdentity }

    private func nextPlayable(from index: Int, dir: Int) -> ClubEntry? {
        var i = index + dir
        while i >= 0 && i < club.queue.count {
            if present(club.queue[i].by) { return club.queue[i] }
            i += dir
        }
        return nil
    }

    private func setCurrentId(_ id: String?) {
        club.curId = id
        club.pos = -1
    }

    private func setAct(_ text: String) {
        club.act = text
        club.actn += 1
    }

    private func sendData(_ obj: [String: Any]) {
        guard let room, let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        Task {
            try? await room.localParticipant.publish(data: data, options: DataPublishOptions(topic: "club", reliable: true))
        }
    }

    private func broadcastState() {
        sendData([
            "t": "state",
            "v": club.v,
            "actn": club.actn,
            "act": club.act,
            "jb": [
                "queue": club.queue.map { $0.dict },
                "curId": club.curId as Any? ?? NSNull(),
                "playing": club.playing,
                "pos": club.pos,
            ],
        ])
    }

    private func bumpBroadcast() {
        club.v += 1
        broadcastState()
        if club.actn > lastActn {
            lastActn = club.actn
            if !club.act.isEmpty { announce(club.act) }
        }
        reconcile()
    }

    private func adoptState(_ msg: [String: Any]) {
        guard let v = (msg["v"] as? NSNumber)?.intValue, v > club.v else { return }
        club.v = v
        club.act = (msg["act"] as? String) ?? ""
        club.actn = (msg["actn"] as? NSNumber)?.intValue ?? 0
        if let jb = msg["jb"] as? [String: Any] {
            club.queue = ((jb["queue"] as? [[String: Any]]) ?? []).compactMap { ClubEntry.from($0) }
            club.curId = jb["curId"] as? String
            club.playing = (jb["playing"] as? Bool) ?? false
            club.pos = (jb["pos"] as? NSNumber)?.doubleValue ?? -1
        }
        if club.actn > lastActn {
            lastActn = club.actn
            if !club.act.isEmpty { announce(club.act) }
        }
        reconcile()
    }

    private func normalizeCurrent() {
        guard let curId = club.curId else { return }
        guard let c = entryById(curId) else {
            club.curId = nil
            club.playing = false
            return
        }
        if club.playing && !present(c.by) {
            if let n = nextPlayable(from: curIndex(), dir: 1) {
                setCurrentId(n.id)
                setAct("\(c.byName) left and took their song along — next up: \(n.title).")
            } else {
                club.playing = false
                setAct("\(c.byName) left and took their song along. Music off.")
            }
        }
    }

    private func applyCmd(_ m: [String: Any]) {
        let cmd = (m["cmd"] as? String) ?? ""
        let who = (m["fromName"] as? String) ?? "Somebody"
        let i = curIndex()
        switch cmd {
        case "play":
            if club.curId == nil, let f = nextPlayable(from: -1, dir: 1) { setCurrentId(f.id) }
            if club.curId != nil {
                club.playing = true
                setAct("\(who) pressed play.")
            }
        case "pause":
            if club.playing {
                club.playing = false
                club.pos = -1
                setAct("\(who) paused the music.")
            }
        case "stop":
            if club.curId != nil {
                club.playing = false
                club.pos = 0
                setAct("\(who) stopped the music.")
            }
        case "skip":
            if let n = nextPlayable(from: i, dir: 1) {
                setCurrentId(n.id)
                club.playing = true
                setAct("\(who) skipped ahead to \(n.title).")
            } else if club.curId != nil {
                club.playing = false
                club.pos = 0
                setAct("\(who) skipped — that was the end of the queue.")
            }
        case "back":
            if let p = nextPlayable(from: i, dir: -1) {
                setCurrentId(p.id)
                club.playing = true
                setAct("\(who) went back to \(p.title).")
            } else if club.curId != nil {
                club.pos = 0
                club.playing = true
                setAct("\(who) started the song over.")
            }
        case "jump":
            if let id = m["id"] as? String, let e = entryById(id), present(e.by) {
                setCurrentId(e.id)
                club.playing = true
                setAct("\(who) jumped to \(e.title).")
            }
        case "remove":
            if let id = m["id"] as? String, let r = entryById(id) {
                let wasCur = club.curId == r.id
                let n = wasCur ? nextPlayable(from: curIndex(), dir: 1) : nil
                club.queue.removeAll { $0.id == r.id }
                if wasCur {
                    if let n { setCurrentId(n.id) } else {
                        club.curId = nil
                        club.playing = false
                    }
                }
                let auto = (m["auto"] as? Bool) ?? false
                setAct(auto ? "\(r.title) would not play and came off the list." : "\(who) took \(r.title) off the list.")
            }
        case "ended":
            if let n = nextPlayable(from: i, dir: 1) {
                setCurrentId(n.id)
                club.playing = true
                setAct("Next up: \(n.title).")
            } else {
                club.playing = false
                club.pos = 0
                setAct("That was the end of the queue.")
            }
        default:
            break
        }
        normalizeCurrent()
        bumpBroadcast()
    }

    private func applyAdd(entry: ClubEntry, interrupt: Bool, fromName: String) {
        if interrupt && club.curId != nil {
            let i = curIndex()
            club.queue.insert(entry, at: min(i + 1, club.queue.count))
            setCurrentId(entry.id)
            club.playing = true
            setAct("\(fromName) cut in with \(entry.title).")
        } else {
            club.queue.append(entry)
            if club.curId == nil {
                setCurrentId(entry.id)
                club.playing = true
                setAct("\(fromName) dropped a quarter in: \(entry.title).")
            } else {
                setAct("\(fromName) queued up \(entry.title).")
            }
        }
        normalizeCurrent()
        bumpBroadcast()
    }

    func clubCmd(_ cmd: String, id: String? = nil) {
        var msg: [String: Any] = ["t": "cmd", "cmd": cmd, "fromName": myName]
        if let id { msg["id"] = id }
        if iAmAuthority() { applyCmd(msg) } else { sendData(msg) }
    }

    // ── my playback engine (only for entries I added) ──
    private func enginePosEstimate() -> Double {
        guard enginePlayingId != nil else { return 0 }
        return engineLastPos + Date().timeIntervalSince(engineLastPosAt)
    }

    private func reconcile() {
        let cur = curEntry()
        let mine = cur != nil && club.playing && cur?.by == myIdentity
        if mine, let e = cur {
            if enginePlayingId != e.id {
                startEnginePlayback(e)
            } else if club.pos == 0 && enginePosEstimate() > 1.5 {
                club.pos = -1
                myPos[e.id] = 0
                startEnginePlayback(e)
            }
        } else if enginePlayingId != nil {
            silenceEngine()
        }
        rebuildUI()
    }

    private func startEnginePlayback(_ e: ClubEntry) {
        guard songData[e.id] != nil else {
            announce("That song's file went missing on this phone — taking it off the list.")
            autoRemove(e.id)
            return
        }
        enginePlayingId = e.id
        engineLastPos = club.pos == 0 ? 0 : (myPos[e.id] ?? 0)
        engineLastPosAt = Date()
        let resume = club.pos == 0 ? 0 : (myPos[e.id] ?? 0)
        pendingResume[e.id] = resume
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.ensureEngine()
            guard self.enginePlayingId == e.id else { return }
            guard ok else {
                self.enginePlayingId = nil
                self.announce("The music engine could not start — pausing the jukebox for now.")
                self.clubCmd("pause")
                return
            }
            self.engine.command("KE.loadPlay(\(ClubhouseEngine.jsString(e.id)), \(resume))")
        }
    }

    /// Feeds a song's bytes to the engine as base64 chunks over the JS
    /// bridge — awaited per chunk so nothing piles up in flight. (fetch()
    /// refuses custom URL schemes in WebKit; build 156 proved it live.)
    private func feedSong(_ id: String) async -> Bool {
        guard let data = songData[id] else { return false }
        if feedingSongs.contains(id) { return true }
        feedingSongs.insert(id)
        defer { feedingSongs.remove(id) }
        let b64 = data.base64EncodedString()
        let chunkSize = 3_000_000
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let end = b64.index(idx, offsetBy: chunkSize, limitedBy: b64.endIndex) ?? b64.endIndex
            let chunk = String(b64[idx..<end])
            let last = end == b64.endIndex
            let js = "KE.feedB64(\(ClubhouseEngine.jsString(id)), \"\(chunk)\", \(last))"
            let ok = await engine.commandAsync(js)
            if !ok { return false }
            idx = end
        }
        return true
    }

    private func autoRemove(_ id: String) {
        let msg: [String: Any] = ["t": "cmd", "cmd": "remove", "id": id, "auto": true, "fromName": myName]
        if iAmAuthority() { applyCmd(msg) } else { sendData(msg) }
    }

    private func silenceEngine() {
        if let id = enginePlayingId {
            myPos[id] = enginePosEstimate()
        }
        enginePlayingId = nil
        engine.command("KE.silence()")
    }

    private func ensureEngine() async -> Bool {
        if engineReadyFlag { return true }
        guard let room, room.connectionState == .connected else { return false }
        if !engine.isUp {
            guard let mint = try? await mintToken(roomKey: joinedRoomKey, code: joinedCode, lane: "dj"),
                  let api = Keychain.string(for: .accessToken) else {
                announce("The music engine could not get a room key.")
                return false
            }
            engine.connect(livekitToken: mint.token, livekitURL: mint.url, apiToken: api)
            engineUp = true
        }
        let waitId = UUID()
        return await withCheckedContinuation { cont in
            engineWaiters.append((waitId, cont))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                self?.timeoutEngineWaiter(waitId)
            }
        }
    }

    private func timeoutEngineWaiter(_ id: UUID) {
        if let idx = engineWaiters.firstIndex(where: { $0.0 == id }) {
            let (_, cont) = engineWaiters.remove(at: idx)
            cont.resume(returning: false)
        }
    }

    private func resolveEngineWaiters(_ ok: Bool) {
        let waiters = engineWaiters
        engineWaiters = []
        for (_, cont) in waiters { cont.resume(returning: ok) }
    }

    private func handleEngine(_ event: ClubhouseEngine.Event) {
        switch event {
        case .ready:
            engineReadyFlag = true
            resolveEngineWaiters(true)
        case .dead, .gone:
            engineReadyFlag = false
            enginePlayingId = nil
            engine.teardown()
            engineUp = false
            resolveEngineWaiters(false)
        case let .playing(id, pos):
            if enginePlayingId == id {
                engineLastPos = pos
                engineLastPosAt = Date()
            }
        case let .pos(id, pos, silenced):
            myPos[id] = pos
            if enginePlayingId == id {
                if silenced {
                    enginePlayingId = nil
                } else {
                    engineLastPos = pos
                    engineLastPosAt = Date()
                }
            }
        case let .ended(id):
            myPos[id] = 0
            if enginePlayingId == id {
                enginePlayingId = nil
                if iAmAuthority() { applyCmd(["cmd": "ended", "fromName": ""]) }
            }
        case let .needSong(id):
            Task { [weak self] in
                guard let self else { return }
                let ok = await self.feedSong(id)
                guard self.enginePlayingId == id else { return }
                if ok {
                    let resume = self.pendingResume[id] ?? 0
                    self.engine.command("KE.loadPlay(\(ClubhouseEngine.jsString(id)), \(resume))")
                } else {
                    self.enginePlayingId = nil
                    self.announce("That song would not reach the engine — taking it off the list.")
                    self.autoRemove(id)
                }
            }
        case let .feedFail(id):
            enginePlayingId = nil
            announce("That song's data would not load — taking it off the list.")
            autoRemove(id)
        case let .playFail(id, why):
            enginePlayingId = nil
            if why == "publish" {
                announce("The room would not take the track — try playing it again.")
            } else {
                announce("That file would not play — try an MP3, M4A, or WAV.")
                autoRemove(id)
            }
        case .botReady:
            if let agent = pendingInviteAgent {
                pendingInviteAgent = nil
                bot = ClubBot(agentId: agent.id, name: agent.name, anchor: myIdentity, anchorName: myName)
                trans = ""
                botBusy = false
                sendBotState()
                engine.command("KE.earsOn()")
                announce("\(agent.name) pulled up a chair. Press their talk button when you want them to speak — they listen along in between.")
                rebuildUI()
            }
        case .botDone:
            finishBotTurn()
        case .botFail:
            if pendingInviteAgent != nil {
                pendingInviteAgent = nil
                announce("Could not set up the guest chair — try again.")
            } else {
                finishBotTurn()
            }
        case let .ears(text):
            trans += "\n" + text
            if trans.count > 3800 { trans = String(trans.suffix(3800)) }
        }
    }

    // ── the room ──
    private struct Mint {
        let token: String
        let url: String
        let room: String
        let identity: String
        let name: String
    }

    private func mintToken(roomKey: String, code: String?, lane: String?) async throws -> Mint {
        var req = client.request(path: "api/kade/lounge/token", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["room": roomKey]
        if let code { body["code"] = code }
        if let lane { body["lane"] = lane }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await client.send(req)
        guard http.statusCode == 200,
              let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = j["token"] as? String,
              let url = j["url"] as? String else {
            throw ClubError.server(Self.explain(data, fallback: "Could not get a room key."))
        }
        return Mint(token: token,
                    url: url,
                    room: (j["room"] as? String) ?? roomKey,
                    identity: (j["identity"] as? String) ?? "Me",
                    name: (j["name"] as? String) ?? "Me")
    }

    enum ClubError: LocalizedError {
        case server(String)
        var errorDescription: String? {
            if case let .server(s) = self { return s }
            return nil
        }
    }

    private static func explain(_ data: Data, fallback: String) -> String {
        if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let e = j["error"] as? String, !e.isEmpty { return e }
        return fallback
    }

    func loadConfig() async {
        statusLine = "Opening the Clubhouse…"
        let req = client.request(path: "api/kade/lounge/config", authorized: true)
        guard let (data, http) = try? await client.send(req), http.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            statusLine = "Could not reach the Clubhouse — try again."
            return
        }
        serverReady = (j["ready"] as? Bool) ?? false
        publicRooms = ((j["rooms"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let key = r["key"] as? String, let name = r["name"] as? String else { return nil }
            return ClubPublicRoom(key: key, name: name, blurb: (r["blurb"] as? String) ?? "")
        }
        myHotelRooms = ((j["hotel"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let key = r["key"] as? String, let name = r["name"] as? String else { return nil }
            return ClubHotelRoom(key: key, name: name)
        }
        statusLine = serverReady
            ? "Pick a room."
            : "The Clubhouse is built and ready — it's just waiting on the room-server keys."
    }

    func checkIn(code raw: String) async {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !code.isEmpty else { return }
        statusLine = "Asking the front desk…"
        var req = client.request(path: "api/kade/lounge/hotel/checkin", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code])
        guard let (data, http) = try? await client.send(req) else {
            statusLine = "The front desk did not answer — try again."
            return
        }
        guard http.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = j["key"] as? String, let name = j["name"] as? String else {
            statusLine = Self.explain(data, fallback: "No room answered to that code.")
            return
        }
        await join(roomKey: key, label: name, code: code)
    }

    func openHotelRoom(name rawName: String, code rawCode: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, !code.isEmpty else { return }
        var req = client.request(path: "api/kade/lounge/hotel", method: "POST", authorized: true)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "code": code])
        guard let (data, http) = try? await client.send(req) else {
            statusLine = "Could not open the room — try again."
            return
        }
        guard http.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = j["key"] as? String, let roomName = j["name"] as? String else {
            statusLine = Self.explain(data, fallback: "Could not open the room.")
            return
        }
        statusLine = "The Hotel opened \(roomName). Share the passcode with your people — walking you in now."
        await join(roomKey: key, label: roomName, code: code)
    }

    func closeHotelRoom(key: String) async {
        let req = client.request(path: "api/kade/lounge/hotel/\(key)", method: "DELETE", authorized: true)
        guard let (data, http) = try? await client.send(req), http.statusCode == 200 else {
            statusLine = "Could not close that room."
            return
        }
        _ = data
        statusLine = "Room closed."
        await loadConfig()
    }

    func joinTable(code raw: String) async {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        await join(roomKey: code.lowercased(), label: "Table \(code.uppercased())", code: nil)
    }

    func join(roomKey: String, label: String, code: String?) async {
        guard phase != .joining else { return }
        phase = .joining
        statusLine = "Getting your room key…"
        let mint: Mint
        do {
            mint = try await mintToken(roomKey: roomKey, code: code, lane: nil)
        } catch {
            statusLine = (error as? LocalizedError)?.errorDescription ?? "Could not get a room key."
            phase = .picker
            return
        }
        myIdentity = mint.identity
        myName = mint.name
        joinedRoomKey = mint.room
        joinedCode = code
        roomLabel = label

        let newRoom = Room()
        newRoom.add(delegate: self)
        room = newRoom
        AudioManager.shared.isSpeakerOutputPreferred = true

        var attempt = 0
        while true {
            attempt += 1
            statusLine = attempt == 1
                ? "Connecting…"
                : "Waking the room up — still warming, try \(attempt) of 8…"
            do {
                try await newRoom.connect(url: mint.url, token: mint.token)
                break
            } catch {
                if attempt >= 8 {
                    statusLine = "The room server never answered — it may need a look. Try once more in a minute."
                    phase = .picker
                    room = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 3_500_000_000)
            }
        }

        micMuted = false
        do {
            try await newRoom.localParticipant.setMicrophone(enabled: true)
        } catch {
            announce("Mic permission was refused — you can listen, but the room cannot hear you.")
        }

        club = ClubState()
        lastActn = 0
        bot = nil
        botBusy = false
        trans = ""
        phase = .inRoom
        rebuildRoster()
        rebuildUI()
        let others = roster.count - 1
        announce("You are in \(label) with \(others) other\(others == 1 ? "" : "s"). Your mic is live.")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            self?.sendData(["t": "hello"])
        }
        await loadAgents()
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.periodicTick() }
        }
    }

    private func periodicTick() {
        guard room != nil else { return }
        if let e = curEntry(), club.playing, e.by == myIdentity, enginePlayingId == e.id {
            club.pos = enginePosEstimate().rounded()
            club.v += 1
            broadcastState()
        }
        if bot?.anchor == myIdentity { sendBotState() }
    }

    func toggleMic() {
        guard let room else { return }
        micMuted.toggle()
        let enabled = !micMuted
        Task {
            try? await room.localParticipant.setMicrophone(enabled: enabled)
        }
        announce(micMuted ? "Mic muted." : "Mic live.")
    }

    func sayWhosHere() {
        var names = roster.map { $0.name + ($0.isMe ? " (you)" : "") }
        if let bot { names.append("\(bot.name) (guest)") }
        announce(names.isEmpty ? "Nobody here yet." : "Here now: \(names.joined(separator: ", ")).")
    }

    func leave() {
        engine.command("KE.silence(); KE.earsOff(); KE.botOff();")
        engine.teardown()
        engineUp = false
        engineReadyFlag = false
        enginePlayingId = nil
        resolveEngineWaiters(false)
        tick?.invalidate()
        tick = nil
        if let room {
            Task { await room.disconnect() }
        }
        room = nil
        bot = nil
        botBusy = false
        trans = ""
        club = ClubState()
        lastActn = 0
        speakingIds = []
        phase = .picker
        statusLine = "Pick a room."
        roomSay = ""
        rebuildUI()
    }

    // ── jukebox actions from the UI ──
    func addSong(url: URL, interrupt: Bool) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            announce("That file would not open.")
            return
        }
        guard data.count <= 60_000_000 else {
            announce("That file is too big — keep songs under about sixty megabytes.")
            return
        }
        var title = url.deletingPathExtension().lastPathComponent
        if title.count > 60 { title = String(title.prefix(60)) }
        if title.isEmpty { title = "a song" }
        let id = "e" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(7).lowercased()
        songData[id] = data
        let entry = ClubEntry(id: id, title: title, by: myIdentity, byName: myName)
        if iAmAuthority() {
            applyAdd(entry: entry, interrupt: interrupt, fromName: myName)
        } else {
            sendData(["t": "add", "entry": entry.dict, "interrupt": interrupt, "fromName": myName])
        }
    }

    func togglePlay() { clubCmd(club.playing ? "pause" : "play") }
    func skip() { clubCmd("skip") }
    func back() { clubCmd("back") }
    func stopMusic() { clubCmd("stop") }
    func jump(to id: String) { clubCmd("jump", id: id) }
    func removeSong(_ id: String) { clubCmd("remove", id: id) }

    func setMusicVolume(_ v: Double) {
        musicVolume = max(0, min(1, v))
        UserDefaults.standard.set(musicVolume, forKey: "kadeClubMusicVol")
        applyVolumes()
    }

    private func applyVolumes() {
        guard let room else { return }
        for p in room.remoteParticipants.values {
            for pub in p.audioTracks {
                if pub.name == "music", let track = pub.track as? RemoteAudioTrack {
                    track.volume = musicVolume
                }
            }
        }
    }

    // ── bot guest ──
    private func loadAgents() async {
        let req = client.request(path: "api/kade/room/agents", authorized: true)
        guard let (data, http) = try? await client.send(req), http.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        agents = ((j["agents"] as? [[String: Any]]) ?? []).compactMap { a in
            guard let id = a["id"] as? String, let name = a["name"] as? String else { return nil }
            return ClubAgent(id: id, name: name)
        }
    }

    func inviteBot(_ agent: ClubAgent) {
        guard bot == nil else {
            announce("One guest at a time — ask \(bot?.name ?? "the guest") to leave first.")
            return
        }
        pendingInviteAgent = agent
        announce("Setting up a chair for \(agent.name)…")
        Task { [weak self] in
            guard let self else { return }
            let ok = await self.ensureEngine()
            guard ok else {
                self.pendingInviteAgent = nil
                self.announce("Could not set up the guest chair — try again.")
                return
            }
            self.engine.command("KE.botOn()")
        }
    }

    func cueBot() {
        guard let bot else { return }
        if bot.anchor == myIdentity {
            runBotTurn(from: myName)
        } else {
            sendData(["t": "bot-cue", "fromName": myName])
            announce("Told \(bot.name) it's their turn.")
        }
    }

    func kickBot() {
        guard let bot else { return }
        if bot.anchor == myIdentity {
            performKick(by: myName)
        } else {
            sendData(["t": "bot-kick", "fromName": myName])
        }
    }

    private func performKick(by name: String) {
        guard let gone = bot, gone.anchor == myIdentity else { return }
        engine.command("KE.earsOff(); KE.botOff();")
        bot = nil
        botBusy = false
        sendBotState()
        sendData(["t": "bot-said", "name": gone.name, "line": "(left the room)"])
        announce("\(gone.name) said goodnight and headed out. (\(name) showed them the door.)")
        rebuildUI()
    }

    private func runBotTurn(from name: String) {
        guard let bot, bot.anchor == myIdentity else { return }
        if botBusy {
            announce("\(bot.name) is already mid-thought.")
            return
        }
        botBusy = true
        sendData(["t": "bot-busy", "busy": true])
        rebuildUI()
        Task { [weak self] in
            guard let self else { return }
            var req = self.client.request(path: "api/kade/lounge/bot-turn", method: "POST", authorized: true)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "agentId": bot.agentId,
                "roomLabel": self.roomLabel,
                "transcript": self.trans,
                "cuedBy": name,
            ])
            guard let (data, http) = try? await self.client.send(req), http.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let line = j["line"] as? String else {
                self.announce("\(bot.name) lost their train of thought — cue them again.")
                self.finishBotTurn()
                return
            }
            let botName = (j["name"] as? String) ?? bot.name
            self.trans += "\n\(botName) (the guest): \(line)"
            if self.trans.count > 3800 { self.trans = String(self.trans.suffix(3800)) }
            self.sendData(["t": "bot-said", "name": botName, "line": line])
            self.botLastLine = "\(botName): \(line)"
            if let voice = j["voice"] as? String, !voice.isEmpty {
                self.engine.command("KE.botSay(\(ClubhouseEngine.jsString(line)), \(ClubhouseEngine.jsString(voice)))")
                // botDone / botFail events settle the busy flag
            } else {
                self.finishBotTurn()
            }
        }
    }

    private func finishBotTurn() {
        guard botBusy else { return }
        botBusy = false
        sendData(["t": "bot-busy", "busy": false])
        rebuildUI()
    }

    private func sendBotState() {
        if let bot, bot.anchor == myIdentity {
            sendData(["t": "bot", "bot": bot.dict])
        } else if bot == nil {
            sendData(["t": "bot", "bot": NSNull()])
        }
    }

    // ── incoming data ──
    private func handleData(_ data: Data, from identity: String?, topic: String) {
        guard topic.isEmpty || topic == "club" else { return }
        guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = msg["t"] as? String else { return }
        switch t {
        case "state":
            adoptState(msg)
        case "hello":
            if iAmAuthority() { broadcastState() }
            if bot?.anchor == myIdentity { sendBotState() }
        case "cmd":
            if iAmAuthority() { applyCmd(msg) }
        case "add":
            if iAmAuthority(), let d = msg["entry"] as? [String: Any], let entry = ClubEntry.from(d) {
                applyAdd(entry: entry, interrupt: (msg["interrupt"] as? Bool) ?? false,
                         fromName: (msg["fromName"] as? String) ?? "Somebody")
            }
        case "bot":
            if let d = msg["bot"] as? [String: Any], let b = ClubBot.from(d), b.anchor == identity {
                bot = b
                rebuildUI()
            } else if msg["bot"] is NSNull, let bot, bot.anchor == identity {
                self.bot = nil
                botBusy = false
                rebuildUI()
            }
        case "bot-cue":
            if bot?.anchor == myIdentity { runBotTurn(from: (msg["fromName"] as? String) ?? "Somebody") }
        case "bot-kick":
            if bot?.anchor == myIdentity { performKick(by: (msg["fromName"] as? String) ?? "Somebody") }
        case "bot-said":
            if let n = msg["name"] as? String, let l = msg["line"] as? String {
                botLastLine = "\(n): \(l)"
            }
        case "bot-busy":
            botBusy = (msg["busy"] as? Bool) ?? false
            rebuildUI()
        default:
            break
        }
    }

    // ── UI snapshots ──
    private func rebuildRoster() {
        guard let room else {
            roster = []
            return
        }
        var rows: [ClubRosterRow] = [
            ClubRosterRow(id: myIdentity,
                          name: room.localParticipant.name ?? myName,
                          isMe: true,
                          talking: speakingIds.contains(myIdentity)),
        ]
        for p in realRemotes().sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
            let id = p.identity?.stringValue ?? UUID().uuidString
            rows.append(ClubRosterRow(id: id,
                                      name: p.name ?? id,
                                      isMe: false,
                                      talking: speakingIds.contains(id)))
        }
        roster = rows
    }

    private func rebuildUI() {
        if let cur = curEntry() {
            nowPlayingLine = (club.playing ? "Now playing: " : "Paused: ") + cur.title + " — brought by " + cur.byName
        } else {
            nowPlayingLine = "Nothing playing yet."
        }
        isPlaying = club.playing
        queueRows = club.queue.map { e in
            let marker: String
            if e.id == club.curId {
                marker = club.playing ? "playing" : "paused"
            } else if !present(e.by) {
                marker = "owner stepped out"
            } else {
                marker = ""
            }
            return ClubQueueRow(id: e.id, title: e.title, byName: e.byName, marker: marker)
        }
        botName = bot?.name
        botAnchorName = bot?.anchorName ?? ""
    }
}

// ── LiveKit delegate (nonisolated hops back to the main actor) ──
extension ClubhouseService: RoomDelegate {
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? ""
        let name = participant.name ?? identity
        Task { @MainActor in
            guard !self.isDj(identity) else { return }
            self.rebuildRoster()
            self.announce("\(name) joined.")
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? ""
        let name = participant.name ?? identity
        Task { @MainActor in
            if self.isDj(identity) {
                self.rebuildRoster()
                self.reconcile()
                return
            }
            if let bot = self.bot, bot.anchor == identity {
                let botName = bot.name
                self.bot = nil
                self.botBusy = false
                self.announce("\(name) left and took \(botName) with them.")
            } else {
                self.announce("\(name) left.")
            }
            self.rebuildRoster()
            if self.iAmAuthority() {
                self.normalizeCurrent()
                self.bumpBroadcast()
            } else {
                self.reconcile()
            }
        }
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        let ids = Set(participants.compactMap { $0.identity?.stringValue })
        Task { @MainActor in
            self.speakingIds = ids
            self.rebuildRoster()
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        let name = publication.name
        let track = publication.track
        Task { @MainActor in
            if name == "music", let audio = track as? RemoteAudioTrack {
                audio.volume = self.musicVolume
            }
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        let identity = participant?.identity?.stringValue
        Task { @MainActor in
            self.handleData(data, from: identity, topic: topic)
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            guard self.phase == .inRoom else { return }
            self.announce("You left the room.")
            self.leave()
        }
    }
}
