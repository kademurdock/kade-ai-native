import SwiftUI
import WidgetKit

/// Sep 23 2026 redesign: everything the Kade-AI widget extension shows.
///
/// - C2 `KadeCharacterWidget`: "Talk to your character" on the home screen and
///   Lock Screen.
/// - C3 `KadeJobLiveActivity`: the lock-screen and Dynamic Island card for
///   long jobs the app starts with `KadeJobActivity`.
/// - C7 `KadeSpotterControl`: "Call your Spotter" for Control Center, the
///   Lock Screen and the Action button, iOS 18 and later only.
///
/// The control is added with `if #available`, the one condition a widget
/// bundle accepts: WidgetBundleBuilder's `buildOptional` only takes what
/// `buildLimitedAvailability` returns, and Apple ships that for widgets
/// (iOS 16.1) and for controls (iOS 18). A plain `if` would not compile here.
@main
struct KadeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        KadeCharacterWidget()
        KadeJobLiveActivity()
        if #available(iOS 18.0, *) {
            KadeSpotterControl()
        }
    }
}
