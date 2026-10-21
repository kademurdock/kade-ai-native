import SwiftUI
import UIKit
import QuartzCore
import AVFoundation

/// THE GAME PAD (Oct 18 2026; touch v2 Oct 20 2026). Everything below the
/// Arcade's top strip is this one view. With VoiceOver on it is one element,
/// "Game pad", hint "Double-tap to play.", value Menu, Fight, Paused or Demo,
/// and a VoiceOver direct touch area (iOS 17's
/// UIAccessibility.DirectTouchOptions): requiresActivation, so a double-tap
/// takes hold of it first (Settings, Pad takes hold: At once drops that), and
/// silentOnTouch, so from then on every touch goes straight to the game with
/// VoiceOver quiet, until focus moves to the strip. With VoiceOver off the
/// pad simply takes touches.
///
/// Held or not (ArcadePadHold): iOS says nothing when the pad is taken, so
/// the pad does. VoiceOver's activate (if iOS calls it on the activating
/// double-tap) or else the first touch that reaches the pad takes it: a
/// rising chime and a success buzz, and the first touch is played as a
/// normal gesture. Focus leaving the pad: a falling chime, the kit's voice
/// held, and a live fight pauses itself. While it has focus but is not held,
/// the escape scrub is Back in menus and pause in fights, and the magic tap
/// is Start (Leave game is only on the strip).
///
/// The gestures are the game's own tables (profile.input.touch), run by
/// ArcadeTouchRecognizer, the kit's core/touch.js v2: in menus VoiceOver's
/// own grammar (flick, tap to hear it, double-tap to choose, two-finger
/// scrub back, two-finger tap quiet, two-finger double-tap Start); in
/// fights the tier in use (Easy: the whole pad one zone; Full: the two
/// halves); the plain player's per-system zones (Oct 19 2026).
///
/// Every gesture acted on gets a haptic by its action and every touch that
/// did nothing a warning buzz (ArcadeFeel); the kit's game cues (a foe's
/// wind-up, a hit, a block) buzz too. Haptics and chimes are made when the
/// game opens, never at app launch (the CI simulator has no haptic or audio
/// hardware), and follow the Pad haptics and Pad chimes switches.
final class ArcadeTouchPadView: UIView {
    /// Pad states, info keys and the v2 reports: for the page (or Pad practice). Called on the main thread.
    var onOutputs: (@MainActor ([ArcadeTouchOutput]) -> Void)?
    /// The first touch since the page (re)loaded (the page may need a gesture for sound).
    var onFirstTouch: (@MainActor () -> Void)?
    /// VoiceOver's escape scrub and magic tap while the pad has focus.
    var onEscape: (@MainActor () -> Void)?
    var onMagicTap: (@MainActor () -> Void)?
    /// The held state's effects for the host: lines, the kit's voice held or
    /// let go, the game's pause (the chimes and the buzz are the pad's own).
    var onHold: (@MainActor ([ArcadePadEffect]) -> Void)?
    /// The pad taken (true) or let go, and how, for the report.
    var onPadLog: (@MainActor (Bool, String) -> Void)?
    /// VoiceOver called the pad's activate (for the report).
    var onActivate: (@MainActor () -> Void)?

    private var recognizer = ArcadeTouchRecognizer()
    private var link: CADisplayLink?
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextId = 1
    private var touchedOnce = false
    private(set) var mode = "menu"
    private(set) var hold = ArcadePadHold()
    /// When a touch last reached the pad (ms on the pad's clock), for the watchdog.
    private(set) var lastTouch: Double?
    /// When VoiceOver last called the pad's activate (ms on the pad's clock).
    private var lastActivate: Double?
    private let selectionTick = UISelectionFeedbackGenerator()
    private let lightTick = UIImpactFeedbackGenerator(style: .light)
    private let mediumTick = UIImpactFeedbackGenerator(style: .medium)
    private let heavyTick = UIImpactFeedbackGenerator(style: .heavy)
    private let rigidTick = UIImpactFeedbackGenerator(style: .rigid)
    private let softTick = UIImpactFeedbackGenerator(style: .soft)
    private let notice = UINotificationFeedbackGenerator()
    private let risingChime: AVAudioPlayer?
    private let fallingChime: AVAudioPlayer?
    var hapticsOn = true
    var chimesOn = true
    /// Pause when I leave the pad (Settings): a live fight pauses as focus leaves.
    var pauseOnLeave = true
    /// Pad takes hold: At once (no double-tap first).
    var takesHoldAtOnce = false {
        didSet { if takesHoldAtOnce != oldValue { updateDirectTouch() } }
    }

    override init(frame: CGRect) {
        risingChime = try? AVAudioPlayer(data: ArcadeChime.wav(rising: true))
        fallingChime = try? AVAudioPlayer(data: ArcadeChime.wav(rising: false))
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = ArcadePadWords.label
        accessibilityHint = ArcadePadWords.hint
        // A direct touch area that VoiceOver lets go of only after a
        // double-tap, and stays silent in (iOS 17, the app's deployment target).
        accessibilityTraits = .allowsDirectInteraction
        updateDirectTouch()
        for generator in [lightTick, mediumTick, heavyTick, rigidTick, softTick] { generator.prepare() }
        selectionTick.prepare()
        notice.prepare()
        risingChime?.prepareToPlay()
        fallingChime?.prepareToPlay()
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("ArcadeTouchPadView is made in code") }

    // MARK: The game's side

    func setTable(_ table: ArcadeTouchTable) {
        emit(recognizer.releaseAll())
        let fit = recognizer.fit
        recognizer = ArcadeTouchRecognizer(table: table)
        recognizer.mode = mode
        recognizer.fit = fit
    }

    /// Her touch timing over the table's numbers (nil: Relaxed, the table's own).
    func setFit(_ fit: ArcadeTouchFit?) {
        recognizer.fit = fit
    }

    /// 'menu', 'fight', 'pause' or 'demo' from the kit's mode event.
    func setMode(_ newMode: String) {
        guard newMode != mode else { return }
        mode = newMode
        recognizer.mode = newMode
        // A fight that paused itself as she left is remembered only while the
        // game is on its pause screen: resumed some other way, or left for a
        // menu or a demo, there is nothing to say on return.
        hold.setMode(newMode)
        play([ArcadeBuzz(style: .soft, intensity: 0.5)])
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

    /// Oct 21 2026: whether the page's kit has the one speech queue (the
    /// host asks it at 'ready'): the paused line on her return depends on it.
    func setKitQueue(_ on: Bool) {
        hold.kitQueue = on
    }

    /// Oct 21 2026: the kit's one queue was cleared (an answer queued, or its
    /// quiet): a pause read it held while she was away went with it.
    func kitQueueCleared() {
        hold.kitQueueCleared()
    }

    /// The kit's game cue ('telegraph', 'hurt', 'landed', 'blocked', 'reach', 'ko').
    func feel(cue kind: String) {
        play(ArcadeFeel.cue(kind))
    }

    /// Haptics, if Pad haptics is on; later ones after their delay.
    func play(_ buzzes: [ArcadeBuzz]) {
        guard hapticsOn else { return }
        for buzz in buzzes {
            if buzz.afterMs > 0 {
                let wait = UInt64(buzz.afterMs * 1_000_000)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: wait)
                    self?.buzzNow(buzz)
                }
            } else {
                buzzNow(buzz)
            }
        }
    }

    private func buzzNow(_ buzz: ArcadeBuzz) {
        guard hapticsOn else { return }
        let strength = CGFloat(max(0, min(1, buzz.intensity)))
        switch buzz.style {
        case .selection: selectionTick.selectionChanged()
        case .light: lightTick.impactOccurred(intensity: strength)
        case .medium: mediumTick.impactOccurred(intensity: strength)
        case .heavy: heavyTick.impactOccurred(intensity: strength)
        case .rigid: rigidTick.impactOccurred(intensity: strength)
        case .soft: softTick.impactOccurred(intensity: strength)
        case .success: notice.notificationOccurred(.success)
        case .warning: notice.notificationOccurred(.warning)
        }
    }

    private func chime(rising: Bool) {
        guard chimesOn, let player = rising ? risingChime : fallingChime else { return }
        player.currentTime = 0
        player.play()
    }

    // MARK: VoiceOver

    private func updateDirectTouch() {
        accessibilityDirectTouchOptions = takesHoldAtOnce ? [.silentOnTouch] : [.silentOnTouch, .requiresActivation]
    }

    private func updateAccessibility() {
        accessibilityValue = ArcadePadWords.value(mode: mode)
    }

    /// The held state's effects: chimes and the buzz here, the rest for the host.
    private func apply(_ effects: [ArcadePadEffect]) {
        var forHost: [ArcadePadEffect] = []
        for effect in effects {
            switch effect {
            case .risingChime: chime(rising: true)
            case .fallingChime: chime(rising: false)
            case .takenBuzz: play(ArcadeFeel.taken)
            default: forHost.append(effect)
            }
        }
        if !forHost.isEmpty { onHold?(forHost) }
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        apply(hold.focus(now: now()))
    }

    /// Focus moved to the strip (or anywhere else): nothing stays held down,
    /// a falling chime if the pad was held, the kit's voice waits, and a live fight pauses.
    override func accessibilityElementDidLoseFocus() {
        super.accessibilityElementDidLoseFocus()
        releaseAll()
        let wasHeld = hold.held
        apply(hold.lostFocus(now: now(), mode: mode, pauseOnLeave: pauseOnLeave))
        if wasHeld { onPadLog?(false, "VoiceOver back") }
    }

    /// VoiceOver's activate on the pad: logged, and if iOS calls it on the
    /// activating double-tap, the pad is taken here. It returns false, so
    /// VoiceOver goes on as it would.
    override func accessibilityActivate() -> Bool {
        onActivate?()
        lastActivate = now()
        let wasHeld = hold.held
        apply(hold.activate(now: now()))
        if !wasHeld && hold.held { onPadLog?(true, "activate") }
        return false
    }

    /// The escape scrub on the pad (focused, not held): Back in menus, pause in fights.
    override func accessibilityPerformEscape() -> Bool {
        guard let onEscape else { return false }
        onEscape()
        return true
    }

    /// The magic tap on the pad: Start (pause in fights).
    override func accessibilityPerformMagicTap() -> Bool {
        guard let onMagicTap else { return false }
        onMagicTap()
        return true
    }

    // MARK: Touches

    private func now() -> Double { CACurrentMediaTime() * 1000 }

    /// Now on the pad's clock (the watchdog compares it with lastTouch).
    var clock: Double { now() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let t = now()
        // VoiceOver's own tap after its activate (at the activation point, the
        // pad's middle) is not hers: not played, and not a touch reaching the
        // pad, so two activates with nothing between still mean Direct Touch is off.
        if let activated = lastActivate, touches.count == 1, let touch = touches.first {
            let point = touch.location(in: self)
            let dx = Double(point.x - bounds.midX)
            let dy = Double(point.y - bounds.midY)
            let fingers = event?.allTouches?.count ?? 1
            if ArcadePadHold.isVoiceOverTap(sinceActivateMs: t - activated, fingers: fingers, offset: (dx * dx + dy * dy).squareRoot()) {
                lastActivate = nil
                return
            }
        }
        lastTouch = t
        if !touchedOnce {
            touchedOnce = true
            onFirstTouch?()
        }
        // The first touch after focus takes the pad, and is still played.
        let wasHeld = hold.held
        apply(hold.touch(now: t, voiceOver: UIAccessibility.isVoiceOverRunning))
        if !wasHeld && hold.held { onPadLog?(true, "first touch") }
        let width = Double(bounds.width)
        let height = Double(bounds.height)
        for touch in touches {
            let id = nextId
            nextId += 1
            ids[ObjectIdentifier(touch)] = id
            let point = touch.location(in: self)
            // Oct 21 2026: every job due by now runs first (touchBegan), as in the kit.
            emit(recognizer.touchBegan(id: id, x: Double(point.x), y: Double(point.y), width: width, height: height, now: t))
        }
        startLink()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let t = now()
        for touch in touches {
            guard let id = ids[ObjectIdentifier(touch)] else { continue }
            lastTouch = t
            let point = touch.location(in: self)
            emit(recognizer.touchMoved(id: id, x: Double(point.x), y: Double(point.y), now: t))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        let t = now()
        for touch in touches {
            guard let id = ids.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            lastTouch = t
            // A hold due a moment before the lift is a block (or a repeat), never a slow tap.
            emit(recognizer.touchEnded(id: id, now: t))
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

    /// Haptics for the stick, every gesture by its action and every dud;
    /// everything but the stick's own cues goes on (the reports too).
    private func emit(_ outputs: [ArcadeTouchOutput]) {
        guard !outputs.isEmpty else { return }
        var forPage: [ArcadeTouchOutput] = []
        for output in outputs {
            switch output {
            case .haptic(let cue):
                switch cue {
                case .direction: play([ArcadeBuzz(style: .light, intensity: 0.6)])
                case .fullPush: play([ArcadeBuzz(style: .rigid)])
                case .hold: break   // the hold's own gesture report buzzes
                }
            case .gesture(let report):
                play(ArcadeFeel.of(report))
                forPage.append(output)
            case .dud:
                play(ArcadeFeel.dud)
                forPage.append(output)
            default:
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
