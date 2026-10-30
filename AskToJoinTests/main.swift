import Foundation

// Oct 29 2026: the in-app front door's request body and its answers.
// Compiled by run-ask-to-join-tests.sh with Sources/AskToJoinRequest.swift only.
var failures = 0
func check(_ name: String, _ ok: Bool) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

func decoded(_ r: AskToJoinRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: r.jsonBody()) as? [String: Any]) ?? [:]
}

var r = AskToJoinRequest()
check("an empty form asks for a name first", r.missing == "Please say what people call you.")
r.name = "  David  "
check("then a way to reach them", r.missing?.contains("phone number or an email") == true)
r.contact = "417 770 0000"
check("then a little about them", r.missing == "Please tell Kade a little about yourself.")
r.whoYouAre = "Kade's friend from church."
check("the sight question is never required", r.missing == nil)

// Unanswered and "rather not say" both send JSON null; the key is always there.
var body = decoded(r)
check("names match the website form", body["name"] as? String == "David"
      && body["contact"] as? String == "417 770 0000"
      && body["whoYouAre"] as? String == "Kade's friend from church."
      && body["whyHere"] as? String == "")
check("no answer sends sight as null", body.keys.contains("sight") && body["sight"] is NSNull)
r.sight = .ratherNotSay
body = decoded(r)
check("rather not say sends null", body["sight"] is NSNull)
r.sight = .sighted
check("look at the screen sends sighted", decoded(r)["sight"] as? String == "sighted")
r.sight = .nonvisual
check("screen reader sends nonvisual", decoded(r)["sight"] as? String == "nonvisual")

check("the choices read in order", AskToJoinSight.allCases.map(\.label) == [
    "I'll look at the screen", "I'll listen, I use a screen reader", "I'd rather not say",
])
check("server values match the account flag", AskToJoinSight.allCases.map { $0.serverValue ?? "null" }
      == ["sighted", "nonvisual", "null"])

// The server's own caps.
r.name = String(repeating: "a", count: 200)
check("name trimmed to 80 like the server", (decoded(r)["name"] as? String)?.count == 80)
r.whoYouAre = String(repeating: "b", count: 5000)
check("about-you trimmed to 1200", (decoded(r)["whoYouAre"] as? String)?.count == 1200)

// Phone or email.
r.contact = "4177700000"
check("ten digits reads as a phone", r.contactLooksLikePhone)
r.contact = "(417) 770-0000"
check("a formatted number reads as a phone", r.contactLooksLikePhone)
r.contact = "dave@example.com"
check("an email is not a phone", !r.contactLooksLikePhone)
r.contact = "call me"
check("words are not a phone", !r.contactLooksLikePhone)

// The server's phone rule (kadeLoginId.js normalizePhone): 10 digits, or 11 starting with 1.
r.contact = "770-4722"
check("seven digits is not a phone", !r.contactLooksLikePhone)
check("seven digits asks for the area code before sending",
      r.missing == "Please include the area code, like 417-555-0123.")
r.contact = "+44 20 7946 0958"
check("a UK number is not a phone", !r.contactLooksLikePhone)
check("a foreign number says US or email", r.missing?.contains("US phone number") == true)
r.contact = "1-417-770-0000"
check("eleven digits starting with 1 is a phone", r.contactLooksLikePhone && r.missing == nil)
check("eleven digits starting with 1 drops the 1", AskToJoinRequest.usPhoneDigits("1-417-770-0000") == "4177700000")
r.contact = "2-417-770-0000"
check("eleven digits starting with 2 is not a phone", !r.contactLooksLikePhone && r.missing != nil)
r.contact = "call me"
check("words alone ask for a phone or email", r.missing?.contains("or an email address") == true)
r.contact = "dave@example"
check("an unfinished email is caught", r.missing?.contains("email address looks unfinished") == true)
r.contact = "Dave@Example.com or 417-770-0000"
check("an email anywhere wins, like the server", !r.contactLooksLikePhone && r.missing == nil
      && AskToJoinRequest.findEmail(r.contact) == "dave@example.com")
check("only 0-9 count as digits", AskToJoinRequest.asciiDigits("٤١٧ 417") == "417")

// Something typed is something to ask about before throwing it away.
var blank = AskToJoinRequest()
check("an empty form has nothing to lose", !blank.hasTypedSomething)
blank.sight = .sighted
check("a sight tap alone is not typing", !blank.hasTypedSomething)
blank.whoYouAre = "  hi "
check("words in any box count", blank.hasTypedSomething)

// Answers.
let ok = AskToJoinRequest.outcome(status: 200, serverMessage: "Request sent. Kade will review it.")
check("success keeps the server's words", ok.sent && ok.text == "Request sent. Kade will review it.")
check("success without words still says sent", AskToJoinRequest.outcome(status: 200, serverMessage: nil).sent)
let busy = AskToJoinRequest.outcome(status: 429, serverMessage: nil)
check("too many knocks is not sent and says wait", !busy.sent && busy.text.contains("Try again in a bit"))
let refused = AskToJoinRequest.outcome(status: 400, serverMessage: "Name, a way to reach you, and who you are.")
check("a refusal reads the server's reason", !refused.sent && refused.text.hasPrefix("Name"))
check("a blank 500 still says what to do", AskToJoinRequest.outcome(status: 500, serverMessage: "  ").text.contains("try again"))

if failures > 0 {
    print("\(failures) ask-to-join check(s) failed")
    exit(1)
}
print("All ask-to-join checks passed")
