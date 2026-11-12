import Foundation

/// Decision 24 (Nov 12 2026): her voice speed, filler switch and per-character
/// delivery follow her account through GET/PUT /api/kade/voice-prefs (the
/// `listener` field). The rules are in ListenerVoicePlan; this carries them
/// out. Speech never waits on any of it: every request reads the values on the
/// phone, and a value from the account lands in UserDefaults (and in every
/// VoiceService, through `applied`) the moment it arrives.
///
/// Switch on the phone: UserDefaults `kade.switch.voiceSync` = false (local
/// settings only, exactly as before). Server switch: KADE_LISTENER_PREFS=0
/// (the GET has no `listener`, and then this does nothing at all).
@MainActor
final class ListenerVoiceSync {
    static let shared = ListenerVoiceSync()

    /// Posted after account values were written to UserDefaults.
    static let applied = Notification.Name("kadeListenerVoicePrefsApplied")
    /// True while account values are being applied, so VoiceService's own
    /// change hooks do not mistake them for her change.
    private(set) static var applying = false

    static let paceKey = "kade.voiceMessage.pace"
    static let deliveryPrefix = "kade.voiceDelivery."
    /// Set the first time SHE picks a speed on this phone after this build.
    /// The pace key alone cannot say that: the app saves "character" there on
    /// first run, and a default must never seed the account.
    static let paceChosenKey = "kade.voiceSync.paceChosen"
    private static let stateKey = "kade.voiceSync.state"

    private var client: KadeAPIClient?
    private var lastFetch: Date = .distantPast
    private var fetching = false
    private var pushing = false
    private var pushAgain = false
    /// GET answered without `listener` (server switch off): nothing is sent.
    private var serverOff = false

    func attach(_ client: KadeAPIClient) { self.client = client }

    /// Another account may sign in next: forget this one's stamps and
    /// anything still waiting to be sent. The local settings stay.
    func signedOut() {
        UserDefaults.standard.removeObject(forKey: Self.stateKey)
        serverOff = false
        lastFetch = .distantPast
    }

    // MARK: State

    private var state: ListenerVoicePlan.State {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.stateKey),
                  let decoded = try? JSONDecoder().decode(ListenerVoicePlan.State.self, from: data) else {
                return ListenerVoicePlan.State()
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.stateKey)
            }
        }
    }

    private func localValues() -> ListenerVoicePlan.Local {
        let defaults = UserDefaults.standard
        let word = defaults.string(forKey: Self.paceKey) ?? "character"
        let parsed = ListenerVoicePlan.paceNumber(word: word)   // nil = a word the list does not have
        let known = parsed != nil
        let number: Double? = parsed.flatMap { $0 }           // nil = Character's speed
        let paceSaved = defaults.bool(forKey: Self.paceChosenKey) || (known && word != "character")
        let fillersKey = VoiceFillerPolicy.defaultsKey
        let fillersSaved = defaults.object(forKey: fillersKey) != nil
        let fillers = VoiceFillerPolicy.isOn(stored: fillersSaved ? defaults.bool(forKey: fillersKey) : nil)
        var delivery: [String: String] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(Self.deliveryPrefix) {
            if let mode = value as? String, ListenerVoicePlan.deliveryModes.contains(mode) {
                delivery[String(key.dropFirst(Self.deliveryPrefix.count))] = mode
            }
        }
        return ListenerVoicePlan.Local(pace: number, paceSaved: paceSaved, fillers: fillers,
                                       fillersSaved: fillersSaved, delivery: delivery)
    }

    // MARK: Her changes on this phone (already saved locally by the caller)

    func paceChanged() {
        guard KadeAppSwitches.voiceSync, !Self.applying else { return }
        UserDefaults.standard.set(true, forKey: Self.paceChosenKey)
        var s = state; s.pendingPace = true; state = s
        Task { await pushPending() }
    }

    func fillersChanged() {
        guard KadeAppSwitches.voiceSync, !Self.applying else { return }
        var s = state; s.pendingFillers = true; state = s
        Task { await pushPending() }
    }

    func deliveryChanged(agentId: String) {
        guard KadeAppSwitches.voiceSync, !Self.applying, ListenerVoicePlan.validAgentId(agentId) else { return }
        var s = state
        if !s.pendingDelivery.contains(agentId) { s.pendingDelivery.append(agentId) }
        state = s
        Task { await pushPending() }
    }

    // MARK: Fetch (launch, sign-in, back to the foreground after a minute)

    func foregrounded() {
        guard Date().timeIntervalSince(lastFetch) >= 60 else { return }
        Task { await sync() }
    }

    func sync() async {
        guard KadeAppSwitches.voiceSync, let client, !fetching else { return }
        fetching = true
        defer { fetching = false }
        lastFetch = Date()
        let req = client.request(path: "api/kade/voice-prefs", authorized: true, timeout: 20)
        guard let (data, http) = try? await client.send(req), http.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        guard let listener = json["listener"] as? [String: Any] else {
            serverOff = true   // the server keeps no listener prefs: local settings only
            return
        }
        serverOff = false
        let account = ListenerVoicePlan.Account(json: listener)
        let plan = ListenerVoicePlan.plan(account: account, local: localValues(), state: state)
        apply(plan)
        state = plan.state
        if plan.pushesAnything {
            await send(pace: plan.pushPace, fillers: plan.pushFillers, delivery: plan.pushDelivery)
        }
    }

    private func apply(_ plan: ListenerVoicePlan.Plan) {
        let defaults = UserDefaults.standard
        var changed = false
        if let pace = plan.applyPace, let word = ListenerVoicePlan.paceWord(number: pace) {
            // A number with no exact option keeps the local value (its stamp is still stored).
            if defaults.string(forKey: Self.paceKey) != word {
                defaults.set(word, forKey: Self.paceKey)
                changed = true
            }
        }
        if let fillers = plan.applyFillers {
            defaults.set(fillers, forKey: VoiceFillerPolicy.defaultsKey)
            changed = true
        }
        if let delivery = plan.applyDelivery {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.deliveryPrefix) {
                let agent = String(key.dropFirst(Self.deliveryPrefix.count))
                if delivery[agent] == nil { defaults.removeObject(forKey: key) }
            }
            for (agent, mode) in delivery { defaults.set(mode, forKey: Self.deliveryPrefix + agent) }
            changed = true
        }
        guard changed else { return }
        KadeBreadcrumbs.drop("voice sync: applied the account's values")
        Self.applying = true
        NotificationCenter.default.post(name: Self.applied, object: nil)
        Self.applying = false
    }

    // MARK: Writes

    private func pushPending() async {
        let s = state
        guard KadeAppSwitches.voiceSync, !serverOff,
              s.pendingPace || s.pendingFillers || !s.pendingDelivery.isEmpty else { return }
        let local = localValues()
        var delivery: [String: String?]? = nil
        if !s.pendingDelivery.isEmpty {
            var map: [String: String?] = [:]
            for agent in s.pendingDelivery { map[agent] = .some(local.delivery[agent]) }
            delivery = map
        }
        await send(pace: s.pendingPace ? .some(local.pace) : nil,
                   fillers: s.pendingFillers ? local.fillers : nil,
                   delivery: delivery)
    }

    private func send(pace: Double??, fillers: Bool?, delivery: [String: String?]?) async {
        guard let client else { return }
        if pushing { pushAgain = true; return }
        pushing = true
        defer {
            pushing = false
            if pushAgain {
                pushAgain = false
                Task { await pushPending() }
            }
        }
        var body: [String: Any] = [:]
        if let pace { body["pace"] = pace.map { $0 as Any } ?? NSNull() }
        if let fillers { body["fillers"] = fillers }
        if let delivery {
            var map: [String: Any] = [:]
            for (agent, mode) in delivery { map[agent] = mode.map { $0 as Any } ?? NSNull() }
            body["delivery"] = map
        }
        guard !body.isEmpty else { return }
        var req = client.request(path: "api/kade/voice-prefs", method: "PUT", authorized: true, timeout: 20)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard let (data, http) = try? await client.send(req) else { return }   // offline: still pending
        if http.statusCode == 404 { serverOff = true; return }
        guard http.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let listener = json["listener"] as? [String: Any] else { return }
        let account = ListenerVoicePlan.Account(json: listener)
        state = ListenerVoicePlan.afterPush(state: state, sentPace: pace, sentFillers: fillers,
                                            sentDelivery: delivery, account: account, local: localValues())
    }
}
