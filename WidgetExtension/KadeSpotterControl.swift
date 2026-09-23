import AppIntents
import SwiftUI
import WidgetKit

/// Sep 23 2026 redesign (C7): "Call your Spotter" as an iOS 18 control, for
/// Control Center, the Lock Screen's two bottom buttons, or the Action
/// button. More about access than looks: the Action button is one press from
/// a locked phone in a pocket, with no screen to find at all.
///
/// VoiceOver reads the label, "Call your Spotter". The control has no state
/// to report, so it is a button, not a toggle.
@available(iOS 18.0, *)
struct KadeSpotterControl: ControlWidget {
    static let kind: String = "com.kademurdock.kadeai.widgets.spotter"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenSpotterIntent()) {
                Label("Call your Spotter", systemImage: "eye")
            }
        }
        .displayName("Call your Spotter")
        .description("Opens Kade-AI and calls your Spotter, who looks through your camera and tells you what's around you.")
    }
}
