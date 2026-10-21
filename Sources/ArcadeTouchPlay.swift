import Foundation

// MARK: - TOUCH PLAY (Oct 20 2026), the pure half
//
// Kade's second test of the game pad on the phone speaker: she could not
// tell whether the pad was held, her deliberate taps (300-450 ms) became
// blocks or nothing, two voices talked at once, and a game that moves on by
// itself named gestures that did nothing. The plan she approved ("Yes, build
// the touch controls this way") changes the app like this:
//   - the pad says only "Game pad. Double-tap to play." and its state (Menu,
//     Fight, Paused, Demo); a rising chime and a buzz when it is taken, a
//     falling chime when VoiceOver comes back, and a fight pauses itself then;
//   - every gesture the recognizer acts on gets a haptic, and a touch that
//     did nothing a warning buzz and a reason (ArcadeFeel);
//   - her touch timing: Relaxed by default, Quick (the old quarter-second
//     values) or Fitted to me from Pad practice (ArcadeTouchFit);
//   - one voice at a time: the kit's lines with no clip come here one by one
//     and are acknowledged when said (ArcadeSpeechQueue);
//   - Pad practice, a native screen with no game running (ArcadePadPractice),
//     and How to play built from the table's own words (ArcadeHowToPlay);
//   - the trace for "How the game ran" (ArcadeTouchLog).
// Everything here is plain Foundation, checked by run-arcade-tests.sh.

// MARK: - Her touch timing

/// Touch timing over a table's numbers: menus get the tap time, double-tap
/// gap, slop and flick; a fight tier of the Easy shape (a tap is anything
/// lifted before the rest, the slop is the flick) gets the rest for both and
/// the flick for both (ArcadeTouchNumbers.fitted).
struct ArcadeTouchFit: Equatable, Codable {
    var tapMs: Double
    var doubleMs: Double
    var slopPx: Double
    var flickPx: Double
    var restMs: Double

    /// The tables' own numbers since Oct 20 2026 (the default).
    static let relaxed = ArcadeTouchFit(tapMs: 450, doubleMs: 400, slopPx: 24, flickPx: 28, restMs: 500)
    /// The Oct 18 values: tap 250 ms, double 300 ms, hold 250 ms, slop 12, flick 20.
    static let quick = ArcadeTouchFit(tapMs: 250, doubleMs: 300, slopPx: 12, flickPx: 20, restMs: 250)

    static let tapBounds: ClosedRange<Double> = 400...650
    static let slopBounds: ClosedRange<Double> = 16...32
    static let flickBounds: ClosedRange<Double> = 20...40
    static let doubleBounds: ClosedRange<Double> = 350...650
    static let restBounds: ClosedRange<Double> = 450...900
    /// Fewer samples than this keep the relaxed value for that item.
    static let minimumSamples = 5

    static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// The nearest-rank percentile (p from 0 to 100); nil with no values.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        let sorted = values.filter { $0.isFinite }.sorted()
        guard !sorted.isEmpty else { return nil }
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    /// Fitted to her, from Pad practice:
    ///   tap cap = p90 of her tap durations x 1.3 (400-650 ms);
    ///   rest = max(450, tap cap) (450-900 ms);
    ///   double gap = p90 of her tap-to-tap gaps x 1.3 (350-650 ms);
    ///   slop = p90 of her drift x 1.5 (16-32 pt);
    ///   flick = max(slop + 4, p10 of her flick travel x 0.6) (20-40 pt, at least slop + 4).
    static func fitted(taps: [Double], gaps: [Double], drifts: [Double], flicks: [Double]) -> ArcadeTouchFit {
        var fit = relaxed
        if taps.count >= minimumSamples, let p90 = percentile(taps, 90) {
            let cap = p90 * 1.3
            fit.tapMs = clamp(cap, tapBounds)
            fit.restMs = clamp(max(450, cap), restBounds)
        }
        if gaps.count >= minimumSamples, let p90 = percentile(gaps, 90) {
            fit.doubleMs = clamp(p90 * 1.3, doubleBounds)
        }
        if drifts.count >= minimumSamples, let p90 = percentile(drifts, 90) {
            fit.slopPx = clamp(p90 * 1.5, slopBounds)
        }
        var flick = relaxed.flickPx
        if flicks.count >= minimumSamples, let p10 = percentile(flicks, 10) { flick = p10 * 0.6 }
        fit.flickPx = max(clamp(max(fit.slopPx + 4, flick), flickBounds), fit.slopPx + 4)
        return fit
    }

    /// The numbers as the kit is told them (setSettings touchTiming).
    var json: [String: Any] {
        ["tapMs": tapMs, "doubleMs": doubleMs, "tapSlopPx": slopPx, "flickPx": flickPx, "restMs": restMs]
    }
}

/// Settings, Touch timing.
enum ArcadeTouchTiming: String, CaseIterable, Codable {
    case fitted, relaxed, quick

    var label: String {
        switch self {
        case .fitted: return "Fitted to me"
        case .relaxed: return "Relaxed"
        case .quick: return "Quick"
        }
    }
}

/// Her touch timing, kept per player for every game (UserDefaults
/// 'arcade.touchTiming', JSON).
struct ArcadeTouchTimingStore: Codable, Equatable {
    static let key = "arcade.touchTiming"

    var choice: ArcadeTouchTiming = .relaxed
    /// What Pad practice fitted, once she has done it.
    var fitted: ArcadeTouchFit?

    /// The recognizer's overlay: nil keeps the tables' own numbers (Relaxed,
    /// or Fitted to me before any practice).
    var overlay: ArcadeTouchFit? {
        switch choice {
        case .fitted: return fitted
        case .relaxed: return nil
        case .quick: return .quick
        }
    }

    /// What the kit is told: the choice, and the numbers in use when they are not the tables' own.
    var kitValue: [String: Any] {
        var value: [String: Any] = ["choice": choice.rawValue]
        if let overlay { value.merge(overlay.json) { _, mine in mine } }
        return value
    }

    static func decode(_ data: Data?) -> ArcadeTouchTimingStore {
        guard let data, let store = try? JSONDecoder().decode(ArcadeTouchTimingStore.self, from: data) else {
            return ArcadeTouchTimingStore()
        }
        return store
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

// MARK: - The feel of a touch

enum ArcadeBuzzStyle: String, Equatable {
    case selection, light, medium, heavy, rigid, soft, success, warning
}

/// One haptic: a style, its strength (impacts only) and how long after the first one it comes.
struct ArcadeBuzz: Equatable {
    var style: ArcadeBuzzStyle
    var intensity: Double = 1
    var afterMs: Double = 0
}

/// A haptic for every gesture by its action (the plan's gesture table), and
/// for the kit's game cues. Haptics carry the confirmation so that, on the
/// speaker, nothing competes with speech; the only sounds are the pad's chimes.
enum ArcadeFeel {
    static let attackButtons: Set<String> = ["CL", "CU", "CD", "CR"]
    static let strongButtons: Set<String> = ["CU", "CR"]
    static let selection = [ArcadeBuzz(style: .selection)]
    /// Back (B): two light taps 60 ms apart.
    static let back = [ArcadeBuzz(style: .light), ArcadeBuzz(style: .light, afterMs: 60)]
    /// Start and pause, and a block taking hold.
    static let start = [ArcadeBuzz(style: .rigid)]
    /// A touch that did nothing.
    static let dud = [ArcadeBuzz(style: .warning)]
    /// The pad taken (with the rising chime).
    static let taken = [ArcadeBuzz(style: .success)]

    static func of(_ report: ArcadeGestureReport) -> [ArcadeBuzz] {
        let kind = ArcadeGestureWords.split(report.key).kind
        switch kind {
        case "stick": return []   // the stick's own direction ticks
        case "release": return [ArcadeBuzz(style: .soft)]
        case "press": return [ArcadeBuzz(style: .light)]
        default: break
        }
        let fight = report.mode == "fight"
        switch report.action {
        case .hold:
            return start
        case .info(let what):
            return what == "quiet" || what == "help" ? [ArcadeBuzz(style: .soft)] : selection
        case .pulse(let state):
            let buttons = Set(state.buttons)
            if buttons.contains("START") { return start }
            if buttons.contains("B") { return back }
            if fight, !buttons.isDisjoint(with: attackButtons) {
                if kind == "tap" { return [ArcadeBuzz(style: .light)] }   // the Easy tap attack
                return isStrong(report, buttons: buttons) ? [ArcadeBuzz(style: .heavy)] : [ArcadeBuzz(style: .medium)]
            }
            if buttons.contains("A") { return [ArcadeBuzz(style: .medium)] }   // choose
            if buttons.isEmpty || !fight { return selection }   // a menu step, a C button in menus
            return [ArcadeBuzz(style: .medium)]
        }
    }

    /// Strong attacks buzz heavy: by the table's words when it has them, else CU and CR.
    static func isStrong(_ report: ArcadeGestureReport, buttons: Set<String>) -> Bool {
        if let say = report.say?.lowercased() {
            if say.contains("strong") { return true }
            if say.contains("weak") { return false }
        }
        return !buttons.isDisjoint(with: strongButtons)
    }

    /// The kit's 'cue' event {k}: haptics only, so on the speaker they never compete with speech.
    static func cue(_ kind: String) -> [ArcadeBuzz] {
        switch kind {
        case "telegraph": return [ArcadeBuzz(style: .rigid), ArcadeBuzz(style: .rigid, afterMs: 70)]
        case "hurt": return [ArcadeBuzz(style: .heavy, intensity: 1)]
        case "landed": return [ArcadeBuzz(style: .light), ArcadeBuzz(style: .light, afterMs: 60)]
        case "blocked": return [ArcadeBuzz(style: .rigid, intensity: 0.6)]
        case "reach": return [ArcadeBuzz(style: .soft, intensity: 0.4)]
        case "ko": return [ArcadeBuzz(style: .success)]
        default: return []
        }
    }
}

// MARK: - The pad's words and lines

enum ArcadePadWords {
    static let label = "Game pad"
    /// Replaces the 40-word hint: the full controls are under How to play.
    static let hint = "Double-tap to play."

    /// The pad's value from the kit's mode.
    static func value(mode: String) -> String {
        switch mode {
        case "fight": return "Fight"
        case "pause": return "Paused"
        case "demo": return "Demo"
        default: return "Menu"
        }
    }
}

/// The app's own lines for the pad (no game names: these are said for every game).
enum ArcadeTouchLines {
    static let padOn = "Pad on."
    static let pausedReturn = "Paused. Two-finger double-tap to fight."
    static let watchdog = "The pad isn't held. Double-tap the screen to play."
    static let directTouchOff = "Direct touch looks off for this app. In the VoiceOver rotor, turn Direct Touch on."
    static let offerTitle = "First time with the game pad?"
    static let offerLearn = "Learn the pad, about three minutes"
    static let offerPlay = "Play now"
}

// MARK: - Taking hold of the pad

/// What the pad's held state asks for.
enum ArcadePadEffect: Equatable {
    case risingChime
    case fallingChime
    /// The success haptic that comes with the rising chime.
    case takenBuzz
    /// A line through the kit's one queue (cls: answer, screen, teach).
    case say(String, cls: String)
    /// revivalKit.holdSpeech(on).
    case holdSpeech(Bool)
    /// The game's own pause (a fight left while the pad was held).
    case pauseGame
    /// VoiceOver focus is back on the pad, not held: the kit's voice may go
    /// again once VoiceOver has read the pad (the host waits, then lets it go
    /// if focus is still there), as it is held only while focus is off the pad.
    case focusedNotHeld
}

/// The pad's held state with VoiceOver: iOS says nothing when a direct touch
/// area is taken, so the pad decides. Focus on the pad waits for the hold;
/// VoiceOver's activate (if iOS calls it on the activating double-tap) or
/// else the first touch that reaches the pad takes it: a rising chime, a
/// success buzz, the kit's voice let go, "Pad on." the first time each
/// session, and "Paused. Two-finger double-tap to fight." when a fight paused
/// itself as she left (with the kit's one queue, its own pause read says
/// that instead, unless "Pad on." cuts it). Focus leaving the pad: a falling
/// chime, the kit's voice held (answers still pass), and a live fight pauses
/// (Pause when I leave the pad). Two activates within 10 s with no touch
/// between mean direct touch is off for the app: said once.
struct ArcadePadHold {
    private(set) var focused = false
    /// VoiceOver focus has been on the pad at least once (until then, nothing says where it is).
    private(set) var focusedOnce = false
    private(set) var held = false
    private(set) var autoPaused = false
    private(set) var saidPadOn = false
    private(set) var saidDirectTouch = false
    /// VoiceOver's activate came at least once (for the report).
    private(set) var activates = 0
    /// The kit's mode, as the pad has it ('menu', 'fight', 'pause', 'demo').
    private(set) var mode = "menu"
    /// Oct 21 2026: the page's kit has the one queue (the host asks it at
    /// 'ready'). Its pause screen read, held while she was off the pad, is
    /// said as the hold lifts and ends with the same words as the paused
    /// line, so that line is said only where "Pad on." cuts the read or the
    /// read is already gone (heldReadDropped). An older kit (false, until
    /// known) has no held read: the line is always said.
    var kitQueue = false
    /// The kit's held pause read is gone: its queue was cleared while she was
    /// off the pad with the fight paused for her (an answer she asked for
    /// from the strip or Settings, or quiet), so the paused line is said on her return.
    private(set) var heldReadDropped = false
    private var lastActivate: Double?
    private var touchedSinceActivate = true

    /// VoiceOver's own tap after its activate: accessibilityActivate returns
    /// false, so VoiceOver follows it with a tap of its own at the pad's
    /// activation point (its middle). One finger within 150 ms of the
    /// activate and within 2 points of that point is that tap, not hers: it
    /// is not played and does not count as a touch reaching the pad (so the
    /// Direct Touch check can still see two activates with no touch between).
    static func isVoiceOverTap(sinceActivateMs: Double?, fingers: Int, offset: Double) -> Bool {
        guard let since = sinceActivateMs, since >= 0, since <= 150 else { return false }
        return fingers == 1 && offset <= 2
    }

    /// Focus on the pad. Not held, the kit's voice may go again once
    /// VoiceOver has read the pad (speech rule R10: held only while focus is off it).
    mutating func focus(now: Double) -> [ArcadePadEffect] {
        focused = true
        focusedOnce = true
        return held ? [] : [.focusedNotHeld]
    }

    /// VoiceOver focus has left the pad for the strip, a sheet or an alert
    /// (known only once it has been on the pad): the kit's voice stays held.
    func offPad(voiceOver: Bool) -> Bool {
        voiceOver && focusedOnce && !focused
    }

    /// The kit's mode. A fight that paused itself as she left the pad is
    /// remembered only while the game is on its pause screen: resumed some
    /// other way (the strip's Pause, the magic tap) or left for a menu, there
    /// is nothing to say on return.
    mutating func setMode(_ next: String) {
        mode = next
        if next != "pause" {
            autoPaused = false
            heldReadDropped = false
        }
    }

    /// Oct 21 2026: the kit's one queue was cleared. Every answer it queues
    /// clears what waits there (the host hears each as 'cut': her Status,
    /// Repeat or Teach me again from the strip or Settings), and so does its
    /// quiet. While she is off the pad on the pause screen of a fight that
    /// paused itself, that takes the kit's held pause read with it.
    mutating func kitQueueCleared() {
        if autoPaused && !held && mode == "pause" { heldReadDropped = true }
    }

    mutating func activate(now: Double) -> [ArcadePadEffect] {
        activates += 1
        var out: [ArcadePadEffect] = []
        if let last = lastActivate, !touchedSinceActivate, now - last <= 10_000, !saidDirectTouch {
            saidDirectTouch = true
            out.append(.say(ArcadeTouchLines.directTouchOff, cls: "answer"))
        }
        lastActivate = now
        touchedSinceActivate = false
        if !held { out += take() }
        return out
    }

    /// A touch reached the pad. Without VoiceOver the pad needs no taking.
    mutating func touch(now: Double, voiceOver: Bool) -> [ArcadePadEffect] {
        touchedSinceActivate = true
        guard voiceOver, !held else { return [] }
        return take()
    }

    mutating func lostFocus(now: Double, mode: String, pauseOnLeave: Bool) -> [ArcadePadEffect] {
        focused = false
        guard held else { return [.holdSpeech(true)] }
        held = false
        var out: [ArcadePadEffect] = [.fallingChime, .holdSpeech(true)]
        if mode == "fight" && pauseOnLeave {
            autoPaused = true
            out.append(.pauseGame)
        }
        return out
    }

    /// The game left the fight some other way (her own Start, a menu): nothing to say on return.
    mutating func forgetPause() {
        autoPaused = false
        heldReadDropped = false
    }

    private mutating func take() -> [ArcadePadEffect] {
        held = true
        var out: [ArcadePadEffect] = [.risingChime, .takenBuzz, .holdSpeech(false)]
        let saysPadOn = !saidPadOn
        if saysPadOn {
            saidPadOn = true
            out.append(.say(ArcadeTouchLines.padOn, cls: "answer"))
        }
        let readGone = heldReadDropped
        heldReadDropped = false
        if autoPaused {
            autoPaused = false
            // Only while the game is still paused: the line asks for the
            // two-finger double-tap that resumes it. With the kit's one queue,
            // only when the kit's own held read is gone: "Pad on." (an answer)
            // cuts it now, or an answer while she was away already cleared it.
            if mode == "pause" && (!kitQueue || saysPadOn || readGone) {
                out.append(.say(ArcadeTouchLines.pausedReturn, cls: "screen"))
            }
        }
        return out
    }
}

/// The fight watchdog: the kit's 'idleHurt' (she lost health with no
/// presses) is said only when the pad itself had no touches in those five
/// seconds, once per fight, never in a demo.
enum ArcadeWatchdog {
    static let windowMs = 5000.0

    static func shouldWarn(mode: String, lastTouch: Double?, now: Double, warnedThisFight: Bool) -> Bool {
        guard mode == "fight", !warnedThisFight else { return false }
        guard let lastTouch else { return true }
        return now - lastTouch >= windowMs
    }
}

// MARK: - One voice at a time

/// A line VoiceOver (or the phone's own speech) says: the kit's native item
/// with its id, or the app's own line (no id).
struct ArcadeSpeechItem: Equatable {
    let id: String?
    let text: String
    let cls: String
    /// Her own action asked for it: it may cut the line being said.
    var interrupts = false
    var tries = 0
}

enum ArcadeSpeechStep: Equatable {
    /// Say it now: a VoiceOver announcement, or AVSpeech with VoiceOver off.
    case post(ArcadeSpeechItem)
    /// revivalKit.spoken(id, ok).
    case ack(id: String, ok: Bool)
    /// Stop the phone's own speech now (a line that interrupts is posted
    /// next, and that cuts VoiceOver's line by itself).
    case stop
    /// Stop what is being said now with nothing in its place: the phone's
    /// own speech, and VoiceOver's announcement too (Quiet, or the kit's cut).
    case silence
}

/// The app's side of the kit's one queue (speech rule R1): exactly one line
/// at a time. A line ends with VoiceOver's announcementDidFinish (one retry
/// when VoiceOver says it was not spoken) or AVSpeech's didFinish; the kit's
/// item is then acknowledged. A line that never ends is given up after
/// 0.8 s + 0.4 s a word (at most 8 s), as the kit does. The kit's 'quiet'
/// stops the phone's speech and drops everything waiting.
struct ArcadeSpeechQueue {
    private(set) var current: ArcadeSpeechItem?
    private(set) var waiting: [ArcadeSpeechItem] = []
    /// When the current line is given up on (ms, the caller's clock).
    private(set) var deadline: Double?
    /// Lines this queue cut partway: VoiceOver (or AVSpeech) still reports
    /// their end, as not spoken, and that end is theirs, never the end of a
    /// new line with the same words (Pad practice says the same say-back twice in a row).
    private(set) var cutTexts: [String] = []

    static func timeoutMs(_ text: String) -> Double {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return min(8000, 800 + 400 * Double(words))
    }

    /// Whether the kit's native item cuts the line being said: her answers
    /// do (the kit marks them urgent and has already cut its own line, R2),
    /// and an older kit's own flush. An older kit (no id) keeps its flush alone.
    static func kitInterrupts(flush: Bool, urgent: Bool, id: String?) -> Bool {
        flush || (id != nil && urgent)
    }

    var isIdle: Bool { current == nil && waiting.isEmpty }

    /// A new line. One that interrupts (her own action) drops what waits,
    /// ends the current line unacknowledged and starts at once.
    mutating func add(_ item: ArcadeSpeechItem, now: Double) -> [ArcadeSpeechStep] {
        var steps: [ArcadeSpeechStep] = []
        if item.interrupts {
            for dropped in [current].compactMap({ $0 }) + waiting {
                if let id = dropped.id { steps.append(.ack(id: id, ok: false)) }
            }
            if let cut = current {
                noteCut(cut.text)
                steps.append(.stop)
            }
            current = nil
            deadline = nil
            waiting = []
        }
        waiting.append(item)
        return steps + startNext(now: now)
    }

    /// The current line ended (text: what VoiceOver says it finished; nil
    /// matches the current line). Another line's end is ignored, and so is
    /// the end of a line this queue cut itself.
    mutating func finished(text: String?, ok: Bool, now: Double) -> [ArcadeSpeechStep] {
        let said = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ok, let said, let index = cutTexts.firstIndex(of: said) {
            cutTexts.remove(at: index)
            return []
        }
        guard var item = current else { return [] }
        if let said, said != item.text { return [] }
        // Oct 21 2026: the one retry stays inside the line's first window:
        // the kit's own wait for this id runs from when it was routed, so the
        // deadline is kept, and with less than half of it left there is no
        // retry (not spoken, at once).
        if !ok && item.tries < 1, let deadline, deadline - now >= Self.timeoutMs(item.text) / 2 {
            item.tries += 1
            current = item
            return [.post(item)]
        }
        current = nil
        deadline = nil
        var steps: [ArcadeSpeechStep] = []
        if let id = item.id { steps.append(.ack(id: id, ok: ok)) }
        return steps + startNext(now: now)
    }

    /// The current line ran past its time: given up (not spoken), the next
    /// one starts. A line said a second time (the retry) may still be going:
    /// it stops, so it never talks over the kit's next line.
    mutating func expire(now: Double) -> [ArcadeSpeechStep] {
        guard let deadline, now >= deadline, let item = current else { return [] }
        current = nil
        self.deadline = nil
        var steps: [ArcadeSpeechStep] = []
        if let id = item.id { steps.append(.ack(id: id, ok: false)) }
        if item.tries > 0 {
            noteCut(item.text)
            steps.append(.silence)
        }
        return steps + startNext(now: now)
    }

    /// The kit's 'quiet' (her two-finger tap): stop, VoiceOver's line too, and drop everything.
    mutating func quiet() -> [ArcadeSpeechStep] {
        let speaking = current?.text
        current = nil
        deadline = nil
        waiting = []
        guard let text = speaking else { return [] }
        noteCut(text)
        return [.silence]
    }

    /// The kit cut its own line for her answer (R2): its items here are gone
    /// in the kit already, so they go here too, unacknowledged, and the one
    /// being said stops. The app's own lines stay.
    mutating func cutKit(now: Double) -> [ArcadeSpeechStep] {
        waiting.removeAll { $0.id != nil }
        guard let item = current, item.id != nil else { return [] }
        current = nil
        deadline = nil
        noteCut(item.text)
        return [.silence] + startNext(now: now)
    }

    /// A new page (the game restarted): the old page's items go, and its ids
    /// mean nothing to the new page (which numbers its own from the start
    /// again), so none is acknowledged. The app's own lines stay, and a line
    /// already being said is said to its end.
    mutating func dropKit(now: Double) -> [ArcadeSpeechStep] {
        waiting.removeAll { $0.id != nil }
        if let item = current, item.id != nil {
            current = nil
            deadline = nil
        }
        return startNext(now: now)
    }

    private mutating func noteCut(_ text: String) {
        cutTexts.append(text)
        if cutTexts.count > 8 { cutTexts.removeFirst(cutTexts.count - 8) }
    }

    private mutating func startNext(now: Double) -> [ArcadeSpeechStep] {
        guard current == nil, !waiting.isEmpty else { return [] }
        let next = waiting.removeFirst()
        current = next
        deadline = now + Self.timeoutMs(next.text)
        return [.post(next)]
    }
}

// MARK: - Gesture words (say-back, How to play)

enum ArcadeGestureWords {
    /// "doubleTap2" -> ("doubleTap", 2).
    static func split(_ key: String) -> (kind: String, fingers: Int) {
        let kind = String(key.prefix(while: { $0.isLetter }))
        let fingers = Int(key.dropFirst(kind.count)) ?? 1
        return (kind, fingers)
    }

    static func fingersWord(_ n: Int) -> String {
        switch n {
        case 2: return "Two-finger"
        case 3: return "Three-finger"
        case 4: return "Four-finger"
        default: return "\(n)-finger"
        }
    }

    static func countWords(_ n: Int) -> String {
        switch n {
        case 1: return "one finger"
        case 2: return "two fingers"
        case 3: return "three fingers"
        default: return "\(n) fingers"
        }
    }

    /// "Tap", "Two-finger double-tap", "Flick up", "Rest" (a held hold in a
    /// fight), "Hold", "Two-finger scrub", "Lift" (a held hold let go).
    static func gesture(key: String, direction: ArcadeDirection?, mode: String, held: Bool) -> String {
        let (kind, n) = split(key)
        let way = direction.map { " " + $0.rawValue } ?? ""
        let many = fingersWord(n) + " "
        switch kind {
        case "tap": return n > 1 ? many + "tap" : "Tap"
        case "doubleTap": return n > 1 ? many + "double-tap" : "Double-tap"
        case "flick": return n > 1 ? many + "flick" + way : "Flick" + way
        case "hold":
            if n == 1 { return held && mode == "fight" ? "Rest" : "Hold" }
            return many + "hold"
        case "scrub": return n > 1 ? many + "scrub" : "Scrub"
        case "release": return "Lift"
        case "stick": return "Slide"
        case "press": return n > 1 ? many + "press" : "Press"
        default: return key
        }
    }

    static let infoWords: [String: String] = [
        "here": "hear it", "repeat": "repeat", "quiet": "quiet", "help": "help",
        "status": "how you're doing", "where": "where everyone is", "nextLine": "next line",
        "prevLine": "line before", "health": "health", "facing": "facing", "time": "time",
    ]

    static let buttonWords: [String: String] = [
        "START": "start", "block": "block", "CL": "C left", "CU": "C up", "CD": "C down", "CR": "C right",
        "DUP": "up", "DDOWN": "down", "DLEFT": "left", "DRIGHT": "right",
    ]

    static func stateWords(_ state: ArcadePadState) -> String {
        if !state.buttons.isEmpty { return state.buttons.map { buttonWords[$0] ?? $0 }.joined(separator: " and ") }
        if state.sx > 0 { return "right" }
        if state.sx < 0 { return "left" }
        if state.sy > 0 { return "down" }
        if state.sy < 0 { return "up" }
        return "nothing"
    }

    /// The action's words: the table's own 'say', else made from the action.
    static func action(_ action: ArcadePadAction, say: String?, release: Bool = false) -> String {
        let words: String
        if let say {
            words = say
        } else {
            switch action {
            case .info(let what): words = infoWords[what] ?? what
            case .pulse(let state): words = stateWords(state)
            case .hold(let state): words = stateWords(state)
            }
        }
        return release ? words + " off" : words
    }

    /// Pad practice's say-back: "<gesture>: <action>." ("Flick up: strong
    /// punch.", "Rest: block.", "Lift: block off.", "Two-finger scrub: back.").
    static func sayBack(_ report: ArcadeGestureReport) -> String {
        let release = report.key.hasPrefix("release")
        var held = false
        if case .hold = report.action { held = true }
        var name = gesture(key: report.key, direction: report.direction, mode: report.mode, held: held)
        if report.fromHold { name = "From a block, " + name.lowercased() }
        return name + ": " + action(report.action, say: report.say, release: release) + "."
    }
}

struct ArcadeHowToPlaySection: Equatable {
    let title: String
    let rows: [String]
}

/// How to play (a strip button): the controls in normal VoiceOver text,
/// built from the table's own 'say' words, for menus and the fight tier in use.
enum ArcadeHowToPlay {
    static func rows(_ set: ArcadeGestureSet, mode: String) -> [String] {
        var rows: [String] = []
        func row(_ key: String, _ direction: ArcadeDirection?, _ action: ArcadePadAction, _ say: String?) {
            var held = false
            if case .hold = action { held = true }
            let name = ArcadeGestureWords.gesture(key: key, direction: direction, mode: mode, held: held)
            rows.append(name + ": " + ArcadeGestureWords.action(action, say: say) + ".")
        }
        for n in 1...4 {
            if let action = set.taps[n] { row("tap\(n)", nil, action, set.says["tap\(n)"]) }
            if let action = set.doubleTaps[n] { row("doubleTap\(n)", nil, action, set.says["doubleTap\(n)"]) }
            if let flick = set.flicks[n] {
                for direction in [ArcadeDirection.right, .left, .up, .down] {
                    if let action = flick.actions[direction] { row("flick\(n)", direction, action, flick.says[direction]) }
                }
            }
            if let action = set.holds[n] {
                row("hold\(n)", nil, action, set.says["hold\(n)"])
                if set.flickBreaks.contains(n), set.flicks[n] != nil {
                    rows.append("From a \(set.says["hold\(n)"] ?? "hold"), flick to hit back.")
                }
            }
            if let action = set.scrubs[n] { row("scrub\(n)", nil, action, set.says["scrub\(n)"]) }
            if n == 1, set.stickRadius != nil { rows.append("Slide a finger: " + (set.says["stick1"] ?? "move") + ".") }
            if let state = set.presses[n] { row("press\(n)", nil, .hold(state), set.says["press\(n)"]) }
        }
        return rows
    }

    static func zoneWords(_ name: String) -> String {
        switch name {
        case "left": return "left half"
        case "right": return "right half"
        case "pad": return "the whole pad"
        default: return name.count <= 2 ? "the " + name.uppercased() + " area" : name
        }
    }

    /// Menus, then the fight tier in use (one zone: the whole pad; zones;
    /// or the two halves and anywhere). `plainHelp` is the plain player's
    /// own help, which leads.
    static func sections(table: ArcadeTouchTable, plainHelp: String?) -> [ArcadeHowToPlaySection] {
        var out: [ArcadeHowToPlaySection] = []
        if let plainHelp, !plainHelp.isEmpty { out.append(ArcadeHowToPlaySection(title: "The game's own help", rows: [plainHelp])) }
        out.append(ArcadeHowToPlaySection(title: "Menus", rows: rows(table.menu, mode: "menu")))
        let fight = table.active
        var title = "Fights"
        if table.fights[table.tier] != nil { title = table.tier == "easy" ? "Fights, Easy controls" : "Fights, Full controls" }
        if fight.zones.count == 1, let only = fight.zones.first {
            out.append(ArcadeHowToPlaySection(title: title, rows: rows(fight.gestures(zone: ArcadeZone(only.name)), mode: "fight")))
        } else if !fight.zones.isEmpty {
            for zone in fight.zones {
                let set = fight.named[zone.name] ?? (zone.name == "left" ? fight.left : (zone.name == "right" ? fight.right : ArcadeGestureSet()))
                out.append(ArcadeHowToPlaySection(title: title + ", " + zoneWords(zone.name), rows: rows(set, mode: "fight")))
            }
            out.append(ArcadeHowToPlaySection(title: title + ", anywhere", rows: rows(fight.anywhere, mode: "fight")))
        } else {
            out.append(ArcadeHowToPlaySection(title: title + ", left half", rows: rows(fight.left, mode: "fight")))
            out.append(ArcadeHowToPlaySection(title: title + ", right half", rows: rows(fight.right, mode: "fight")))
            out.append(ArcadeHowToPlaySection(title: title + ", anywhere", rows: rows(fight.anywhere, mode: "fight")))
        }
        return out.filter { !$0.rows.isEmpty }
    }
}

// MARK: - Pad practice

struct ArcadePracticeStep: Equatable {
    enum Want: Equatable {
        /// Lesson 1: the pad taken, VoiceOver back, the pad taken again.
        case held
        case released
        case gesture(key: String, direction: ArcadeDirection?, fromHold: Bool)
    }

    let line: String
    let want: Want
    /// The pad's mode for this step ('menu' or 'fight').
    let mode: String
    /// The wanted action's words (for "Flick right for strong kick.").
    var say: String?
}

struct ArcadePracticeLesson: Equatable {
    /// "the pad", "menus", "fighting".
    let title: String
    /// "Lesson 2, menus." said before its first step.
    let intro: String
    let steps: [ArcadePracticeStep]
}

/// Pad practice: a native screen, no game running (the plan's VoiceOver
/// Practice for the game pad). Every attempt is said back as "<gesture>:
/// <action>."; a touch that did nothing gets its reason, and a different
/// gesture a specific correction; a step passes after two clean in a row
/// (Lesson 1's pad steps after one); Next lesson skips. The lessons come
/// from the pack's practice table when it has one, else from the game's own
/// tables and their 'say' words. Her taps, tap-to-tap gaps, drift and flick
/// travel are measured all the way through, for Fitted to me.
struct ArcadePadPractice {
    static let opening = "Pad practice. Nothing here plays the game. The buttons along the top are Done, Next lesson and Repeat."
    static let good = "Good."
    static let lessonDone = "Lesson done."
    /// The end when her taps were measured enough to fit (Fitted to me is kept).
    static let finishedLine = "Done. The pad is tuned to your touch."
    /// The end when they were not (Next lesson skipped them): nothing was tuned.
    static let doneLine = "Done."
    /// The end's pointer for a game with fight tiers (it names no game).
    static let practiceModeLine = "In the game, Practice on the main menu is a safe first fight."
    static let cleanToPass = 2

    let lessons: [ArcadePracticeLesson]
    let endLine: String?
    private(set) var lesson = 0
    private(set) var step = 0
    private(set) var clean = 0
    private(set) var finished = false
    private(set) var taps: [Double] = []
    private(set) var gaps: [Double] = []
    private(set) var drifts: [Double] = []
    private(set) var flicks: [Double] = []
    private var lastTapLift: Double?
    /// The pad was just taken: the touch that took it (or, when VoiceOver's
    /// activate took it, the one touch Lesson 1 asks for after the
    /// double-tap) is not an attempt, and its say-back would cut the step's
    /// own line.
    private var skipTakingTouch = false
    /// A double-tap step's second tap came late: its own tap report is part
    /// of the same attempt, which has been said back and corrected once.
    private var skipLateTap = false

    init(lessons: [ArcadePracticeLesson], endLine: String? = nil) {
        self.lessons = lessons.filter { !$0.steps.isEmpty }
        self.endLine = endLine
        if self.lessons.isEmpty { finished = true }
    }

    var current: ArcadePracticeStep? {
        guard !finished, lesson < lessons.count, step < lessons[lesson].steps.count else { return nil }
        return lessons[lesson].steps[step]
    }

    /// The pad's mode now.
    var mode: String { current?.mode ?? "menu" }

    /// Fitted to her, from everything measured so far.
    var fit: ArcadeTouchFit { .fitted(taps: taps, gaps: gaps, drifts: drifts, flicks: flicks) }

    /// Enough taps were measured for Fitted to me to be kept.
    var keepsFit: Bool { taps.count >= ArcadeTouchFit.minimumSamples }

    /// The end's first words: tuned only when the fit is kept.
    var endWords: String { keepsFit ? Self.finishedLine : Self.doneLine }

    func startLines() -> [String] {
        var lines = [Self.opening]
        if lesson < lessons.count, !finished {
            lines.append(lessons[lesson].intro)
            if let current { lines.append(current.line) }
        }
        return lines
    }

    func repeatLines() -> [String] {
        current.map { [$0.line] } ?? [endWords]
    }

    mutating func padHeld() -> [String] {
        skipTakingTouch = true
        return pad(.held)
    }

    mutating func padReleased() -> [String] {
        skipTakingTouch = false
        return pad(.released)
    }

    private mutating func pad(_ event: ArcadePracticeStep.Want) -> [String] {
        guard let current, current.want == event else { return [] }
        return pass(needed: 1)
    }

    /// Next lesson (the strip button).
    mutating func nextLesson() -> [String] {
        guard !finished else { return [] }
        if lesson + 1 < lessons.count { return ["Next: " + lessons[lesson + 1].title + "."] + advanceLesson() }
        return advanceLesson()
    }

    /// The recognizer's outputs: say-backs, corrections and progress lines to announce, in order.
    mutating func handle(_ output: ArcadeTouchOutput) -> [String] {
        switch output {
        case .lifted(let lift):
            sample(lift)
            return []
        case .dud(let dud):
            guard let current else { return [] }
            if skipTakingTouch {
                skipTakingTouch = false
                return []
            }
            // Lesson 1's steps move only with the pad itself: a touch there is not judged.
            guard case .gesture(let key, _, _) = current.want else { return [] }
            if dud.reason == .lateDouble {
                // The late tap still counts as a tap, and its own report says what it was (and, when a
                // double-tap is wanted, that the second tap came late), so the attempt is corrected once.
                if ArcadeGestureWords.split(key).kind == "doubleTap" { skipLateTap = true }
                return []
            }
            clean = 0
            return [Self.correction(for: dud.reason)]
        case .gesture(let report):
            guard !finished, !report.repeatStep else { return [] }
            let kind = ArcadeGestureWords.split(report.key).kind
            if kind == "stick" { return [] }
            if skipTakingTouch {
                skipTakingTouch = false
                return []
            }
            if skipLateTap {
                skipLateTap = false
                if kind == "tap" { return [] }
            }
            // Lesson 1's steps move only with the pad itself: a touch there is not said back, so it
            // never cuts the step's own line.
            guard let current, case .gesture(let key, let direction, let fromHold) = current.want else { return [] }
            var lines = [ArcadeGestureWords.sayBack(report)]
            if report.key == key && (direction == nil || report.direction == direction) && (!fromHold || report.fromHold) {
                lines += pass(needed: Self.cleanToPass)
            } else if kind == "release" || (fromHold && kind == "hold") {
                // The lift after a wanted rest, or the rest before a flick out of it: on the way, not wrong.
            } else {
                clean = 0
                lines.append(Self.correction(want: current, got: report))
            }
            return lines
        default:
            return []
        }
    }

    static func correction(for reason: ArcadeDudReason) -> String {
        switch reason {
        case .slowTap: return "That touch was too long for a tap. Lift sooner."
        case .shortFlick: return "Your finger moved, but not far enough for a flick. Flick farther."
        case .drift: return "Your finger moved, so it was not a tap. Keep it still."
        case .apart: return "The fingers landed apart. Put them down together."
        case .lateDouble: return "The second tap came late. Tap twice, a little quicker."
        case .noAction: return "That gesture does nothing here."
        }
    }

    /// Expected against got.
    static func correction(want: ArcadePracticeStep, got: ArcadeGestureReport) -> String {
        guard case .gesture(let key, let direction, _) = want.want else { return want.line }
        let wanted = ArcadeGestureWords.split(key)
        let made = ArcadeGestureWords.split(got.key)
        if wanted.kind == "tap" && made.kind == "hold" && wanted.fingers == made.fingers {
            if case .hold = got.action, got.mode == "fight" {
                let held = ArcadeGestureWords.action(got.action, say: got.say)
                return "That was a rest, so it \(held)ed. Lift sooner for an attack."
            }
            return "That was a hold. Lift sooner for a tap."
        }
        if wanted.fingers != made.fingers {
            let had = ArcadeGestureWords.countWords(made.fingers)
            var use = String(wanted.fingers)
            if wanted.fingers == 1 { use = "one" } else if wanted.fingers == 2 { use = "two" }
            return "That was \(had). Use \(use)."
        }
        if wanted.kind == "scrub" { return "Not quite a scrub. Rub two fingers left and right, quickly." }
        if wanted.kind == "flick", made.kind == "flick", let direction, let way = got.direction, way != direction {
            let purpose = want.say.map { " for " + $0 } ?? ""
            return "That flick went \(way.rawValue). Flick \(direction.rawValue)\(purpose)."
        }
        if wanted.kind == "doubleTap" && made.kind == "tap" { return correction(for: .lateDouble) }
        return "Not that one. " + want.line
    }

    // MARK: Inside

    private mutating func pass(needed: Int) -> [String] {
        clean += 1
        guard clean >= needed else { return [] }
        clean = 0
        step += 1
        var lines = [Self.good]
        if step >= lessons[lesson].steps.count {
            lines.append(Self.lessonDone)
            lines += advanceLesson()
        } else if let current {
            lines.append(current.line)
        }
        return lines
    }

    private mutating func advanceLesson() -> [String] {
        lesson += 1
        step = 0
        clean = 0
        if lesson >= lessons.count {
            finished = true
            return [endWords] + (endLine.map { [$0] } ?? [])
        }
        return [lessons[lesson].intro] + (current.map { [$0.line] } ?? [])
    }

    /// Her measurements: still one-finger lifts while a step asks for a tap
    /// or a double-tap (slow ones too) for the tap time and drift, and the
    /// gaps between them while it asks for a double-tap (from one tap's lift
    /// to the next one landing, the recognizer's own rule); the travel of
    /// one-finger flicks while a step asks for a flick.
    private mutating func sample(_ lift: ArcadeLiftReport) {
        let wantKind: String
        if let current, case .gesture(let key, _, _) = current.want, ArcadeGestureWords.split(key).fingers == 1 {
            wantKind = ArcadeGestureWords.split(key).kind
        } else {
            wantKind = ""
        }
        if (wantKind == "tap" || wantKind == "doubleTap") && lift.fingers == 1 && !lift.fired
            && lift.far <= ArcadeTouchFit.slopBounds.upperBound && lift.ms <= 1000 {
            taps.append(lift.ms)
            drifts.append(lift.far)
            if wantKind == "doubleTap", let last = lastTapLift, lift.t0 >= last, lift.t0 - last <= 1500 { gaps.append(lift.t0 - last) }
            lastTapLift = lift.t1
        } else {
            lastTapLift = nil
        }
        if wantKind == "flick", lift.fingers == 1, lift.fired, lift.travel >= ArcadeTouchFit.flickBounds.lowerBound {
            flicks.append(lift.travel)
        }
    }

    // MARK: The lessons

    /// The plan's lines for the standard v2 menu table's gestures, used when
    /// the game's menu table has the same action there; anything else is
    /// said from its own words.
    static let menuLines: [(key: String, direction: ArcadeDirection?, line: String)] = [
        ("flick1", .right, "Flick right for the next item."),
        ("flick1", .left, "Flick left for the one before."),
        ("tap1", nil, "Tap once to hear where you are."),
        ("doubleTap1", nil, "Double-tap to choose."),
        ("scrub2", nil, "Two-finger scrub to go back."),
        ("doubleTap2", nil, "Two-finger double-tap is Start, and pause."),
        ("tap2", nil, "Two-finger tap makes the game quiet."),
    ]

    /// The action a set has for a key (and a flick's direction), with its words.
    static func lookup(_ set: ArcadeGestureSet, key: String, direction: ArcadeDirection?) -> (action: ArcadePadAction, say: String?)? {
        let (kind, n) = ArcadeGestureWords.split(key)
        switch kind {
        case "tap": return set.taps[n].map { (action: $0, say: set.says[key]) }
        case "doubleTap": return set.doubleTaps[n].map { (action: $0, say: set.says[key]) }
        case "hold": return set.holds[n].map { (action: $0, say: set.says[key]) }
        case "scrub": return set.scrubs[n].map { (action: $0, say: set.says[key]) }
        case "flick":
            guard let direction, let flick = set.flicks[n], let action = flick.actions[direction] else { return nil }
            return (action: action, say: flick.says[direction])
        default: return nil
        }
    }

    /// Lesson 1 (with VoiceOver: the pad on and off), Lesson 2 (menus) and
    /// Lesson 3 (the Easy fight, or the tier in use), each with only the
    /// gestures the game's tables have.
    static func makeLessons(table: ArcadeTouchTable, voiceOver: Bool) -> [ArcadePracticeLesson] {
        var lessons: [ArcadePracticeLesson] = []
        if voiceOver {
            lessons.append(ArcadePracticeLesson(title: "the pad", intro: "Lesson 1, the pad.", steps: [
                ArcadePracticeStep(line: "Double-tap below the buttons, then touch once. A rising chime means the pad is yours.",
                                   want: .held, mode: "menu"),
                ArcadePracticeStep(line: "Now touch the very top of the screen. A falling chime means VoiceOver is back.",
                                   want: .released, mode: "menu"),
                // VoiceOver is on a strip button now: a double-tap there would press it, so she
                // touches the pad first (VoiceOver moves to it), then takes it.
                ArcadePracticeStep(line: "Touch the pad below the buttons, then double-tap and touch once to take it back.",
                                   want: .held, mode: "menu"),
            ]))
        }
        let standardMenu = ArcadeTouchTable.standard.menu
        var menu: [ArcadePracticeStep] = []
        for item in menuLines {
            guard let found = lookup(table.menu, key: item.key, direction: item.direction) else { continue }
            let same = lookup(standardMenu, key: item.key, direction: item.direction)?.action == found.action
            let line: String
            if same {
                line = item.line
            } else {
                let name = ArcadeGestureWords.gesture(key: item.key, direction: item.direction, mode: "menu", held: false)
                line = name + ": " + ArcadeGestureWords.action(found.action, say: found.say) + "."
            }
            menu.append(ArcadePracticeStep(line: line, want: .gesture(key: item.key, direction: item.direction, fromHold: false),
                                           mode: "menu", say: found.say))
        }
        if !menu.isEmpty {
            lessons.append(ArcadePracticeLesson(title: "menus", intro: "Lesson \(lessons.count + 1), menus.", steps: menu))
        }
        let tier = table.fights["easy"] != nil ? table.onTier("easy") : table
        let fight = tier.active
        // The whole pad when the tier is one zone; else the right half (attacks), as the halves are taught later.
        let zone: ArcadeZone? = fight.zones.count == 1 ? ArcadeZone(fight.zones[0].name) : (fight.zones.isEmpty ? .right : nil)
        var steps: [ArcadePracticeStep] = []
        if let zone {
            let set = fight.gestures(zone: zone)
            let anywhere = zone == .right ? "" : " anywhere"
            func add(_ key: String, _ direction: ArcadeDirection?, _ make: (String) -> String, fromHold: Bool = false) {
                guard let found = lookup(set, key: key, direction: direction) else { return }
                let words = ArcadeGestureWords.action(found.action, say: found.say)
                steps.append(ArcadePracticeStep(line: make(words), want: .gesture(key: key, direction: direction, fromHold: fromHold),
                                                mode: "fight", say: found.say))
            }
            // The Easy tap is "an attack" (any of them lands); anything else is said by its own words.
            let easyTap = ArcadeTouchTable.standard.fights["easy"]?.gestures(zone: ArcadeZone("pad")).taps[1]
            add("tap1", nil) { words in "Tap" + anywhere + ": " + (set.taps[1] == easyTap ? "an attack" : words) + "." }
            for direction in [ArcadeDirection.up, .right, .down, .left] {
                add("flick1", direction) { "Flick \(direction.rawValue): \($0)." }
            }
            add("hold1", nil) { "Rest a finger still: \($0). Lift to stop." }
            if set.flickBreaks.contains(1), set.flicks[1] != nil, set.holds[1] != nil {
                steps.append(ArcadePracticeStep(line: "From a block, flick to hit back.",
                                                want: .gesture(key: "flick1", direction: nil, fromHold: true), mode: "fight"))
            }
            add("flick2", .down) { "Two fingers, flick down: \($0)." }
            add("flick2", .up) { "Two fingers, flick up: \($0)." }
            add("hold2", nil) { "Hold two fingers still: \($0)." }
        }
        if !steps.isEmpty {
            let walk = table.fights["easy"] != nil ? " With Walk in for me on, you are walked to your foe." : ""
            lessons.append(ArcadePracticeLesson(title: "fighting", intro: "Lesson \(lessons.count + 1), fighting." + walk, steps: steps))
        }
        return lessons
    }

    /// The pack's own practice table (input.touch.practice, when the kit
    /// ships one): {lessons: [{title, intro, steps: [{key, dir, mode, line,
    /// say, fromHold}]}], end}. Lesson 1 (the pad) is always the app's own.
    /// Nil when there is none or it has no usable step.
    static func makeLessons(json: [String: Any]?, voiceOver: Bool) -> (lessons: [ArcadePracticeLesson], end: String?)? {
        guard let json, let rows = json["lessons"] as? [Any] else { return nil }
        var lessons = voiceOver ? Array(makeLessons(table: ArcadeTouchTable(), voiceOver: true).prefix(1)) : []
        for row in rows {
            guard let lesson = row as? [String: Any] else { continue }
            var steps: [ArcadePracticeStep] = []
            for item in (lesson["steps"] as? [Any]) ?? [] {
                guard let step = item as? [String: Any], let key = step["key"] as? String, !key.isEmpty,
                      let line = step["line"] as? String, !line.isEmpty else { continue }
                let direction = (step["dir"] as? String).flatMap { ArcadeDirection(rawValue: $0) }
                let mode = (step["mode"] as? String) == "fight" ? "fight" : "menu"
                steps.append(ArcadePracticeStep(line: line, want: .gesture(key: key, direction: direction,
                                                                            fromHold: (step["fromHold"] as? Bool) ?? false),
                                                mode: mode, say: step["say"] as? String))
            }
            guard !steps.isEmpty else { continue }
            let title = (lesson["title"] as? String) ?? "practice"
            let intro = (lesson["intro"] as? String) ?? "Lesson \(lessons.count + 1), \(title)."
            lessons.append(ArcadePracticeLesson(title: title, intro: intro, steps: steps))
        }
        let usable = lessons.contains { (lesson: ArcadePracticeLesson) -> Bool in
            lesson.steps.contains(where: { (step: ArcadePracticeStep) -> Bool in
                if case .gesture = step.want { return true }
                return false
            })
        }
        guard usable else { return nil }
        return (lessons, json["end"] as? String)
    }
}

// MARK: - The chimes

/// The pad's two sounds, made in code (no file to bundle): a 120 ms glide,
/// rising when the pad is taken, falling when VoiceOver comes back. Mono
/// 16-bit WAV at 22,050 Hz.
enum ArcadeChime {
    static let sampleRate = 22_050
    static let milliseconds = 120.0

    static func wav(rising: Bool) -> Data {
        let count = Int(Double(sampleRate) * milliseconds / 1000)
        let from = rising ? 660.0 : 990.0
        let to = rising ? 990.0 : 660.0
        var data = Data()
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        put32(UInt32(36 + count * 2))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        put32(16)
        put16(1)   // PCM
        put16(1)   // mono
        put32(UInt32(sampleRate))
        put32(UInt32(sampleRate * 2))
        put16(2)
        put16(16)
        data.append(contentsOf: Array("data".utf8))
        put32(UInt32(count * 2))
        var phase = 0.0
        let rate = Double(sampleRate)
        for index in 0..<count {
            let t = Double(index) / Double(count)
            let frequency = from + (to - from) * t
            phase += 2 * Double.pi * frequency / rate
            let attack = min(1, Double(index) / (0.008 * rate))
            let release = min(1, Double(count - index) / (0.04 * rate))
            let value = sin(phase) * 0.35 * attack * release
            let sample = Int16(max(-1, min(1, value)) * 32767)
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

// MARK: - The kit's touch choices

/// The kit-owned touch settings (kept by the kit and given back like its
/// others): Fight controls, Walk in for me, Less damage, Skip the demo
/// fight, and coached (the teach pause, once per tier). The app fills its
/// defaults for a game that has fight tiers.
struct ArcadeTouchChoices: Equatable {
    var fightControls = "easy"
    var walkIn = true
    /// Nil: the kit's own default (on in Easy for touch input until she turns it off).
    var lessDamage: Bool?
    /// Nil: the kit's own default (on for touch input only, so keyboard and
    /// controller players keep the demo fight).
    var skipDemo: Bool?
    /// Oct 21 2026: Less damage and Skip the demo fight as this page's kit
    /// has them, from the 'settings' it sent (nil until it has sent any), for
    /// the switches only. The kit sets its own defaults at boot and on a
    /// switch to touch, never on a change of Fight controls, so mid-session
    /// they can differ from the defaults worked out here.
    var kitLessDamage: Bool?
    /// Nil also when the kit has no skipDemo of its own: it follows the input then.
    var kitSkipDemo: Bool?

    init() {}

    init(settings: [String: Any]?) {
        let settings = settings ?? [:]
        if let tier = settings["fightControls"] as? String, tier == "easy" || tier == "full" { fightControls = tier }
        if let value = settings["walkIn"] as? Bool { walkIn = value }
        if let value = settings["lessDamage"] as? Bool { lessDamage = value }
        if let value = settings["skipDemo"] as? Bool { skipDemo = value }
    }

    /// Oct 21 2026: her choices from the kit's kept settings (Less damage and
    /// Skip the demo fight only where she set them; onlyChosen), with what
    /// this page's kit is doing from `echo`, the 'settings' it sent (nil until
    /// it has sent any). Only her choices go back to the kit.
    init(settings: [String: Any]?, chosen: Set<String>, echo: [String: Any]?) {
        self.init(settings: ArcadeTouchChoices.onlyChosen(settings, chosen: chosen))
        guard let echo else { return }
        // The kit's Less damage is on only when it is true there.
        kitLessDamage = (echo["lessDamage"] as? Bool) ?? false
        kitSkipDemo = echo["skipDemo"] as? Bool
    }

    /// Less damage as the Settings switch shows it: her choice, else what
    /// this page's kit is doing, else (before it has said) on in Easy for
    /// touch input (Oct 21 2026: as the kit has it, now that only her own
    /// choice goes back to it, a keyboard or controller player's is off).
    func lessDamageShown(touch: Bool) -> Bool { lessDamage ?? kitLessDamage ?? (touch && fightControls == "easy") }

    /// Skip the demo fight as the Settings switch shows it: her choice, else
    /// what this page's kit is doing, else on for touch input.
    func skipDemoShown(touch: Bool) -> Bool { skipDemo ?? kitSkipDemo ?? touch }

    /// Oct 21 2026: the kit's touch keys whose default depends on the input
    /// at hand (Less damage: on in Easy for touch; Skip the demo fight: on for
    /// touch). The kit takes any key given back to it as her choice, and its
    /// 'settings' carry every key it has, so these go back to it only once
    /// she has set them in the game's Settings herself.
    static let inputDefaultKeys = ["lessDamage", "skipDemo"]

    /// The kit's kept settings without the input-dependent keys she has not
    /// chosen (`chosen`: the keys she set in Settings; settings kept by an
    /// earlier build count as not chosen), so the kit's own default for the
    /// input at hand applies at every start.
    static func onlyChosen(_ settings: [String: Any]?, chosen: Set<String>) -> [String: Any]? {
        guard var kept = settings else { return nil }
        for key in inputDefaultKeys where !chosen.contains(key) { kept.removeValue(forKey: key) }
        return kept
    }

    /// The defaults, filled only where the kit's kept settings have none:
    /// Easy and Walk in for me for every input (as the kit does); Skip the
    /// demo fight and Pause when I leave the pad only for touch input.
    static func fillDefaults(_ settings: inout [String: Any], pauseOnLeave: Bool, touch: Bool) {
        if settings["fightControls"] == nil { settings["fightControls"] = "easy" }
        if settings["walkIn"] == nil { settings["walkIn"] = true }
        guard touch else { return }
        if settings["skipDemo"] == nil { settings["skipDemo"] = true }
        settings["pauseOnLeave"] = pauseOnLeave
    }
}

/// Settings, Warnings on the phone speaker: the kit's calls on the speaker
/// route, and whether the telegraph buzz fires.
enum ArcadeSpeakerWarnings: String, CaseIterable {
    case buzzAndWords, buzzOnly, everyCall, off

    var label: String {
        switch self {
        case .buzzAndWords: return "Buzz, and words when quiet"
        case .buzzOnly: return "Buzz only"
        case .everyCall: return "Every call"
        case .off: return "Off"
        }
    }

    /// The kit's calls choice for the speaker route.
    var calls: String {
        switch self {
        case .buzzAndWords: return "alerts"
        case .buzzOnly, .off: return "off"
        case .everyCall: return "all"
        }
    }

    var buzz: Bool { self != .off }
}

// MARK: - The trace for "How the game ran"

/// Touch evidence for her next session: the last 300 gestures and duds,
/// the pad taken and let go, VoiceOver's activate, the watchdog and the
/// auto-pauses, counts per gesture and per dud reason, and the kit's own
/// speech trace (start, end, cutBy, class, route) as it sends it.
struct ArcadeTouchLog {
    static let limit = 300

    private(set) var trace: [String] = []
    private(set) var gestureCounts: [String: Int] = [:]
    private(set) var dudCounts: [String: Int] = [:]
    private(set) var padTimes: [String] = []
    private(set) var padOn = 0
    private(set) var padOff = 0
    var activates = 0
    var watchdogFires = 0
    var autoPauses = 0
    private(set) var kitSpeech: [String] = []

    static func seconds(_ value: Double) -> String { String(format: "%.2f s", value) }

    mutating func note(gesture report: ArcadeGestureReport, seconds: Double, held: Bool, tier: String) {
        var name = report.key + (report.direction.map { " " + $0.rawValue } ?? "")
        if report.fromHold { name += " from a block" }
        gestureCounts[name, default: 0] += 1
        let result = name + ": " + ArcadeGestureWords.action(report.action, say: report.say)
        let parts: [String] = [Self.seconds(seconds), "\(report.fingers) finger", report.zone ?? "-", "\(Int(report.ms.rounded())) ms",
                               String(format: "%.1f pt", report.travel), result, held ? "held" : "not held", report.mode, tier]
        add(parts.joined(separator: " | "))
    }

    mutating func note(dud: ArcadeDudReport, seconds: Double, held: Bool, tier: String) {
        dudCounts[dud.reason.rawValue, default: 0] += 1
        let parts: [String] = [Self.seconds(seconds), "\(dud.fingers) finger", dud.zone ?? "-", "\(Int(dud.ms.rounded())) ms",
                               String(format: "%.1f pt", dud.travel), "dud " + dud.reason.rawValue, held ? "held" : "not held", dud.mode, tier]
        add(parts.joined(separator: " | "))
    }

    mutating func note(pad on: Bool, seconds: Double, how: String) {
        if on { padOn += 1 } else { padOff += 1 }
        let way = how.isEmpty ? "" : " (\(how))"
        padTimes.append((on ? "on " : "off ") + Self.seconds(seconds) + way)
        if padTimes.count > 40 { padTimes.removeFirst(padTimes.count - 40) }
    }

    /// The kit's trace as its telemetry ticks carry it (`trace`: the speech
    /// lines and the mode, screen and pad events since the last tick), kept
    /// to the last 300.
    mutating func appendKitTrace(_ entries: [Any]) {
        kitSpeech += entries.map { (entry: Any) -> String in
            guard let row = entry as? [String: Any] else { return String(String(describing: entry).prefix(160)) }
            return row.keys.sorted().map { (key: String) -> String in
                key + "=" + String(String(describing: row[key] ?? "").prefix(80))
            }.joined(separator: " ")
        }
        if kitSpeech.count > Self.limit { kitSpeech.removeFirst(kitSpeech.count - Self.limit) }
    }

    private mutating func add(_ line: String) {
        trace.append(line)
        if trace.count > Self.limit { trace.removeFirst(trace.count - Self.limit) }
    }

    /// The short part (it leads, so a report cut to size keeps it).
    func summary() -> [String] {
        var lines: [String] = []
        lines.append("Pad: taken \(padOn), let go \(padOff). VoiceOver's activate on the pad: \(activates). Pad isn't held lines: \(watchdogFires). Paused on leaving the pad: \(autoPauses).")
        if !padTimes.isEmpty { lines.append("Pad times: " + padTimes.joined(separator: ", ") + ".") }
        let gestures = gestureCounts.keys.sorted().compactMap { key in gestureCounts[key].map { "\(key) \($0)" } }
        lines.append("Gestures: " + (gestures.isEmpty ? "none" : gestures.joined(separator: ", ")) + ".")
        let duds = dudCounts.keys.sorted().compactMap { key in dudCounts[key].map { "\(key) \($0)" } }
        lines.append("Touches that did nothing: " + (duds.isEmpty ? "none" : duds.joined(separator: ", ")) + ".")
        return lines
    }

    /// The long part (it goes last).
    func traces() -> [String] {
        var lines: [String] = []
        if !trace.isEmpty {
            lines.append("Gesture trace (the last \(trace.count)):")
            lines += trace
        }
        if !kitSpeech.isEmpty {
            lines.append("Kit trace, speech and events (the last \(kitSpeech.count)):")
            lines += kitSpeech
        }
        return lines
    }
}
