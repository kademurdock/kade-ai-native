#if DEBUG && targetEnvironment(simulator)
import Foundation
import SwiftUI
import UIKit

/// A finite offline input sample passed through the ordinary portrait renderer.
/// The captured frame retains its active pose while its audit clock is frozen.
struct CharacterPuppetCompletionSample {
    let time: Double
    let performanceElapsed: Double
    let presentation: CharacterPresentation
    let outputLevel: Double
    var captureFrozen: Bool = false
}

enum CharacterPuppetCompletionAudit {
    enum Pose: String, CaseIterable { case neutral, gesturePeak, settled }
    static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["KADE_CHARACTER_AUDIT"] == "1"
            && environment["KADE_PUPPET_COMPLETION_AUDIT"] == "1"
    }
    static var uiDriven: Bool {
        isEnabled && ProcessInfo.processInfo.environment["KADE_PUPPET_COMPLETION_UI"] == "1"
    }
    static var source: String {
        ProcessInfo.processInfo.environment["KADE_PUPPET_COMPLETION_SOURCE"] ?? ""
    }
    static let filename = "puppet-completion-ready.json"
    static let acknowledgementFilename = "puppet-completion-captured.txt"
    static let phases = CharacterAuditPerson.allCases.flatMap { person in
        Pose.allCases.map { person.rawValue + "-" + $0.rawValue }
    }
    static func person(index: Int) -> CharacterAuditPerson {
        CharacterAuditPerson.allCases[index / Pose.allCases.count]
    }
    static func pose(index: Int) -> Pose { Pose.allCases[index % Pose.allCases.count] }
}

/// Records actual production renderer outputs and measured native rectangles.
/// It never invokes a player, microphone, network request or independent clock.
@MainActor
enum CharacterPuppetCompletionRecorder {
    private(set) static var phase = ""
    private(set) static var person: CharacterAuditPerson = .harley
    private(set) static var tickCount = 0
    private(set) static var activeSamples = 0
    private(set) static var pausedSamples = 0
    private(set) static var maximumFPS = 0.0
    private(set) static var times = Set<Double>()
    private(set) static var vectors = Set<String>()
    private(set) static var frames: [String: CGRect] = [:]
    private(set) static var last: [String: Any] = [:]
    private(set) static var invalidSample = false

    static func begin(phase next: String, person nextPerson: CharacterAuditPerson) {
        phase = next; person = nextPerson
        tickCount = 0; activeSamples = 0; pausedSamples = 0; maximumFPS = 0
        times = []; vectors = []; frames = [:]; last = [:]; invalidSample = false
    }
    static func recordFrame(_ key: String, _ frame: CGRect) {
        guard CharacterPuppetCompletionAudit.isEnabled,
              ["stage", "portrait"].contains(key),
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else { return }
        frames[key] = frame
    }
    static func recordTick(agentID: String?, renderer: String, assets: [String],
                           side: Double, height: Double, time: Double, active: Bool,
                           budget: CharacterAnimationBudget, face: CharacterFace,
                           viseme: Int, values: [String: Double]) {
        guard CharacterPuppetCompletionAudit.isEnabled, !phase.isEmpty else { return }
        let valid = agentID == person.agentID && !renderer.isEmpty && renderer.count <= 40
            && assets.count <= 16 && assets.allSatisfy { !$0.isEmpty && $0.count <= 80 }
            && [side, height, time, budget.framesPerSecond].allSatisfy(\.isFinite)
            && side > 0 && height > 0 && time >= 0 && (0...24).contains(budget.framesPerSecond)
            && (0...8).contains(viseme) && !values.isEmpty && values.count <= 40
            && values.allSatisfy { $0.key.count <= 40 && $0.value.isFinite && abs($0.value) <= 10_000 }
        guard valid else { invalidSample = true; return }
        guard tickCount < 256 else { invalidSample = true; return }
        tickCount += 1
        if active && !budget.paused { activeSamples += 1 } else { pausedSamples += 1 }
        maximumFPS = max(maximumFPS, budget.framesPerSecond)
        times.insert(time)
        let vector = values.keys.sorted().map { $0 + "=" + String(format: "%.6f", values[$0]!) }.joined(separator: ";")
        vectors.insert(vector)
        last = ["agentID": person.agentID, "renderer": renderer, "assets": assets,
                "side": side, "height": height, "time": time, "active": active,
                "framesPerSecond": budget.framesPerSecond, "paused": budget.paused,
                "face": face.rawValue, "viseme": viseme, "values": values]
    }
    static func ready(policy: String, frozen: Bool, completedInputs: Int) -> [String: Any]? {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow), !last.isEmpty,
              let stage = frames["stage"], let portrait = frames["portrait"] else { return nil }
        func rectangle(_ value: CGRect) -> [Double] {
            [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)]
        }
        return ["schema": "kade.puppet-completion-ready.v1", "source": CharacterPuppetCompletionAudit.source,
                "phase": phase, "character": person.rawValue, "avatarPath": "/images/" + person.avatarFile,
                "appearance": window.traitCollection.userInterfaceStyle == .dark ? "dark" : "light",
                "windowPoints": [Double(window.bounds.width), Double(window.bounds.height)],
                "geometry": ["window": rectangle(window.frame), "stage": rectangle(stage), "portrait": rectangle(portrait)],
                "render": last, "samples": ["count": tickCount, "active": activeSamples,
                    "paused": pausedSamples, "distinctTimes": times.count, "distinctVectors": vectors.count,
                    "maximumFPS": maximumFPS, "invalid": invalidSample],
                "policy": policy, "captureFrozen": frozen, "completedInputs": completedInputs,
                "jointCoordinateSpace": "rendererLocalBeforeParentTransform",
                "syntheticOutput": true, "networkRequestsBlocked": true,
                "blockedRequestCount": KadeAPIClient.hostAuditBlockedRequestCount,
                "audioStarted": false, "microphoneStarted": false, "cameraStarted": false,
                "physicalPhoneVerified": false, "batteryMeasured": false, "voiceOverVerified": false]
    }
    static func write(_ data: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(data),
              let bytes = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
              bytes.count <= 64 * 1024,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        do {
            try bytes.write(to: documents.appendingPathComponent(CharacterPuppetCompletionAudit.filename), options: .atomic)
            return true
        } catch { return false }
    }
}
#endif
