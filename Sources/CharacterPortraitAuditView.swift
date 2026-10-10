#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import AVFoundation
import UIKit

enum CharacterAuditCheckpoint {
    static func mark(_ label: String) {
        guard ProcessInfo.processInfo.environment["KADE_CHARACTER_AUDIT"] == "1" else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("character-checkpoint.txt")
        try? label.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Fixture identities remain exact even when public and private Lilly share art.
/// This list never participates in authenticated agent discovery.
enum CharacterAuditPerson: String, CaseIterable {
    case harley, kiana, lilly, della, witherspoon
    case privateLilly = "lilly-private"
    case angel

    static var appearanceCases: [Self] { allCases.filter { $0 != .privateLilly } }
    var name: String {
        switch self {
        case .harley: return "Harley"
        case .kiana: return "Kiana"
        case .lilly, .privateLilly: return "Lilly"
        case .della: return "Della"
        case .witherspoon: return "Witherspoon"
        case .angel: return "Angel"
        }
    }
    var auditName: String { self == .privateLilly ? "Private Lilly" : name }
    var agentID: String {
        switch self {
        case .harley: return CharacterMotion.harleyID
        case .kiana: return CharacterMotion.kianaID
        case .lilly: return CharacterMotion.lillyID
        case .della: return CharacterMotion.dellaID
        case .witherspoon: return CharacterMotion.witherspoonID
        case .angel: return CharacterMotion.angelID
        case .privateLilly: return CharacterMotion.skyleeLillyID
        }
    }
    var avatarFile: String {
        switch self {
        case .harley: return CharacterMotion.harleyFile
        case .kiana: return CharacterMotion.kianaFile
        case .lilly: return CharacterMotion.lillyFile
        case .della: return CharacterMotion.dellaFile
        case .witherspoon: return CharacterMotion.witherspoonFile
        case .angel: return CharacterMotion.angelFile
        case .privateLilly: return CharacterMotion.skyleeLillyFile
        }
    }
    var atlasAssets: [String] {
        if self == .angel { return [] }
        let prefix = "Character" + name
        let base = [prefix + "Faces", prefix + "Mouths"]
        // Witherspoon deliberately uses basic expression panels only.
        return self == .witherspoon ? base : base + [prefix + "Nuance"]
    }
    var otherSpeakerID: String {
        switch self {
        case .lilly: return CharacterMotion.skyleeLillyID
        case .privateLilly: return CharacterMotion.lillyID
        case .kiana: return CharacterMotion.harleyID
        default: return CharacterMotion.kianaID
        }
    }
}

/// Offline CI fixtures around the production view and call adapter.
/// No sign-in, provider, microphone, or real user data participates.
struct CharacterPortraitAuditView: View {
    @EnvironmentObject private var agents: AgentsService
    @EnvironmentObject private var voice: VoiceService
    @StateObject private var call = StreamingCallService(apiClient: KadeAPIClient())
    @State private var phase = "Starting"
    @State private var name = "Harley"
    @State private var agentID = CharacterMotion.harleyID
    @State private var callMode = false
    @State private var gallery = true
    @State private var ran = false
    @State private var ready = false
    @State private var checks: [String] = []
    @State private var puppetPoses = false
    @State private var reviewAgentID = CharacterMotion.harleyID
    @State private var reviewName = "Harley"
    @State private var reviewPerformance = CharacterPresentation.idle
    @State private var reviewSide = 208.0
    @State private var reviewStill = false
    @State private var reviewDark = false
    @State private var handSample: Double? = nil
    @State private var handVariant = CharacterHarleyHandPrototypeVariant.smallRight
    @State private var facialStudy = false
    @State private var blinkSample: Double? = nil
    @State private var angelFaceSample: CharacterFace? = nil
    @State private var angelMouthSample: Int? = nil
    @State private var angelGallery = false
    @State private var angelMotionSample: CharacterBustPose? = nil
    @State private var angelOrnamentsSample: AngelVectorOrnamentPose? = nil
    @State private var angelArmSample: AngelVectorArmPose? = nil
    private let expressions: [CharacterExpression] = [.amused, .serious, .concerned, .skeptical, .surprised, .warm]

    var body: some View {
        VStack(spacing: 8) {
            Text("Character playback acceptance").font(.headline)
            Text(phase).accessibilityIdentifier("character-audit-phase")
            if !ready { ProgressView() }
            else if angelGallery, let art = CharacterAngelArtwork.loaded {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 6) {
                    ForEach(CharacterFace.allCases, id: \.rawValue) { face in
                        VStack(spacing: 2) {
                            CharacterAngelVectorView(art: art,
                                facial: AngelVectorMotion.facial(face, blink: 0, active: true),
                                mouth: AngelVectorMotion.mouth(role: 0, strength: 0, face: face, active: true),
                                ornaments: .still)
                                .frame(width: 84, height: 84)
                            Text("Face \(face.rawValue)").font(.caption2)
                        }
                    }
                }
                Text("Angel's seventeen original geometric expressions. Static offline gallery.").font(.caption)
            } else if gallery {
                ForEach(expressions, id: \.rawValue) { expression in
                    HStack {
                        galleryPortrait(CharacterMotion.kianaID, "Kiana", expression)
                        galleryPortrait(CharacterMotion.dellaID, "Della", expression)
                    }
                }
            } else if puppetPoses {
                CharacterPortraitView(agentID: reviewAgentID, name: reviewName,
                    playing: angelMouthSample != nil, level: { 0 },
                    presentation: { reviewPerformance }, stage: true, side: reviewSide,
                    motionPaused: reviewStill, handPrototypeElapsed: handSample,
                    handPrototypeVariant: handVariant, blinkAuditAmount: blinkSample,
                    angelFaceAudit: angelFaceSample, angelMouthAudit: angelMouthSample,
                    angelMotionAudit: angelMotionSample, angelOrnamentsAudit: angelOrnamentsSample,
                    angelArmAudit: angelArmSample)
                Text(reviewName + (facialStudy ? " · controlled face preview"
                    : (handSample == nil ? " · production puppet" : " · hand study")))
                if facialStudy {
                    Text("Authored face study. No audio; simulator preview, not a recording of a production call.")
                } else if handSample != nil {
                    Text("Unregistered hand prototype. Controlled motion sample; not enabled in the app.")
                } else {
                    Text(reviewAgentID == CharacterMotion.angelID
                        ? "Angel's own vector face, robe, white feather wings and pearl-gold halo. Controlled geometry, no audio."
                        : (CharacterMotion.rigID(reviewAgentID) == CharacterMotion.lillyID
                        ? "Head and hoodie. Original cats remain still; arms do not move independently. Compact stages retain the portrait."
                        : "Head and shoulders. Arms do not move independently. Compact stages retain the portrait."))
                }
            } else {
                CharacterPortraitView(agentID: agentID, name: name,
                    playing: callMode ? call.status == .speaking : (voice.isClipPlaying && !voice.isPaused),
                    level: { callMode ? call.characterLevel : voice.characterLevel() }, listening: callMode,
                    presentation: { callMode ? call.characterPresentation : voice.characterPresentation() },
                    stage: true, side: 208)
                Text(name).font(.title)
                Text("Offline audio engine. Local synthetic test tones.")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The app owns its window appearance. Set the fixture's own environment
        // and backdrop so an ancestor preference cannot silently turn dark QA light.
        .background(reviewDark ? Color.black : Color.white)
        .environment(\.colorScheme, reviewDark ? .dark : .light)
        .task { await run() }
    }
    private func galleryPortrait(_ id: String, _ name: String, _ expression: CharacterExpression) -> some View {
        VStack(spacing: 0) {
            CharacterPortraitView(agentID: id, name: name, playing: true, level: { 0 },
                presentation: { CharacterPresentation(activity: .speaking, expression: expression) })
                .scaleEffect(0.58).frame(width: 112, height: 100)
            Text(name + " · " + expression.rawValue).font(.caption)
        }
    }
    private var output: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private func advance(_ seconds: Double) async throws {
        for _ in 0..<Int((seconds * 50).rounded()) {
            try call.auditRender(frames: 480)
            await wait(0.02)
        }
    }
    private func step(_ label: String) {
        phase = label
        try? label.write(to: output.appendingPathComponent("character-phase.txt"), atomically: true, encoding: .utf8)
    }
    private func capturePose(_ label: String) async throws {
        // Let SwiftUI lay out the changed mode before the runner sees its label.
        await wait(0.6)
        // Publishing the file can wake the runner before the phase Text has
        // committed its new label. Set it first, then allow a UI frame to pass.
        phase = label
        await wait(0.12)
        step(label)
        for _ in 0..<25 {
            if (try? String(contentsOf: output.appendingPathComponent("character-captured.txt"), encoding: .utf8)) == label { return }
            await wait(0.2)
        }
        throw NSError(domain: "CharacterAudit", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Missing required screenshot: " + label])
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
        UserDefaults.standard.set(false, forKey: "kade.feedback.reduceMotion")
        ready = true
        do {
            try await capturePose("expression-gallery")
            gallery = false
            let roster = CharacterAuditPerson.allCases
            let resolved = roster.filter { person in
                CharacterPuppetRegistration.approved(stage: true, side: 208,
                    agentID: person.agentID, avatarPath: "/images/" + person.avatarFile)
            }
            try check(resolved.filter { $0 != .angel }.count == 6 && Set(roster.filter { $0 != .angel }.map { $0.agentID }).count == 6,
                "all six exact production puppet registrations resolve")
            try check(resolved.count == 7 && Set(roster.map { $0.agentID }).count == 7,
                "Angel joins seven exact production puppet registrations")
            guard let angelArt = CharacterAngelArtwork.loaded,
                  let angelCache = CharacterAngelArtwork.cacheAudit else {
                throw NSError(domain: "CharacterAudit", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Angel's verified vector drawing is not cached"])
            }
            try check(angelCache.shapeCount == angelArt.shapes.count && angelCache.shapeCount == 149
                && angelCache.groupCount == CharacterAngelVectorArt.groups.count,
                "Angel caches every verified ornamental path in all five authored groups")
            try check(angelCache.retainsSourceOrder && angelCache.finiteGeometry && angelCache.paintContractsMatch,
                "cached Angel paths preserve source order, finite geometry, paints and opacity")
            for person in roster {
                if person == .angel {
                    try check(CharacterAngelArtwork.approved(agentID: person.agentID,
                        avatarPath: "/images/" + person.avatarFile) != nil,
                        "Angel original vector resources are bundled")
                    continue
                }
                let artwork = CharacterBustArtwork.approved(stage: true, side: 208,
                    agentID: person.agentID, avatarPath: "/images/" + person.avatarFile)
                let resourcesAvailable = artwork.map { pack in
                    !pack.requiredAssets.isEmpty && (pack.requiredAssets + person.atlasAssets).allSatisfy { UIImage(named: $0) != nil }
                } ?? false
                try check(resourcesAvailable, person.auditName + " production resources are bundled")
            }
            puppetPoses = true
            for person in CharacterAuditPerson.appearanceCases {
                reviewAgentID = person.agentID
                reviewName = person.name
                for dark in [false, true] {
                    reviewDark = dark
                    for (activity, state) in [(CharacterActivity.idle, "idle"), (.listening, "listening"), (.thinking, "thinking")] {
                        reviewPerformance = CharacterPresentation(activity: activity)
                        try await capturePose("\(person.rawValue)-puppet-\(state)-\(dark ? "dark" : "light")")
                    }
                }
                reviewStill = true
                try await capturePose(person.rawValue + "-puppet-still")
                reviewStill = false
                for size in [84.0, 104.0, 132.0] {
                    reviewSide = size
                    try await capturePose("\(person.rawValue)-compact-portrait-\(Int(size))")
                }
                reviewSide = 208
            }
            // A separate exact-ID proof; the private agent keeps its own avatar gate.
            reviewAgentID = CharacterAuditPerson.privateLilly.agentID
            reviewName = CharacterAuditPerson.privateLilly.auditName
            reviewPerformance = .idle
            reviewDark = false
            try await capturePose("lilly-private-production-puppet")
            // A controlled study uses the existing production portrait and
            // crop, with the candidate hand added only in DEBUG simulators.
            reviewAgentID = CharacterMotion.harleyID
            reviewName = "Harley"
            reviewPerformance = CharacterPresentation(activity: .listening)
            try check(UIImage(named: "CharacterHarleyGreetingHandPrototype") != nil,
                "Harley hand study resource is bundled for simulator review")
            try check(!CharacterHarleyHandPrototypeMotion.pose(elapsed: 1, active: false).visible,
                "disabled motion hides the hand study entirely")
            for variant in [CharacterHarleyHandPrototypeVariant.smallRight, .largeLeft] {
                handVariant = variant
                let prefix = variant == .smallRight ? "harley-hand-study" : "harley-hand-study-large-left"
                for dark in [false, true] {
                    reviewDark = dark
                    for (sample, label) in [(0.0, "rest"), (0.25, "entry"), (0.5, "raised"),
                                           (0.625, "right"), (0.875, "left"), (1.75, "exit"), (2.0, "finished")] {
                        handSample = sample
                        try await capturePose("\(prefix)-\(label)-\(dark ? "dark" : "light")")
                    }
                    handSample = 0.5
                    reviewStill = true
                    try await capturePose("\(prefix)-motion-off-\(dark ? "dark" : "light")")
                    reviewStill = false
                    UserDefaults.standard.set(true, forKey: "kade.feedback.reduceMotion")
                    try await capturePose("\(prefix)-reduce-motion-\(dark ? "dark" : "light")")
                    UserDefaults.standard.set(false, forKey: "kade.feedback.reduceMotion")
                    handSample = 0
                    try await capturePose("\(prefix)-full-cycle-\(dark ? "dark" : "light")")
                    for tick in 1...48 {
                        handSample = Double(tick) / 24
                        await wait(1.0 / 24)
                    }
                }
            }
            handVariant = .smallRight
            handSample = nil
            facialStudy = true
            reviewDark = false
            reviewStill = false
            reviewSide = 208
            // Keep the exact production compositor visible through complete
            // blink windows. These controlled faces do not simulate speech
            // audio or assert audible synchronization.
            for person in roster {
                reviewAgentID = person.agentID
                reviewName = person.auditName
                reviewPerformance = CharacterPresentation(activity: .speaking,
                    expression: .amused, elapsed: 0.4, laughing: true)
                try await capturePose(person.rawValue + "-authored-laugh-light")
                await wait(person == .della || person == .witherspoon ? 6 : 2)
                reviewPerformance = CharacterPresentation(activity: .speaking,
                    expression: .excited, elapsed: 0.4, laughing: false)
                try await capturePose(person.rawValue + "-authored-excited-light")
                await wait(2)
            }
            // Review the full authored eyelid over three different faces.
            // Deterministic samples make the remaining spatial edge observable
            // even when an ordinary blink falls between screenshot captures.
            for person in [CharacterAuditPerson.lilly, .privateLilly] {
                reviewAgentID = person.agentID
                reviewName = person.auditName
                for (expression, label) in [(CharacterExpression.neutral, "neutral"),
                                           (.concerned, "concerned"), (.warm, "smile")] {
                    reviewPerformance = CharacterPresentation(activity: .listening, expression: expression)
                    for (amount, state) in [(0.0, "open"), (1.0, "closed")] {
                        blinkSample = amount
                        try await capturePose("\(person.rawValue)-blink-mask-\(label)-\(state)-light")
                    }
                }
            }
            blinkSample = nil
            reviewAgentID = CharacterMotion.angelID
            reviewName = "Angel"
            reviewPerformance = .idle
            blinkSample = 0
            angelFaceSample = .neutral
            angelGallery = true
            try await capturePose("angel-face-gallery")
            angelGallery = false
            for face in CharacterFace.allCases {
                angelFaceSample = face
                try await capturePose("angel-expression-\(face.rawValue)-light")
            }
            angelFaceSample = .neutral
            reviewPerformance = CharacterPresentation(activity: .speaking)
            for role in 0...8 {
                angelMouthSample = role
                try await capturePose("angel-mouth-\(role)-light")
            }
            angelMouthSample = nil
            reviewPerformance = .idle
            for (amount, label) in [(0.0, "open"), (0.5, "half"), (1.0, "closed")] {
                blinkSample = amount
                try await capturePose("angel-blink-\(label)-light")
            }
            // Continuous geometric eyelids, not crossfaded authored rasters.
            for tick in 0...48 {
                blinkSample = (1 - cos(Double(tick) / 48 * 2 * .pi)) / 2
                await wait(1.0 / 24)
            }
            blinkSample = 0
            for (direction, label) in [(-1.0, "left"), (1.0, "right")] {
                angelMotionSample = CharacterBustPose(headAngle: direction * 1.8,
                    bodyAngle: direction * 0.4, headOffsetY: direction * 2,
                    bodyOffsetY: direction * 1.5)
                angelOrnamentsSample = AngelVectorOrnamentPose(leftWingDegrees: direction * 1.8,
                    rightWingDegrees: -direction * 1.8, haloOffsetY: direction * 0.003,
                    haloDegrees: direction * 0.35, sparkle: direction < 0 ? 0.21 : 0.51)
                try await capturePose("angel-motion-extreme-\(label)-light")
            }
            angelMotionSample = nil
            angelOrnamentsSample = nil
            // The exact original sleeve/hand paths move together. Capture both
            // limits, both backgrounds and a policy stop before normal playback.
            for dark in [false, true] {
                reviewDark = dark
                let theme = dark ? "dark" : "light"
                angelArmSample = .still
                try await capturePose("angel-clasp-rest-\(theme)")
                for (direction, label) in [(-1.0, "left"), (1.0, "right")] {
                    angelArmSample = AngelVectorArmPose(
                        degrees: direction * AngelVectorArmPose.maximumDegrees,
                        offsetX: direction * AngelVectorArmPose.maximumOffsetX,
                        offsetY: -AngelVectorArmPose.maximumOffsetY)
                    try await capturePose("angel-clasp-\(label)-\(theme)")
                }
            }
            reviewDark = false
            UserDefaults.standard.set(true, forKey: "kade.feedback.reduceMotion")
            try await capturePose("angel-clasp-reduce-motion-light")
            UserDefaults.standard.set(false, forKey: "kade.feedback.reduceMotion")
            angelArmSample = nil
            blinkSample = nil
            angelFaceSample = nil
            facialStudy = false
            reviewPerformance = .idle
            reviewDark = false
            gallery = false
            puppetPoses = false
            let wav = Self.wav(seconds: 3)
            callMode = true
            CharacterAuditCheckpoint.mark("Starting offline call engine")
            try call.auditStart(agentID: agentID)
            for person in roster {
                let id = person.agentID, label = person.auditName, other = person.otherSpeakerID
                agentID = id; name = person.name; call.auditSpeaker(id)
                // Keep every character switch in the continuous video, including its
                // first 0.45 seconds, then capture the settled production compositor.
                try await capturePose(person.rawValue + "-character-transition")
                CharacterAuditCheckpoint.mark(label + " rendering offline call")
                call.auditReceive(metadata: packet(agentID, expression: "surprised"), wav: wav)
                call.auditControl("{\"type\":\"state\",\"state\":\"listening\"}")
                try await advance(0.5)
                try check(call.status == .listening, label + " caller state is listening while rendered speech remains authoritative")
                try check(call.characterPresentation.activity == .speaking && call.characterLevel > 0.01, label + " rendered call output outlives early server listening")
                try check(call.characterPresentation.expression == .surprised, label + " reaction belongs to the rendered clip")
                try await capturePose(person.rawValue + "-call-speaking"); try await advance(0.8)
                call.auditControl("{\"type\":\"clear\"}"); try await advance(0.2)
                try check(call.characterLevel == 0 && call.characterPresentation.activity != .speaking, label + " barge-in clears mouth and expression")
                try await capturePose(person.rawValue + "-call-interrupted"); try await advance(0.4)
                let shortWav = Self.wav(seconds: 1.4)
                call.auditReceive(metadata: packet(agentID, expression: "concerned"), wav: shortWav)
                call.auditReceive(metadata: packet(agentID, expression: "amused"), wav: shortWav)
                try await advance(0.4)
                try check(call.characterLevel > 0.01 && call.characterPresentation.expression == .concerned, label + " first queued reaction resumes correctly after interruption")
                try await capturePose(person.rawValue + "-call-queued-first"); try await advance(1.2)
                try check(call.characterLevel > 0.01 && call.characterPresentation.expression == .amused, label + " second queued reaction waits for its own audio")
                try await capturePose(person.rawValue + "-call-queued-second"); try await advance(1.4)
                try check(call.characterLevel == 0 && call.characterPresentation.activity != .speaking, label + " completed call queue returns to listening")
                call.auditReceive(metadata: packet(other, expression: "amused"), wav: wav)
                try await advance(0.3)
                try check(call.characterLevel == 0, "another speaker cannot animate " + label)
                call.auditControl("{\"type\":\"clear\"}")
                call.auditReceive(metadata: packet(agentID, expression: "warm", speech: false), wav: wav)
                try await advance(0.3)
                try check(call.characterLevel == 0, label + " sound effect output keeps the mouth closed")
                call.auditControl("{\"type\":\"clear\"}")
                call.auditReceive(metadata: "{\"type\":\"character-audio\",\"version\":99}", wav: wav)
                try await advance(0.3)
                try check(call.characterLevel == 0, label + " unsupported metadata cannot animate speech")
            }
            call.auditFinish()
            try await capturePose("passed")
            let result: [String: Any] = ["passed": true, "checks": checks,
                "mode": "offline-AVAudioEngine", "physicalAudioVerified": false,
                "productionPuppets": true, "registeredCharacterIDs": roster.map { $0.agentID },
                "appearanceCount": CharacterAuditPerson.appearanceCases.count,
                "registeredCount": resolved.count,
                "ordinaryScreenLayoutVerified": false,
                "unverified": ["AVAudioPlayer real-time voice-message playback", "Physical speaker and Bluetooth", "Microphone and live network call", "Physical VoiceOver"]]
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
