import SwiftUI
import UIKit

/// One opt-in decision for the host's reserved height and its portrait.
/// The review resource and controls exist only in unsigned simulator builds.
enum CharacterDellaHostReview {
    static let defaultsKey = "kade.della.articulatedReview"

    static func available(enabled: Bool, agentID: String?, avatarPath: String?) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
        return CharacterDellaArticulatedGeometry.eligible(enabled: enabled, stage: true,
            side: 208, agentID: agentID, avatarPath: avatarPath,
            resourcesPresent: CharacterDellaArticulatedGeometry.requiredAssets.allSatisfy { UIImage(named: $0) != nil })
        #else
        return false
        #endif
    }
}

extension View {
    /// Discrete layout observations for the local host fixture. This neither
    /// measures ideal sizes nor publishes state back into the composer.
    /// Parent probes stay geometry-only so native controls keep their own IDs.
    @ViewBuilder
    @MainActor
    func dellaHostProbe(_ key: String, identifier: String? = nil) -> some View {
        #if DEBUG && targetEnvironment(simulator)
        if CharacterDellaHostAudit.isEnabled {
            let observed = self.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                CharacterDellaHostAuditRecorder.record(key, frame: $0)
            }
            if let identifier {
                observed.accessibilityIdentifier(identifier)
            } else {
                observed
            }
        } else { self }
        #else
        self
        #endif
    }
}
