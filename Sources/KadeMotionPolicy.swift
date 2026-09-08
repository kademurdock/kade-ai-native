import SwiftUI
import Combine

/// Shared by decorative views. Low Power Mode must invalidate the view while
/// it is onscreen; reading ProcessInfo in body alone does not observe changes.
private final class KadePowerState: ObservableObject {
    @Published private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var observation: AnyCancellable?

    init() {
        observation = NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
    }
}

@propertyWrapper
struct KadeMotionPolicy: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("kade.feedback.reduceMotion") private var reduceMotion = false
    @StateObject private var power = KadePowerState()

    var wrappedValue: Bool {
        !systemReduceMotion && !reduceMotion && !voiceOver &&
            scenePhase == .active && !power.lowPower
    }
}

/// Respect either contrast preference without overriding the system's choice.
@propertyWrapper
struct KadeContrastPolicy: DynamicProperty {
    @Environment(\.colorSchemeContrast) private var systemContrast
    @AppStorage("kade.appearance.highContrast") private var appContrast = false

    var wrappedValue: Bool { appContrast || systemContrast == .increased }
}
