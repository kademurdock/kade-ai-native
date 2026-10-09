import SwiftUI
import UIKit

/// The actual conversation stage, shared with its offline layout fixture.
/// Transcript, composer and accessible conversation controls stay outside it.
struct CharacterConversationStage: View {
    let agentID: String?
    let name: String
    let playing: Bool
    let side: Double
    let level: () -> Double
    let presentation: () -> CharacterPresentation

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            CharacterPortraitView(agentID: agentID, name: name, playing: playing,
                level: level, presentation: presentation, stage: true, side: side)
            Spacer(minLength: 0)
        }
        .frame(height: side + 40)
        .background(StageMoodLight(mood: StageMood(presentation())))
        .background(Color(.systemBackground))
        .accessibilityHidden(true)
    }
}
