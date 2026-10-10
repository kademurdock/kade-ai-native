import SwiftUI
import Combine

/// Shared by decorative views. Power and thermal changes must invalidate the
/// view while it is onscreen; a one-off ProcessInfo read does not observe them.
private final class KadePowerState: ObservableObject {
    @Published private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var thermal = KadePowerState.pressure(ProcessInfo.processInfo.thermalState)
    private var observations = Set<AnyCancellable>()

    init() {
        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.thermal = Self.pressure(ProcessInfo.processInfo.thermalState)
            }
            .store(in: &observations)
    }

    private static func pressure(_ state: ProcessInfo.ThermalState) -> CharacterThermalPressure {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .critical
        }
    }
}

@propertyWrapper
struct KadeMotionPolicy: DynamicProperty {
    var permitsVoiceOver = false
    init(permitsVoiceOver: Bool = false) { self.permitsVoiceOver = permitsVoiceOver }
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("kade.feedback.reduceMotion") private var reduceMotion = false
    @StateObject private var power = KadePowerState()

    var wrappedValue: Bool {
        !systemReduceMotion && !reduceMotion && (permitsVoiceOver || !voiceOver) &&
            scenePhase == .active && !power.lowPower && power.thermal.permitsAnimation
    }

    /// The portrait's single clock can slow at fair pressure before stopping
    /// entirely at serious pressure. Other decorations keep the Boolean gate.
    var projectedValue: CharacterThermalPressure { power.thermal }
}

/// Respect either contrast preference without overriding the system's choice.
@propertyWrapper
struct KadeContrastPolicy: DynamicProperty {
    @Environment(\.colorSchemeContrast) private var systemContrast
    @AppStorage("kade.appearance.highContrast") private var appContrast = false

    var wrappedValue: Bool { appContrast || systemContrast == .increased }
}
