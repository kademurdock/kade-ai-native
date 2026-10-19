import SwiftUI
import UIKit
import QuartzCore

/// THE GAME PAD (Oct 18 2026). Everything below the Arcade's top strip is this
/// one view. With VoiceOver on it is one element, "Game pad", and a VoiceOver
/// direct touch area (iOS 17's UIAccessibility.DirectTouchOptions):
/// requiresActivation, so a double-tap takes hold of it first, and
/// silentOnTouch, so from then on every touch goes straight to the game with
/// VoiceOver quiet (never reading the pad's label over the game), until focus
/// moves to the strip. With VoiceOver off the pad simply takes touches. While
/// it has VoiceOver focus but is not held, the escape scrub asks "Leave
/// game?" and the magic tap pauses, the same as on the strip.
///
/// The gestures are the game's own tables (profile.input.touch), run by
/// ArcadeTouchRecognizer, the rules of the kit's core/touch.js:
///   menus  flick = one step; double-tap = A; two-finger tap = B;
///          two-finger double-tap = Start; three-finger flick = C buttons
///   fights left half = a floating stick (tap: change target; two-finger
///          flicks: health, where, facing, time); right half = flick attacks,
///          tap jumps, hold blocks, two-finger tap B, two-finger hold crouch;
///          three-finger tap anywhere pauses. The two halves work side by
///          side: the left thumb walks while the right one attacks or blocks.
///   plain  (Oct 19 2026, a game added with no accessibility pack) the kit's
///          per-system table: left half a floating control pad, two-finger
///          tap Select; named zones on the right held as buttons (A above
///          B, the shoulders along the top on the Game Boy Advance);
///          three-finger tap Start. The pad's hint is the kit's own help.
///
/// Haptics are made when the game opens, never at app launch (the CI
/// simulator has no haptic or audio hardware): a light tick per stick
/// direction, a firm one at full push, one when a hold takes effect, and a
/// soft one when the game switches between menus and fights.
final class ArcadeTouchPadView: UIView {
    /// Pad states, info keys: for the page. Called on the main thread.
    var onOutputs: (@MainActor ([ArcadeTouchOutput]) -> Void)?
    /// The first touch since the page (re)loaded (the page may need a gesture for sound).
    var onFirstTouch: (@MainActor () -> Void)?
    /// VoiceOver's escape scrub and magic tap while the pad has focus.
    var onEscape: (@MainActor () -> Void)?
    var onMagicTap: (@MainActor () -> Void)?

    private var recognizer = ArcadeTouchRecognizer()
    private var link: CADisplayLink?
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextId = 1
    private var touchedOnce = false
    private var mode = "menu"
    /// Oct 19 2026: the controls the game's own help describes for play (the
    /// plain player's per-system touch help), said in place of the fighting
    /// game's words.
    private var playHint: String?
    private let lightTick = UIImpactFeedbackGenerator(style: .light)
    private let firmTick = UIImpactFeedbackGenerator(style: .rigid)
    private let softTick = UISelectionFeedbackGenerator()
    var hapticsOn = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = "Game pad"
        // A direct touch area that VoiceOver lets go of only after a
        // double-tap, and stays silent in (iOS 17, the app's deployment target).
        accessibilityTraits = .allowsDirectInteraction
        accessibilityDirectTouchOptions = [.silentOnTouch, .requiresActivation]
        lightTick.prepare()
        firmTick.prepare()
        softTick.prepare()
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("ArcadeTouchPadView is made in code") }

    // MARK: The game's side

    func setTable(_ table: ArcadeTouchTable) {
        emit(recognizer.releaseAll())
        recognizer = ArcadeTouchRecognizer(table: table)
        recognizer.mode = mode
    }

    /// The words for play, when the game's own help has them.
    func setPlayHint(_ hint: String?) {
        playHint = hint
        updateAccessibility()
    }

    /// 'menu', 'fight' or 'pause' from the kit's mode event.
    func setMode(_ newMode: String) {
        guard newMode != mode else { return }
        mode = newMode
        recognizer.mode = newMode
        if hapticsOn { softTick.selectionChanged() }
        updateAccessibility()
    }

    /// Lets go of every held stick and button (pause, leave, background).
    func releaseAll() {
        emit(recognizer.releaseAll())
        ids.removeAll()
        stopLink()
    }

    /// The page was (re)loaded: its sound may need waking again on the next touch.
    func resetFirstTouch() {
        touchedOnce = false
    }

    // MARK: VoiceOver

    private func updateAccessibility() {
        let fight = playHint ?? "Left half moves, right half acts."
        accessibilityHint = "Double-tap to take hold of the pad; then touches go straight to the game. "
            + (mode == "fight" ? fight : "Flick to move, double-tap to choose, two-finger tap to go back.")
            + " Touch the strip at the top to get VoiceOver back."
        accessibilityValue = mode == "fight" ? "Fight" : (mode == "pause" ? "Paused" : "Menu")
    }

    /// Focus moved to the strip (or anywhere else): nothing stays held down.
    override func accessibilityElementDidLoseFocus() {
        super.accessibilityElementDidLoseFocus()
        releaseAll()
    }

    /// The escape scrub on the pad (focused, not held): the strip's question, "Leave game?".
    override func accessibilityPerformEscape() -> Bool {
        guard let onEscape else { return false }
        onEscape()
        return true
    }

    /// The magic tap on the pad: pause, as on the strip.
    override func accessibilityPerformMagicTap() -> Bool {
        guard let onMagicTap else { return false }
        onMagicTap()
        return true
    }

    // MARK: Touches

    private func now() -> Double { CACurrentMediaTime() * 1000 }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !touchedOnce {
            touchedOnce = true
            onFirstTouch?()
        }
        let width = Double(bounds.width)
        let height = Double(bounds.height)
        for touch in touches {
            let id = nextId
            nextId += 1
            ids[ObjectIdentifier(touch)] = id
            let point = touch.location(in: self)
            emit(recognizer.start(id: id, x: Double(point.x), y: Double(point.y), width: width, height: height, now: now()))
        }
        startLink()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = ids[ObjectIdentifier(touch)] else { continue }
            let point = touch.location(in: self)
            emit(recognizer.move(id: id, x: Double(point.x), y: Double(point.y), now: now()))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let id = ids.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            emit(recognizer.end(id: id, now: now()))
        }
        startLink()
    }

    // MARK: The clock (holds, repeats, releases, single taps)

    private func startLink() {
        guard link == nil, !recognizer.isIdle else { return }
        let display = CADisplayLink(target: ArcadeLinkTarget(self), selector: #selector(ArcadeLinkTarget.tick))
        display.add(to: .main, forMode: .common)
        link = display
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick() {
        emit(recognizer.advance(to: now()))
        if recognizer.isIdle { stopLink() }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { releaseAll() }
    }

    private func emit(_ outputs: [ArcadeTouchOutput]) {
        guard !outputs.isEmpty else { return }
        var forPage: [ArcadeTouchOutput] = []
        for output in outputs {
            if case .haptic(let cue) = output {
                guard hapticsOn else { continue }
                switch cue {
                case .direction: lightTick.impactOccurred(intensity: 0.6)
                case .fullPush: firmTick.impactOccurred()
                case .hold: firmTick.impactOccurred(intensity: 0.7)
                }
            } else {
                forPage.append(output)
            }
        }
        if !forPage.isEmpty { onOutputs?(forPage) }
    }
}

/// CADisplayLink keeps its target strongly; this keeps the pad collectable.
@MainActor
private final class ArcadeLinkTarget: NSObject {
    weak var pad: ArcadeTouchPadView?
    init(_ pad: ArcadeTouchPadView) { self.pad = pad }
    @objc func tick() { pad?.tick() }
}

/// The pad inside SwiftUI. The host owns the game; the pad only reports touches.
struct ArcadeTouchPadSurface: UIViewRepresentable {
    let host: ArcadeGameHost

    func makeUIView(context: Context) -> ArcadeTouchPadView {
        let pad = ArcadeTouchPadView(frame: .zero)
        host.attach(pad: pad)
        return pad
    }

    func updateUIView(_ pad: ArcadeTouchPadView, context: Context) {}
}
