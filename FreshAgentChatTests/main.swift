import Foundation

@main struct FreshAgentChatTests {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ label: String) {
            count += 1
            precondition(value, label)
        }
        let angel = "agent_NkG_Fb8_xLz8HFJyx4gNv"
        let lilly = "agent_TOdYS8v-bRxeNw0dia_Md"
        let first = KadeFreshAgentChatRequest(agentID: angel)!
        let second = KadeFreshAgentChatRequest(agentID: angel)!
        check(first.agentID == angel && second.agentID == angel && first.id != second.id,
              "Repeated Angel taps retain the exact target and get independent fresh view identities")
        for invalid in ["", "Angel", "agent_", "agent_" + String(repeating: "a", count: 20),
                        "agent_" + String(repeating: "a", count: 22), " " + angel, angel + " ",
                        angel.replacingOccurrences(of: "N", with: "é"), angel + "/history"] {
            check(KadeFreshAgentChatRequest(agentID: invalid) == nil,
                  "Only a complete generated ASCII agent ID can enter the fresh-chat route")
        }
        check(KadeFreshAgentChatRequest(agentID: lilly)?.agentID == lilly,
              "The general route preserves another valid generated target rather than substituting Angel")
        check(KadeFreshAgentChatParser.push(routeName: "agent-chat", agentValue: angel)?.agentID == angel,
              "The exact push carrier selects Angel")
        let invalidPushValues: [Any?] = [nil, "", "Angel", 123, [angel], [angel, angel]]
        for invalid in invalidPushValues {
            check(KadeFreshAgentChatParser.push(routeName: "agent-chat", agentValue: invalid) == nil,
                  "Missing, malformed or repeated push agent data cannot select an agent")
        }
        for other in ["announcements", "talk", "agent-chat ", "AGENT-CHAT", ""] {
            check(KadeFreshAgentChatParser.push(routeName: other, agentValue: angel) == nil,
                  "A fresh-agent payload belongs only to its explicit route")
        }
        func link(_ value: String) -> KadeTalkLinkTarget {
            KadeFreshAgentChatParser.talkLink(URL(string: value)!)
        }
        switch link("kadeai://talk?agent=" + angel) {
        case .agent(let request): check(request.agentID == angel, "The existing exact-agent URL selects Angel")
        default: preconditionFailure("Exact-agent Talk link was lost")
        }
        check(link("kadeai://talk") == .main, "Plain Talk retains its existing main-character behavior")
        check(link("kadeai://talk?other=value") == .main, "A link without an explicit agent retains plain Talk behavior")
        for invalid in ["kadeai://talk?agent", "kadeai://talk?agent=", "kadeai://talk?agent=Angel",
                        "kadeai://talk?agent=" + angel + "&agent=" + angel,
                        "kadeai://talk?agent=" + angel + "&agent=" + lilly,
                        "https://talk?agent=" + angel, "kadeai://library?agent=" + angel,
                        "kadeai://talk/history?agent=" + angel, "kadeai://talk?agent=%20" + angel] {
            check(link(invalid) == .invalid, "An invalid or duplicate explicit agent link never falls back to the main character")
        }
        var inbox = KadeFreshAgentChatInbox()
        inbox.park(first)
        check(inbox.consume(authReady: false) == nil && inbox.pending == first,
              "A cold-launch request waits through signed-out/session restoration")
        check(inbox.consume(authReady: false) == nil && inbox.pending == first,
              "Repeated unavailable-auth attempts do not drop the target")
        check(inbox.consume(authReady: true) == first && inbox.pending == nil,
              "A ready sign-in consumes exactly the parked target")
        check(inbox.consume(authReady: true) == nil, "A consumed tap cannot replay itself")
        inbox.park(first)
        inbox.park(second)
        check(inbox.consume(authReady: true) == second, "The newest explicit tap wins while authentication is pending")
        inbox.park(first)
        inbox.cancel()
        check(inbox.pending == nil && inbox.consume(authReady: true) == nil,
              "A later unrelated route cancels a stale fresh-agent request")
        print("Fresh agent chat routing: \(count) checks passed")
    }
}
