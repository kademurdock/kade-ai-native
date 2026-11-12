import Foundation

// Nov 12 2026 (platform audit, wave 2): the account voice-settings rules
// (decision 24, copied from the website's listenerVoiceSync tests) and the
// stream pick-up rules (phase 4 pick 4). Pure Foundation; no network, no audio.

var count = 0
func check(_ ok: Bool, _ label: String) {
    if !ok { print("FAILED: \(label)"); exit(1) }
    count += 1
}

typealias P = ListenerVoicePlan
func local(pace: Double? = nil, paceSaved: Bool = false, fillers: Bool = true, fillersSaved: Bool = false,
           delivery: [String: String] = [:]) -> P.Local {
    P.Local(pace: pace, paceSaved: paceSaved, fillers: fillers, fillersSaved: fillersSaved, delivery: delivery)
}

// applies a value another device saved
do {
    let plan = P.plan(account: P.Account(pace: .some(1.2), paceAt: "t1", fillers: false, fillersAt: "t2", delivery: [:]),
                      local: local(), state: P.State())
    check(plan.applyPace == .some(.some(1.2)) && plan.applyFillers == false, "applies another device's values")
    check(!plan.pushesAnything, "nothing is sent back")
    check(plan.state.seenPace == "t1" && plan.state.seenFillers == "t2", "stamps are remembered")
}
// a stamp already seen changes nothing
do {
    var state = P.State(); state.seenPace = "t1"
    let plan = P.plan(account: P.Account(pace: .some(1.2), paceAt: "t1"), local: local(pace: 0.9, paceSaved: true), state: state)
    check(plan.applyPace == nil && !plan.pushesAnything, "a seen stamp does nothing")
}
// a pending change made here wins and is sent again
do {
    var state = P.State(); state.seenPace = "t1"; state.pendingPace = true; state.pendingFillers = true
    let plan = P.plan(account: P.Account(pace: .some(1.2), paceAt: "t9", fillers: true, fillersAt: "t9"),
                      local: local(pace: 0.8, paceSaved: true, fillers: false, fillersSaved: true), state: state)
    check(plan.applyPace == nil && plan.applyFillers == nil, "pending is not overwritten")
    check(plan.pushPace == .some(.some(0.8)) && plan.pushFillers == false, "pending is sent again")
}
// seeds the account only from a choice this phone really saved
do {
    let empty = P.Account(delivery: [:])
    check(!P.plan(account: empty, local: local(), state: P.State()).pushesAnything, "a fresh install sends nothing")
    let plan = P.plan(account: empty, local: local(pace: 1.1, paceSaved: true, fillers: false, fillersSaved: true), state: P.State())
    check(plan.pushPace == .some(.some(1.1)) && plan.pushFillers == false, "her saved choices seed the account")
    let defaults = P.plan(account: empty, local: local(pace: nil, paceSaved: false, fillers: true, fillersSaved: false), state: P.State())
    check(defaults.pushPace == nil && defaults.pushFillers == nil, "a never-chosen default never seeds")
}
// null pace is the character's speed
do {
    let plan = P.plan(account: P.Account(pace: .some(nil), paceAt: "t1"), local: local(pace: 1.3), state: P.State())
    check(plan.applyPace == .some(nil), "null pace applies Character's speed")
}
// a pace out of range is ignored
do {
    let plan = P.plan(account: P.Account(pace: .some(4), paceAt: "t1"), local: local(), state: P.State())
    check(plan.applyPace == nil, "out-of-range pace ignored")
}
// delivery: applied on a new stamp, cleaned; seen stamp does nothing
do {
    let plan = P.plan(account: P.Account(delivery: ["agent_a": "STABLE", "agent_b": "LOUD", "x.y": "STABLE"], deliveryAt: "d1"),
                      local: local(), state: P.State())
    check(plan.applyDelivery == ["agent_a": "STABLE"] && plan.state.seenDelivery == "d1", "delivery applied, cleaned")
    var state = P.State(); state.seenDelivery = "d1"
    check(P.plan(account: P.Account(delivery: [:], deliveryAt: "d1"), local: local(), state: state).applyDelivery == nil,
          "a seen delivery stamp does nothing")
}
// delivery: the server never had it and the phone holds saved entries: all sent in one map
do {
    let plan = P.plan(account: P.Account(), local: local(delivery: ["agent_a": "BALANCED", "library-reading": "STABLE"]), state: P.State())
    check(plan.pushDelivery?.count == 2 && plan.pushDelivery?["agent_a"] == .some("BALANCED"), "saved delivery seeds the account")
}
// delivery: a pending agent is sent (a cleared one as null), not overwritten
do {
    var state = P.State(); state.pendingDelivery = ["agent_a", "agent_b"]
    let plan = P.plan(account: P.Account(delivery: ["agent_a": "CREATIVE"], deliveryAt: "d2"),
                      local: local(delivery: ["agent_a": "STABLE"]), state: state)
    check(plan.applyDelivery == nil, "pending delivery is not overwritten")
    check(plan.pushDelivery?["agent_a"] == .some("STABLE") && plan.pushDelivery?["agent_b"] == .some(nil), "pending delivery resent, clear as null")
}
// a missing reply changes nothing
do {
    let plan = P.plan(account: nil, local: local(), state: P.State())
    check(!plan.pushesAnything && plan.applyPace == nil && plan.state == P.State(), "no reply, no change")
}
// afterPush: stamps stored; pending cleared only when the phone still holds what was sent
do {
    var state = P.State(); state.pendingPace = true; state.pendingFillers = true
    let account = P.Account(pace: .some(1.2), paceAt: "t5", fillers: true, fillersAt: "t6")
    let next = P.afterPush(state: state, sentPace: .some(1.2), sentFillers: nil, sentDelivery: nil,
                           account: account, local: local(pace: 1.2))
    check(next.seenPace == "t5" && !next.pendingPace && next.pendingFillers, "taken field cleared, other stays pending")
    let moved = P.afterPush(state: state, sentPace: .some(1.2), sentFillers: nil, sentDelivery: nil,
                            account: account, local: local(pace: 1.4))
    check(moved.seenPace == "t5" && moved.pendingPace, "changed again meanwhile: still pending")
}
// account JSON is read leniently
do {
    let account = P.Account(json: ["pace": NSNull(), "paceAt": "a", "fillers": false, "delivery": ["x": "STABLE", "y": 3]])
    check(account.pace == .some(nil) && account.fillers == false && account.delivery == ["x": "STABLE"], "lenient account read")
    check(P.Account(json: [:]).pace == nil, "absent pace means never saved")
}
// pace words
do {
    check(P.paceWord(number: 1.2) == "brisk" && P.paceWord(number: nil) == "character", "pace word mapping")
    check(P.paceWord(number: 1.25) == nil, "a number with no exact option keeps local")
    check(P.paceNumber(word: "unhurried") == .some(.some(0.75)) && P.paceNumber(word: "nope") == nil, "pace numbers")
    check(P.validPace(nil) && P.validPace(1.5) && !P.validPace(0.4) && !P.validPace(.nan), "validPace")
}

// Phase 4 pick 4: StreamResume
do {
    check(StreamResume.cursor(fromIdLine: "id: 9f3a1c2e-128") == "9f3a1c2e-128", "cursor parsed")
    check(StreamResume.cursor(fromIdLine: "id: 128") == nil, "short cursor refused")
    check(StreamResume.cursor(fromIdLine: "id: 9f3a1c2e-12x") == nil, "bad seq refused")
    check(StreamResume.cursor(fromIdLine: "data: {}") == nil, "not an id line")
    check(StreamResume.tail(saved: "One. Two. Three.", delivered: "One. Two.") == " Three.", "tail by prefix")
    check(StreamResume.tail(saved: "One. Two.", delivered: "") == "One. Two.", "nothing delivered: all")
    let saved = "%%%warm%%% It rained all night in Ozark. The creek is up. Stay off the low road."
    let delivered = "It rained all night in Ozark. The creek is up."
    check(StreamResume.tail(saved: saved, delivered: delivered) == " Stay off the low road.", "tail by 48-character anchor")
    // The delivered text is not a prefix of the saved reply, and its last 48
    // characters appear TWICE in it: the place is ambiguous, so nil.
    let line = "The creek is over the low road again tonight, so take the ridge way home."
    let twice = "\(line) \(line) Call when you get in."
    check(!twice.hasPrefix("Earlier. \(line)") && twice.components(separatedBy: String(line.suffix(48))).count == 3,
          "the fixture really holds the anchor twice")
    check(StreamResume.tail(saved: twice, delivered: "Earlier. \(line)") == nil, "ambiguous anchor refused")
    // The same anchor found once places the rest.
    check(StreamResume.tail(saved: "\(line) Call when you get in.", delivered: "Earlier. \(line)") == " Call when you get in.",
          "a single anchor places the rest")
    check(StreamResume.tail(saved: "Nothing alike here.", delivered: "Earlier. \(line)") == nil, "an anchor not found refuses")
    check(StreamResume.delayNanos(attempt: 1) == 500_000_000 && StreamResume.delayNanos(attempt: 2) == 1_000_000_000
          && StreamResume.delayNanos(attempt: 3) == 2_000_000_000 && StreamResume.delayNanos(attempt: 9) == 4_000_000_000,
          "0.5, 1, 2, then 4 s")
}

print("Voice sync and stream resume: \(count) checks passed; no network, no audio.")
