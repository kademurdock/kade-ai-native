#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import AVFoundation

enum CharacterAuditCheckpoint {
    static func mark(_ label: String) {
        guard ProcessInfo.processInfo.environment["KADE_CHARACTER_AUDIT"] == "1" else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("character-checkpoint.txt")
        try? label.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Offline CI fixtures around the production view, player and call adapter.
/// No sign-in, provider, microphone, or real user data participates.
struct CharacterPortraitAuditView: View {
    @EnvironmentObject private var agents: AgentsService
    @EnvironmentObject private var voice: VoiceService
    @StateObject private var call = StreamingCallService(apiClient: KadeAPIClient())
    @State private var phase = "Starting"
    @State private var name = "Kiana"
    @State private var agentID = CharacterMotion.kianaID
    @State private var callMode = false
    @State private var gallery = true
    @State private var ran = false
    @State private var ready = false
    @State private var checks: [String] = []
    private let expressions: [CharacterExpression] = [.amused, .serious, .concerned, .skeptical, .surprised, .warm]

    var body: some View {
        VStack(spacing: 8) {
            Text("Character playback acceptance").font(.headline)
            Text(phase).accessibilityIdentifier("character-audit-phase")
            if !ready { ProgressView() }
            else if gallery {
                ForEach(expressions, id: \.rawValue) { expression in
                    HStack {
                        galleryPortrait(CharacterMotion.kianaID, "Kiana", expression)
                        galleryPortrait(CharacterMotion.dellaID, "Della", expression)
                    }
                }
            } else {
                CharacterPortraitView(agentID: agentID, name: name, playing: callMode || (voice.isClipPlaying && !voice.isPaused),
                    level: { callMode ? call.characterLevel : voice.characterLevel() }, listening: callMode,
                    presentation: { callMode ? call.characterPresentation : voice.characterPresentation() })
                Text(name).font(.title)
                Text("Existing audio player. Local synthetic test tones.")
            }
        }.padding(8).task { await run() }
    }
    private func galleryPortrait(_ id: String, _ name: String, _ expression: CharacterExpression) -> some View {
        VStack(spacing: 0) {
            CharacterPortraitView(agentID: id, name: name, playing: true, level: { 0 },
                presentation: { CharacterPresentation(activity: .speaking, expression: expression) })
                .scaleEffect(0.68).frame(width: 120, height: 117)
            Text(name + " · " + expression.rawValue).font(.caption)
        }
    }
    private var output: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private func step(_ label: String) {
        phase = label
        try? label.write(to: output.appendingPathComponent("character-phase.txt"), atomically: true, encoding: .utf8)
    }
    private func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw NSError(domain: "CharacterAudit", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
        checks.append(label)
    }
    private func packet(_ speaker: String, expression: String, speech: Bool = true) -> String {
        let value: [String: Any] = ["type": "character-audio", "version": 1, "speakerId": speaker, "speech": speech, "expression": expression]
        return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }
    private func run() async {
        guard !ran else { return }; ran = true
        agents.seedCharacterAudit()
        UserDefaults.standard.set(true, forKey: "kadeVoicePortraits")
        ready = true
        do {
            step("expression-gallery")
            for _ in 0..<100 {
                if (try? String(contentsOf: output.appendingPathComponent("character-captured.txt"), encoding: .utf8)) == "expression-gallery" { break }
                await wait(0.2)
            }
            gallery = false
            let wav = Self.wav(seconds: 3)
            for (id, label, direction, expected) in [(CharacterMotion.kianaID, "Kiana", "%%%amused%%%", CharacterExpression.amused),
                (CharacterMotion.dellaID, "Della", "%%%concerned%%%", CharacterExpression.concerned)] {
                agentID = id; name = label
                CharacterAuditCheckpoint.mark(label + " starting voice")
                let playback = Task { await voice.auditPlay(wav, agentID: id, direction: direction) }
                await wait(0.5)
                try check(voice.nowPlayingAgentID == id && voice.isClipPlaying, label + " owns real buffered playback")
                try check(voice.characterPresentation().expression == expected, label + " uses the playing clip's authored direction")
                try check(voice.characterLevel() > 0.01, label + " mouth receives actual AVAudioPlayer samples")
                step(label.lowercased() + "-voice-playing"); await wait(0.6)
                voice.pauseSpeaking(); await wait(0.2)
                try check(voice.characterLevel() == 0 && voice.characterPresentation().activity == .idle, label + " pauses the portrait with audio")
                step(label.lowercased() + "-voice-paused"); await wait(0.6)
                voice.resumeSpeaking(); await wait(0.2)
                try check(voice.characterLevel() > 0.01, label + " resumes the same recording")
                voice.stopSpeaking(); await playback.value
                try check(voice.characterLevel() == 0 && voice.nowPlayingAgentID == nil, label + " interruption clears identity")
            }
            callMode = true; name = "Della"; agentID = CharacterMotion.dellaID
            try call.auditStart(agentID: agentID)
            call.auditReceive(metadata: packet(agentID, expression: "surprised"), wav: wav)
            call.auditControl("{\"type\":\"state\",\"state\":\"listening\"}")
            await wait(0.5)
            try check(call.characterPresentation.activity == .speaking && call.characterLevel > 0.01, "actual call output outlives early server listening")
            try check(call.characterPresentation.expression == .surprised, "call reaction belongs to the audible clip")
            step("della-call-speaking"); await wait(0.8)
            call.auditControl("{\"type\":\"clear\"}"); await wait(0.2)
            try check(call.characterLevel == 0 && call.characterPresentation.activity != .speaking, "call barge-in clears mouth and expression")
            let shortWav = Self.wav(seconds: 1.4)
            call.auditReceive(metadata: packet(agentID, expression: "concerned"), wav: shortWav)
            call.auditReceive(metadata: packet(agentID, expression: "amused"), wav: shortWav)
            await wait(0.4)
            try check(call.characterLevel > 0.01 && call.characterPresentation.expression == .concerned, "first queued reaction resumes correctly after interruption")
            step("della-call-queued-first"); await wait(1.2)
            try check(call.characterLevel > 0.01 && call.characterPresentation.expression == .amused, "second queued reaction waits for its own audio")
            step("della-call-queued-second"); await wait(1.4)
            try check(call.characterLevel == 0 && call.characterPresentation.activity != .speaking, "completed call queue returns to listening")
            call.auditReceive(metadata: packet(CharacterMotion.kianaID, expression: "amused"), wav: wav)
            await wait(0.3)
            try check(call.characterLevel == 0, "another speaker cannot animate Della")
            call.auditControl("{\"type\":\"clear\"}")
            call.auditReceive(metadata: packet(agentID, expression: "warm", speech: false), wav: wav)
            await wait(0.3)
            try check(call.characterLevel == 0, "real output for a sound effect keeps the mouth closed")
            call.auditFinish()
            step("passed")
            let result: [String: Any] = ["passed": true, "checks": checks]
            try JSONSerialization.data(withJSONObject: result, options: .prettyPrinted).write(to: output.appendingPathComponent("character-audit.json"))
        } catch {
            voice.stopSpeaking(); call.auditFinish()
            let result: [String: Any] = ["passed": false, "checks": checks, "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted).write(to: output.appendingPathComponent("character-audit.json"))
            step("failed: " + error.localizedDescription)
        }
    }
    private static func wav(seconds: Double) -> Data {
        let rate = 24_000, count = Int(seconds * 24_000), bytes = count * 2
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { data.append(UInt8(value & 255)); data.append(UInt8(value >> 8)) }
        func u32(_ value: UInt32) { u16(UInt16(value & 65535)); u16(UInt16(value >> 16)) }
        ascii("RIFF"); u32(UInt32(bytes + 36)); ascii("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16); ascii("data"); u32(UInt32(bytes))
        for i in 0..<count {
            let value = Int16(sin(Double(i) * 2 * .pi * 230 / Double(rate)) * 6500)
            u16(UInt16(bitPattern: value))
        }
        return data
    }
}
#endif
