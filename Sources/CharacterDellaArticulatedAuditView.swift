#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit

/// Focused, silent art QA. The optional master and exact accepted face are
/// rendered through CharacterPortraitView; no player, sign-in or microphone
/// is constructed. The runner acknowledges each requested screenshot.
struct CharacterDellaArticulatedAuditView: View {
    @EnvironmentObject private var agents: AgentsService
    @State private var ready = false
    @State private var ran = false
    @State private var phase = "Preparing Della's offline body study"
    @State private var side = 208.0
    @State private var dark = false
    @State private var still = false
    @State private var arms = CharacterDellaArmPose.still
    @State private var head = CharacterBustPose(headAngle: 0, bodyAngle: 0, headOffsetY: 0, bodyOffsetY: 0)
    @State private var captures: [String] = []
    @State private var checks: [String] = []

    private var output: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    var body: some View {
        VStack(spacing: 12) {
            Text("Della's articulated body study").font(.headline)
            Text(phase).font(.caption).multilineTextAlignment(.center)
            if ready {
                CharacterPortraitView(agentID: CharacterMotion.dellaID, name: "Della",
                    playing: false, level: { 0 }, presentation: { .idle }, stage: true,
                    side: side, motionPaused: still, blinkAuditAmount: 0,
                    dellaArticulatedReview: true, dellaArmAudit: arms, dellaHeadAudit: head)
            }
            Text("Original face and collar. Silent, controlled sleeve and palm poses. Simulator art study.")
                .font(.footnote).multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dark ? Color.black : Color.white)
        .environment(\.colorScheme, dark ? .dark : .light)
        .task { await run() }
    }

    @MainActor private func capture(_ label: String) async throws {
        // Commit layout and title before announcing a capturable frame.
        phase = label
        try await Task.sleep(nanoseconds: 600_000_000)
        try label.write(to: output.appendingPathComponent("della-articulated-phase.txt"), atomically: true, encoding: .utf8)
        for _ in 0..<75 {
            if (try? String(contentsOf: output.appendingPathComponent("della-articulated-captured.txt"), encoding: .utf8)) == label {
                captures.append(label)
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw NSError(domain: "DellaArticulatedAudit", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Missing required screenshot: " + label])
    }

    @MainActor private func require(_ condition: Bool, _ name: String) throws {
        guard condition else { throw NSError(domain: "DellaArticulatedAudit", code: 1,
            userInfo: [NSLocalizedDescriptionKey: name]) }
        checks.append(name)
    }

    @MainActor private func run() async {
        guard !ran else { return }
        ran = true
        let defaults = UserDefaults.standard
        let previousPortraits = defaults.object(forKey: "kadeVoicePortraits")
        let previousReduceMotion = defaults.object(forKey: "kade.feedback.reduceMotion")
        defaults.set(true, forKey: "kadeVoicePortraits")
        defaults.set(false, forKey: "kade.feedback.reduceMotion")
        defer {
            if let previousPortraits { defaults.set(previousPortraits, forKey: "kadeVoicePortraits") }
            else { defaults.removeObject(forKey: "kadeVoicePortraits") }
            if let previousReduceMotion { defaults.set(previousReduceMotion, forKey: "kade.feedback.reduceMotion") }
            else { defaults.removeObject(forKey: "kade.feedback.reduceMotion") }
        }
        do {
            agents.seedCharacterAudit()
            let geometry = CharacterDellaArticulatedGeometry.self
            let resources = geometry.requiredAssets.allSatisfy { UIImage(named: $0) != nil }
            try require(resources, "Optional gesture master and accepted Della torso/matte are bundled")
            let pixelSize = UIImage(named: geometry.masterAsset)?.cgImage.map { [$0.width, $0.height] }
            try require(pixelSize == [1254, 1254], "The unchanged gesture master retains its common 1254-square canvas")
            try require(CharacterMotion.prepared(id: CharacterMotion.dellaID,
                path: agents.agents.first { $0.id == CharacterMotion.dellaID }?.avatar?.filepath),
                "The offline fixture uses Della's exact existing avatar registration")
            try require(geometry.cachedTorsoPath == geometry.torsoPath
                && geometry.cachedViewerLeftArmPath == geometry.viewerLeftArmPath
                && geometry.cachedViewerRightArmPath == geometry.viewerRightArmPath,
                "Cached clipping paths preserve the editable authored source geometry")
            ready = true
            for width in [160.0, 208.0] {
                side = width
                for theme in [false, true] {
                    dark = theme
                    let prefix = "della-articulated-\(Int(width))-\(theme ? "dark" : "light")"
                    still = false
                    arms = .still
                    head = CharacterBustPose(headAngle: 0, bodyAngle: 0, headOffsetY: 0, bodyOffsetY: 0)
                    try await capture(prefix + "-rest")
                    arms = CharacterDellaArmPose(viewerLeftDegrees: 3, viewerRightDegrees: -3)
                    try await capture(prefix + "-counter-inward")
                    arms = CharacterDellaArmPose(viewerLeftDegrees: -3, viewerRightDegrees: 3)
                    try await capture(prefix + "-counter-outward")
                    for direction in [-1.0, 1.0] {
                        head = CharacterBustPose(headAngle: direction * 1.55, bodyAngle: direction * 0.16,
                            headOffsetY: direction * 0.65, bodyOffsetY: 0)
                        try await capture(prefix + (direction < 0 ? "-head-left" : "-head-right"))
                    }
                    // Keep requested extrema set: policy must park those same
                    // input values, rather than merely photographing rest again.
                    still = true
                    try await capture(prefix + "-still")
                    still = false
                    defaults.set(true, forKey: "kade.feedback.reduceMotion")
                    try await capture(prefix + "-reduce-motion")
                    defaults.set(false, forKey: "kade.feedback.reduceMotion")
                }
            }
            try require(captures.count == 28, "Both phone widths, both appearances, extrema and policy stops are captured")
            try writeResult(passed: true, error: nil)
            phase = "Della's offline body study passed"
        } catch {
            try? writeResult(passed: false, error: error.localizedDescription)
            phase = "Della's offline body study failed: " + error.localizedDescription
        }
    }

    @MainActor private func writeResult(passed: Bool, error: String?) throws {
        var result: [String: Any] = ["passed": passed, "checks": checks, "captures": captures,
            "expectedCaptureCount": 28, "silent": true, "productionRegistrationChanged": false,
            "candidateDefaultEnabled": false, "cropWorld": [414, 620], "sourceSide": 1254,
            "bodyDestination": [-132, -1, 677.16, 677.16], "facePanelWorld": [0, 0, 414, 414],
            "headMaskDestination": [35, 0, 350], "maximumArmDegrees": 3,
            "expectedMasterSHA256": "285b6e1f176b79ba08cfc7a4252a3d8864901eabbdcbc1e58f304299164206d2",
            "physicalDeviceVerified": false]
        if let error { result["error"] = error }
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("della-articulated-audit.json"), options: .atomic)
    }
}
#endif
