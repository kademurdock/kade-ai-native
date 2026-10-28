import Foundation

// Oct 28 2026: the live video face gate and the painted-loop pick.
// Compiled by run-live-face-tests.sh with Sources/LiveFacePolicy.swift only.
var failures = 0
func check(_ name: String, _ ok: Bool) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

let kiana = "agent_6llV0eMu4fmIaj8f2x1Sb"
let harley = "agent_d26Mtu8mgOzkVGQECqO1a"
let della = "agent_della"
let faces: Set<String> = [kiana, harley]

func verdict(sight: String = SightSetting.sighted, liveFaces: Bool = true, voiceOver: Bool = false,
             serverEnabled: Bool = true, agentID: String? = kiana, motionAllowed: Bool = true,
             stage: Bool = true) -> LiveFaceRefusal? {
    LiveFacePolicy.refusal(sight: sight, liveFaces: liveFaces, voiceOver: voiceOver,
        serverEnabled: serverEnabled, agents: faces, agentID: agentID,
        motionAllowed: motionAllowed, stage: stage)
}

// The one rule: nobody who has not said they use the screen is ever charged.
check("unset account stays closed", verdict(sight: SightSetting.unset) == .notSighted)
check("blind account stays closed", verdict(sight: SightSetting.nonvisual) == .notSighted)
check("sighted account on the stage opens", verdict() == nil)
check("the switch closes it", verdict(liveFaces: false) == .switchedOff)
check("VoiceOver closes it even for a sighted account", verdict(voiceOver: true) == .voiceOver)
check("Reduce Motion / Low Power closes it", verdict(motionAllowed: false) == .motionOff)
check("no server setup is its own answer", verdict(serverEnabled: false) == .notOffered)
check("Della has no live face yet", verdict(agentID: della) == .noFace)
check("Harley has one", verdict(agentID: harley) == nil)
check("a compact row never opens one", verdict(stage: false) == .notStage)
check("no agent, nothing", verdict(agentID: nil) == .noAgent)
check("sight beats the switch in the order of answers", verdict(sight: SightSetting.nonvisual, liveFaces: false) == .notSighted)

check("calls load the page muted", LiveFacePolicy.pageMuted(lane: .call))
check("chat clips are heard from the page", !LiveFacePolicy.pageMuted(lane: .chat))
check("clip timeout covers the clip and the lag", LiveFacePolicy.clipTimeout(seconds: 6.5) == 10.5)
check("a tiny clip still gets a floor", LiveFacePolicy.clipTimeout(seconds: 0.2) == 6)
check("chunks are a quarter second of PCM16 at 16 kHz", LiveFacePolicy.chunkBytes == 16000 * 2 / 4)

// Painted loops: decoration for sighted people between replies only.
func loop(sight: String = SightSetting.sighted, speaking: Bool = false, thinking: Bool = false,
          listening: Bool = false, face: String = "neutral", motionAllowed: Bool = true,
          liveFaceUp: Bool = false) -> CharacterLoopState? {
    CharacterLoopPolicy.state(sight: sight, speaking: speaking, thinking: thinking, listening: listening,
        face: face, motionAllowed: motionAllowed, liveFaceUp: liveFaceUp)
}
check("blind account loads no loops", loop(sight: SightSetting.nonvisual) == nil)
check("unset account loads no loops", loop(sight: SightSetting.unset) == nil)
check("the rig keeps the mouth while speaking", loop(speaking: true) == nil)
check("the live face wins over loops", loop(liveFaceUp: true) == nil)
check("motion off, no loops", loop(motionAllowed: false) == nil)
check("idle by default", loop() == .idle)
check("listening on a call", loop(listening: true) == .listening)
check("thinking while a reply is out", loop(thinking: true) == .thinking)
check("a laugh face picks the laugh loop", loop(face: "laugh") == .laugh)
check("a worried face picks the concerned loop", loop(face: "worried") == .concerned)
check("surprise", loop(face: "surprised") == .surprised)
check("Kiana's loops have a home", CharacterLoopPolicy.url(agentID: kiana, state: .idle)?.absoluteString
    == "https://kademurdock.com/assets/characters/kiana/loops/idle.mp4")
check("Harley's loops have a home", CharacterLoopPolicy.folder(agentID: harley) == "harley")
check("others have none", CharacterLoopPolicy.url(agentID: della, state: .idle) == nil)

if failures > 0 {
    print("\(failures) live face check(s) failed")
    exit(1)
}
print("live face checks passed")
