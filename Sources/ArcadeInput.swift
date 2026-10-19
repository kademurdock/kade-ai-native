import Foundation
import GameController

/// Controllers and hardware keyboards, read natively with GameController while
/// a game is open, so they work wherever VoiceOver focus is (the web page's
/// own Gamepad API needs the web view to be first responder, which a blind
/// player's focus moves would keep breaking).
///
/// - A controller is mapped with the game's own table (profile.input.gamepad,
///   ArcadeGamepadMapper) and sent to the page as ONE pad source,
///   'controller', only when something changed. Info buttons fire on press.
/// - A keyboard sends the browser's key names to revivalKit.press, down and
///   up, so the game's keyboard map and its spoken key names apply unchanged.
///   Escape asks "Leave game?"; Control, Option and Command combinations stay
///   with VoiceOver.
@MainActor
final class ArcadeInput {
    var onPad: (@MainActor (ArcadePadState?) -> Void)?
    var onInfo: (@MainActor (String) -> Void)?
    var onKey: (@MainActor (String, Bool) -> Void)?
    var onEscape: (@MainActor () -> Void)?
    var onAnnounce: (@MainActor (String) -> Void)?
    /// The kit's mode ('menu', 'fight', 'pause'): the controller map follows it.
    var mode = "menu" {
        didSet { if mode != oldValue { readController() } }
    }

    /// What she most likely plays with right now, for the words the page uses
    /// for buttons before her first press: a controller, else a keyboard, else touch.
    static func connectedType() -> String {
        if GCController.controllers().contains(where: { $0.extendedGamepad != nil }) { return "gamepad" }
        if GCKeyboard.coalesced != nil { return "keyboard" }
        return "touch"
    }

    private var mapper = ArcadeGamepadMapper()
    private var observers: [NSObjectProtocol] = []
    private var controller: GCController?
    private var keyboard: GCKeyboard?
    private var lastPad: String?
    private var modifiersHeld = Set<Int>()
    private var keysDown = Set<String>()
    private var running = false

    func start(map: ArcadeGamepadMap) {
        guard !running else { return }
        running = true
        mapper = ArcadeGamepadMapper(map: map)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pickController(announce: true) }
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pickController(announce: true) }
            },
            center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pickKeyboard() }
            },
            center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pickKeyboard() }
            },
        ]
        pickController(announce: false)
        pickKeyboard()
    }

    func stop() {
        guard running else { return }
        releaseAll()
        running = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = nil
        keyboard?.keyboardInput?.keyChangedHandler = nil
        keyboard = nil
    }

    /// Lets go of every key and the controller (the app went to the background).
    func releaseAll() {
        for key in keysDown { onKey?(key, false) }
        keysDown.removeAll()
        modifiersHeld.removeAll()
        sendPad(nil)
    }

    // MARK: Controllers

    private func pickController(announce: Bool) {
        guard running else { return }
        let next = GCController.controllers().first { $0.extendedGamepad != nil }
        if let next, let current = controller, next === current { return }
        let had = controller != nil
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = next
        if let pad = next?.extendedGamepad {
            pad.valueChangedHandler = { [weak self] _, _ in
                Task { @MainActor in self?.readController() }
            }
            if announce { onAnnounce?("Controller connected: \(next?.vendorName ?? "a game controller").") }
        } else if had {
            sendPad(nil)
            if announce { onAnnounce?("The controller disconnected.") }
        }
        readController()
    }

    private func readController() {
        guard running, let pad = controller?.extendedGamepad else { return }
        // The standard gamepad order the kit's profiles use.
        let buttons: [GCControllerButtonInput?] = [
            pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY,
            pad.leftShoulder, pad.rightShoulder, pad.leftTrigger, pad.rightTrigger,
            pad.buttonOptions, pad.buttonMenu, pad.leftThumbstickButton, pad.rightThumbstickButton,
            pad.dpad.up, pad.dpad.down, pad.dpad.left, pad.dpad.right, pad.buttonHome,
        ]
        var snapshot = ArcadeGamepadSnapshot()
        for (index, button) in buttons.enumerated() where index < snapshot.pressed.count {
            snapshot.pressed[index] = button?.isPressed ?? false
        }
        // GameController's y is up; the kit's is down.
        snapshot.axes = [
            Double(pad.leftThumbstick.xAxis.value), Double(-pad.leftThumbstick.yAxis.value),
            Double(pad.rightThumbstick.xAxis.value), Double(-pad.rightThumbstick.yAxis.value),
        ]
        let reading = mapper.apply(snapshot, mode: mode)
        for what in reading.info { onInfo?(what) }
        sendPad(reading.state.isEmpty ? nil : reading.state)
    }

    private func sendPad(_ state: ArcadePadState?) {
        let encoded = state.map { ArcadeJS.padObject($0) } ?? "null"
        guard encoded != lastPad else { return }
        lastPad = encoded
        onPad?(state)
    }

    // MARK: Keyboards

    private func pickKeyboard() {
        guard running else { return }
        keyboard?.keyboardInput?.keyChangedHandler = nil
        keyboard = GCKeyboard.coalesced
        keyboard?.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            let usage = Int(keyCode.rawValue)
            Task { @MainActor in self?.key(usage: usage, pressed: pressed) }
        }
    }

    private func key(usage: Int, pressed: Bool) {
        guard running else { return }
        if (0xE0...0xE7).contains(usage) {
            if pressed { modifiersHeld.insert(usage) } else { modifiersHeld.remove(usage) }
            return
        }
        if usage == ArcadeKeys.escapeUsage {
            if pressed { onEscape?() }
            return
        }
        guard let name = ArcadeKeys.browserKey(hidUsage: usage) else { return }
        if pressed {
            guard !modifiersHeld.contains(where: { ArcadeKeys.isBlockingModifier(hidUsage: $0) }) else { return }
            keysDown.insert(name)
            onKey?(name, true)
        } else if keysDown.remove(name) != nil {
            onKey?(name, false)
        }
    }
}
