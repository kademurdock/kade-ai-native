#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit

/// Silent all-cast samples around the production portrait and its one clock.
/// A finite input sequence is observed natively before each inspection frame.
struct CharacterPuppetCompletionAuditView: View {
    @EnvironmentObject private var agents: AgentsService
    @State private var seeded = false
    @State private var index = 0
    @State private var sample: CharacterPuppetCompletionSample?
    @State private var revision = 0
    @State private var status = "pending"
    @State private var renderer = ""
    @State private var activeSamples = "0"
    @State private var distinctVectors = "0"
    @State private var fps = "0"
    @State private var face = "0"
    @State private var viseme = "0"
    private let policies = ["compact", "reduceMotion", "offscreen", "resume"]

    private var events: Bool {
        CharacterPuppetCompletionAudit.uiDriven
            && ProcessInfo.processInfo.environment["KADE_PUPPET_COMPLETION_EVENTS"] == "1"
    }
    private var count: Int { events ? CharacterAuditPerson.allCases.count * policies.count : CharacterPuppetCompletionAudit.phases.count }
    private var person: CharacterAuditPerson {
        events ? CharacterAuditPerson.allCases[index / policies.count] : CharacterPuppetCompletionAudit.person(index: index)
    }
    private var policy: String { events ? policies[index % policies.count] : "normal" }
    private var pose: CharacterPuppetCompletionAudit.Pose {
        events ? .gesturePeak : CharacterPuppetCompletionAudit.pose(index: index)
    }
    private var phase: String { events ? person.rawValue + "-" + policy : CharacterPuppetCompletionAudit.phases[index] }
    private var side: Double { policy == "compact" ? 84 : 208 }
    private var portrait: CharacterPortraitView {
        var view = CharacterPortraitView(agentID: person.agentID, name: person.name,
            playing: pose != .neutral, level: { sample?.outputLevel ?? 0 },
            presentation: { sample?.presentation ?? .idle }, stage: true, side: side)
        view.dellaArticulatedReview = true
        view.completionAuditSample = sample
        return view
    }
    private struct ObservedFrame: Equatable { let revision: Int; let frame: CGRect }

    var body: some View {
        VStack(spacing: 8) {
            Text("Puppet completion acceptance").font(.headline)
            Text(phase).accessibilityIdentifier("puppet-completion.phase")
            Spacer(minLength: 0)
            if seeded {
                VStack(spacing: 0) {
                    portrait
                        .id(person.rawValue)
                        .onGeometryChange(for: ObservedFrame.self, of: { geometry in
                            ObservedFrame(revision: revision, frame: geometry.frame(in: .global))
                        }) { CharacterPuppetCompletionRecorder.recordFrame("portrait", $0.frame) }
                }
                .padding(.vertical, 4)
                .offset(y: policy == "offscreen" ? UIScreen.main.bounds.height * 2 : 0)
                .onGeometryChange(for: ObservedFrame.self, of: { geometry in
                    ObservedFrame(revision: revision, frame: geometry.frame(in: .global))
                }) { CharacterPuppetCompletionRecorder.recordFrame("stage", $0.frame) }
                .task(id: phase) { await runPhase() }
            }
            Spacer(minLength: 0)
            Text(status).accessibilityIdentifier("puppet-completion.status")
            Text(renderer).accessibilityIdentifier("puppet-completion.renderer")
            HStack {
                Text(activeSamples).accessibilityIdentifier("puppet-completion.activeSamples")
                Text(distinctVectors).accessibilityIdentifier("puppet-completion.distinctVectors")
                Text(fps).accessibilityIdentifier("puppet-completion.fps")
                Text(face).accessibilityIdentifier("puppet-completion.face")
                Text(viseme).accessibilityIdentifier("puppet-completion.viseme")
            }.font(.caption2)
            if CharacterPuppetCompletionAudit.uiDriven {
                Button("Next sample") { if index + 1 < count { index += 1 } }
                    .accessibilityIdentifier("puppet-completion.next")
                    .disabled(status != "ready" || index + 1 >= count)
            }
            Text("Controlled offline output. No audio or account connection.").font(.caption)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .task {
            guard CharacterPuppetCompletionAudit.isEnabled else { status = "failed"; return }
            agents.seedCharacterAudit()
            FeedbackPrefs.shared.forceReduceMotion = false
            seeded = true
        }
    }

    @MainActor
    private func runPhase() async {
        status = "pending"; renderer = ""; activeSamples = "0"; distinctVectors = "0"
        FeedbackPrefs.shared.forceReduceMotion = policy == "reduceMotion"
        CharacterPuppetCompletionRecorder.begin(phase: phase, person: person)
        let sequence: [Double] = pose == .settled
            ? [0.65, 0.8, 1.6, 2.8, 4.5, 6.8, 9.6, 14, 14.25]
            : [0, 0.08, 0.16, 0.24, 0.325, 0.405, 0.485, 0.565, 0.65]
        let base = 1000 + Double(CharacterAuditPerson.allCases.firstIndex(of: person)!) * 100
        for (number, elapsed) in sequence.enumerated() {
            guard !Task.isCancelled else { return }
            var performance = pose == .neutral ? CharacterPresentation.idle
                : CharacterPresentation(activity: .speaking, expression: .warm, elapsed: elapsed)
            if pose != .neutral {
                performance.outputEpisodeKey = person.rawValue + "-completion-episode"
                performance.outputPhase = .playing
                performance.outputSpeakerID = person.agentID
            }
            let level = pose == .neutral || (pose == .settled && elapsed >= 9.6) ? 0.0 : 0.22
            sample = CharacterPuppetCompletionSample(time: base + elapsed - (pose == .neutral ? 0.7 : 0),
                performanceElapsed: elapsed, presentation: performance, outputLevel: level)
            revision = number + 1
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
        }
        guard var frozen = sample else { status = "failed"; return }
        frozen.captureFrozen = true; sample = frozen; revision += 1
        // Wait only for the final existing native render/geometry observations.
        for _ in 0..<10 {
            if let observedTime = CharacterPuppetCompletionRecorder.last["time"] as? Double,
               abs(observedTime - frozen.time) < 0.000001,
               CharacterPuppetCompletionRecorder.ready(policy: policy, frozen: true, completedInputs: sequence.count) != nil { break }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
        }
        guard let receipt = CharacterPuppetCompletionRecorder.ready(policy: policy, frozen: true, completedInputs: sequence.count),
              !CharacterPuppetCompletionRecorder.invalidSample,
              CharacterPuppetCompletionRecorder.write(receipt),
              let rendered = receipt["render"] as? [String: Any] else { status = "failed"; return }
        renderer = rendered["renderer"] as? String ?? ""
        activeSamples = String(CharacterPuppetCompletionRecorder.activeSamples)
        distinctVectors = String(CharacterPuppetCompletionRecorder.vectors.count)
        fps = String(Int(rendered["framesPerSecond"] as? Double ?? -1))
        face = String(rendered["face"] as? Int ?? -1)
        viseme = String(rendered["viseme"] as? Int ?? -1)
        status = "ready"
        if !CharacterPuppetCompletionAudit.uiDriven {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let acknowledgement = documents.appendingPathComponent(CharacterPuppetCompletionAudit.acknowledgementFilename)
            for _ in 0..<600 {
                guard !Task.isCancelled else { return }
                if (try? String(contentsOf: acknowledgement, encoding: .utf8)) == phase {
                    if index + 1 < count { index += 1 }
                    return
                }
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            }
            status = "failed"
        }
    }
}
#endif
