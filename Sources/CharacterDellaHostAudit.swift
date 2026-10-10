#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit

enum CharacterDellaHostAudit {
    enum Scenario: String, CaseIterable {
        case chatRoomy = "chat-roomy-light", chatPacked = "chat-packed-dark"
        case chatKeyboard = "chat-keyboard-dark", chatKeyboardScrolled = "chat-keyboard-scrolled-dark"
        case chatAccessibility = "chat-a11y-dark", chatAccessibilityScrolled = "chat-a11y-scrolled-dark"
        case chatOff = "chat-off-dark", chatSmall = "chat-small-light"
        case callRoomy = "call-roomy-light", callCaptions = "call-captions-dark"
        case callCaptionsScrolled = "call-captions-scrolled-dark"
        case callCamera = "call-camera-light", callCameraScrolled = "call-camera-scrolled-dark"
        case callAccessibility = "call-a11y-dark", callAccessibilityScrolled = "call-a11y-scrolled-dark"
        case callOffCamera = "call-off-camera-dark", callSmall = "call-small-light"

        var chat: Bool { rawValue.hasPrefix("chat-") }
        var dark: Bool { rawValue.hasSuffix("-dark") }
        var accessibility: Bool { rawValue.contains("a11y") }
        var scrolled: Bool { rawValue.contains("scrolled") }
        var camera: Bool { rawValue.contains("camera") }
        var candidate: Bool { !rawValue.contains("-off-") }
        var keyboard: Bool { [.chatKeyboard, .chatKeyboardScrolled].contains(self) }
        var packed: Bool { [.chatPacked, .chatKeyboard, .chatKeyboardScrolled,
                            .chatAccessibility, .chatAccessibilityScrolled, .chatOff].contains(self) }
        var longCaptions: Bool { [.callCaptions, .callCaptionsScrolled, .callAccessibility, .callAccessibilityScrolled].contains(self) }
    }

    static var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["KADE_CHARACTER_AUDIT"] == "1" && env["KADE_DELLA_HOST_AUDIT"] == "1" && KadeUITestMode.isAuditing
    }
    static var scenario: Scenario? {
        guard isEnabled else { return nil }
        return Scenario(rawValue: ProcessInfo.processInfo.environment["KADE_DELLA_HOST_CASE"] ?? "")
    }
    static func configure(_ scenario: Scenario) {
        UserDefaults.standard.set(scenario.candidate, forKey: CharacterDellaHostReview.defaultsKey)
        UserDefaults.standard.set(true, forKey: "kadeVoicePortraits")
        UserDefaults.standard.set(true, forKey: "kade.feedback.reduceMotion")
        UserDefaults.standard.set(false, forKey: "kade.chat.simpleComposer")
        UserDefaults.standard.set(false, forKey: "kade.chat.simpleTranscript")
    }
}

/// Real screen compositions with invented local data; their ordinary controls
/// and transcript/composer remain intact. No API request or media is started.
struct CharacterDellaHostAuditView: View {
    @EnvironmentObject private var client: KadeAPIClient
    private var scenario: CharacterDellaHostAudit.Scenario? { CharacterDellaHostAudit.scenario }

    var body: some View {
        Group {
            if let scenario {
                if scenario.chat {
                    NavigationStack {
                        ConversationDetailView(conversation: nil, initialAgentId: CharacterMotion.dellaID)
                    }
                } else {
                    CallView(agentId: CharacterMotion.dellaID, agentName: "Della", apiClient: client)
                }
            } else {
                Text("Invalid offline host fixture").accessibilityIdentifier("della-host.invalid")
            }
        }
        .preferredColorScheme(scenario?.dark == true ? .dark : .light)
        .environment(\.dynamicTypeSize, scenario?.accessibility == true ? .accessibility5 : .large)
    }
}

@MainActor
enum CharacterDellaHostAuditRecorder {
    static var geometry: [String: CGRect] = [:]
    static var stage: CharacterDellaHostStage?
    static var keyboardVisible = false
    static var composerEditing = false
    static var invitationPlacement = "none"

    static func record(_ key: String, frame: CGRect) {
        guard CharacterDellaHostAudit.isEnabled, frame.origin.x.isFinite,
              frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite else { return }
        geometry[key] = frame
    }

    static func ready() async {
        guard let scenario = CharacterDellaHostAudit.scenario else { return }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled, let stage else { return }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        guard let window else { return }
        geometry["window"] = window.bounds
        let rects = geometry.mapValues { rect in
            [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
        }
        let visible = geometry["stage"].map { $0.intersects(geometry["viewport"] ?? window.bounds) } ?? false
        let measuredHeight = geometry["stage"]?.height ?? 0
        let validFrame = abs(Double(measuredHeight) - stage.frameHeight) <= 1
        let stageData: [String: Any] = ["side": stage.side, "portraitHeight": stage.portraitHeight,
            "frameHeight": stage.frameHeight, "articulated": stage.articulated]
        let data: [String: Any] = [
            "schema": "kade.della-host-ready.v1", "phase": scenario.rawValue,
            "host": scenario.chat ? "chat" : "call", "actualHost": scenario.chat ? "ConversationDetailView" : "CallView",
            "windowPoints": [Double(window.bounds.width), Double(window.bounds.height)],
            "orientation": window.bounds.width <= window.bounds.height ? "portrait" : "landscape",
            "appearance": window.traitCollection.userInterfaceStyle == .dark ? "dark" : "light",
            "stage": stageData,
            "hostFrameMatchesPortrait": validFrame, "geometry": rects,
            "viewportIntersectsStage": visible, "keyboardVisible": keyboardVisible,
            "composerEditing": composerEditing, "invitationPlacement": invitationPlacement,
            "candidateEnabled": scenario.candidate,
            "dynamicTypeAccessibility": scenario.accessibility, "scrolled": scenario.scrolled,
            "agentID": CharacterMotion.dellaID, "sourceAvatarPath": "/images/" + CharacterMotion.dellaFile,
            "resourceComplete": CharacterDellaArticulatedGeometry.requiredAssets.allSatisfy { UIImage(named: $0) != nil },
            "audioStarted": false, "microphoneStarted": false, "cameraStarted": false, "networkStarted": false,
            "networkRequestsBlocked": true, "blockedRequestCount": KadeAPIClient.hostAuditBlockedRequestCount,
            "physicalPhoneVerified": false, "voiceOverVerified": false, "batteryMeasured": false,
            "motionPausedForLayoutAudit": true
        ]
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) {
            try? json.write(to: folder.appendingPathComponent("della-host-ready.json"), options: .atomic)
        }
    }
}
#endif
