import Foundation
import JavaScriptCore

// MARK: - The one doorway to the matcher (Tellavision Follow along, Nov 14 2026)
//
// Design Part 1, condition 2: the phone keeps the matcher behind one small
// doorway, so Apple's ShazamKit could replace it on iPhone later. Today the
// matcher is syncprint.js (Sources/syncprint.js, an exact copy of the
// library; FollowAlongTests checks its checksum), run in JavaScriptCore.
//
// JavaScriptCore inside an app has no JIT, so:
// - sound goes in one typed array per clip, copied in bulk, never one
//   number at a time;
// - every call runs on one background queue (FollowAlongAudio's engine
//   queue), never on the main thread. This class is not thread-safe: make
//   it, and use it, on that one queue only;
// - the lines and the spoken record live inside JavaScript and are handed
//   back by reference, so a two-hour film's lines are converted once.
//
// Foundation and JavaScriptCore only, so the tests run it in real
// JavaScriptCore on the build Mac.

/// What the phone needs from a matcher. Times are seconds: `now` and clip
/// starts on the phone's audio clock, film times in fingerprint seconds.
protocol FollowMatching: AnyObject {
    /// How long the fingerprint is.
    var printSeconds: Double { get }
    /// The lines to plan from, with their times moved into fingerprint seconds.
    func setCues(_ cues: [FollowCue], offset: Double)
    /// Compares a clip with the fingerprint and tells the tracker what it found.
    func check(_ clip: [Int16], clipStart: Double, now: Double) -> FollowCheck
    /// The tracker's state now. Reading it clears its "just jumped" flag.
    func state(now: Double) -> FollowTrackerState
    /// When to listen next, and for how long.
    func nextListen(now: Double) -> FollowListen
    /// Check at the next chance instead of waiting for the next turn.
    func hurry()
    /// Forget where the film was: look for it afresh (Start, Listen again).
    func reset()
    /// The line to say now, if any. `shift` moves the film time on (the
    /// output delay and her timing nudge), so a line starts that much early.
    func plan(_ state: FollowTrackerState, shift: Double, options: FollowPlanOptions) -> FollowPlan
    /// A line was said (or started), at `filmSec` in fingerprint seconds.
    func spoke(_ id: String, now: Double, filmSec: Double)
    /// A line that never started is not counted as said.
    func forget(_ id: String)
}

final class FollowAlongEngine: FollowMatching {
    enum Failure: Error, Equatable {
        /// syncprint.js would not load.
        case script(String)
        /// The fingerprint bytes are damaged or not a fingerprint.
        case print
        /// The matcher or the tracker could not be made.
        case matcher(String)
    }

    /// sha256 of Sources/syncprint.js. The server keeps the same file and the
    /// same checksum; FollowAlongTests fails when the copy changes alone.
    static let scriptSHA256 = "2e2f576226814db72b6bcb7be0179a1d241ac7837e709d1375416a7f41139468"
    static let sampleRate = 8000.0

    private let context: JSContext
    private let library: JSValue
    private var matcher: JSValue?
    private var tracker: JSValue?
    private var allCues: JSValue?
    private var importantCues: JSValue?
    private var spoken: JSValue?
    private(set) var printSeconds = 0.0
    /// The last JavaScript exception, for the diagnostics trail.
    private(set) var lastError: String?

    /// The library shipped inside the app (the build copies .js files as
    /// resources; claude-native-check.yml checks it is in the app).
    static func bundledScript(_ bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "syncprint", withExtension: "js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    init(script: String) throws {
        let started: JSContext? = JSContext()
        guard let made = started else { throw Failure.script("JavaScriptCore did not start") }
        made.name = "Follow along"
        made.exception = nil
        _ = made.evaluateScript(script)
        let raised: JSValue? = made.exception
        if let thrown = raised, !thrown.isUndefined, !thrown.isNull {
            let words: String? = thrown.toString()
            throw Failure.script(words ?? "the script stopped")
        }
        let found: JSValue? = made.objectForKeyedSubscript("SyncPrint")
        guard let api = found, api.isObject else { throw Failure.script("SyncPrint is missing") }
        context = made
        library = api
    }

    /// syncprint's version, for the report and the trail.
    var version: String {
        text(library, "VERSION") ?? ""
    }

    /// Reads the fingerprint (its own checksum is checked inside decode) and
    /// makes the matcher and the tracker. A two-hour film builds its lookup
    /// table here, once: a second or so without the JIT, and some 15 to 30 MB.
    func load(print bytes: Data, trackerOptions: [String: Any] = [:]) throws {
        guard let array = uint8Array(bytes) else { throw Failure.print }
        guard let decoded = invoke(library, "decode", [array]), decoded.isObject else { throw Failure.print }
        guard let made = invoke(library, "createMatcher", [decoded]), made.isObject else {
            throw Failure.matcher(lastError ?? "createMatcher gave nothing")
        }
        guard let follower = invoke(library, "createTracker", [trackerOptions]), follower.isObject else {
            throw Failure.matcher(lastError ?? "createTracker gave nothing")
        }
        matcher = made
        tracker = follower
        printSeconds = number(made, "durationSec") ?? 0
        let record: JSValue? = JSValue(newObjectIn: context)
        spoken = record
        // The decoded copy and the bytes are no longer needed.
        JSGarbageCollect(context.jsGlobalContextRef)
    }

    // MARK: The doorway

    func setCues(_ cues: [FollowCue], offset: Double) {
        func object(_ cue: FollowCue) -> [String: Any] {
            var made: [String: Any] = [
                "id": cue.id,
                "startSec": cue.startSec - offset,
                "endSec": cue.endSec - offset,
                "text": cue.text,
                "importance": cue.importance,
            ]
            if let short = cue.shortText, !short.isEmpty { made["shortText"] = short }
            return made
        }
        let every: [[String: Any]] = cues.map { object($0) }
        let important: [[String: Any]] = cues.filter { $0.importance >= 2 }.map { object($0) }
        allCues = JSValue(object: every, in: context)
        importantCues = JSValue(object: important, in: context)
    }

    func check(_ clip: [Int16], clipStart: Double, now: Double) -> FollowCheck {
        var outcome = FollowCheck()
        outcome.clipSec = Double(clip.count) / Self.sampleRate
        outcome.clipDb = FollowLoudness.db(clip)
        outcome.startMono = clipStart
        guard let matcher, let tracker else {
            outcome.reason = "not ready"
            return outcome
        }
        let began = ProcessInfo.processInfo.systemUptime
        var expectation: Any = [String: Any]()
        if let expected = invoke(tracker, "expect", [clipStart]) { expectation = expected }
        guard let samples = int16Array(clip),
              let result = invoke(matcher, "match", [samples, expectation]), result.isObject else {
            outcome.millis = (ProcessInfo.processInfo.systemUptime - began) * 1000
            invoke(tracker, "onMiss", [clipStart, outcome.clipSec, [String: Any]()])
            return outcome
        }
        outcome.millis = (ProcessInfo.processInfo.systemUptime - began) * 1000
        outcome.found = flag(result, "found") ?? false
        outcome.filmSec = number(result, "filmSec")
        outcome.reason = text(result, "reason") ?? "error"
        outcome.expectQuiet = flag(result, "expectQuiet")
        outcome.confidence = number(result, "confidence") ?? 0
        invoke(tracker, "onMatch", [result, clipStart, now])
        return outcome
    }

    func state(now: Double) -> FollowTrackerState {
        guard let value = invoke(tracker, "state", [now]), value.isObject else { return FollowTrackerState() }
        var state = FollowTrackerState()
        state.status = FollowTrackerState.Status(rawValue: text(value, "status") ?? "") ?? .searching
        state.filmSec = number(value, "filmSec")
        state.sinceLastFixSec = number(value, "sinceLastFixSec")
        state.justJumped = flag(value, "justJumped") ?? false
        state.lastJumpSec = number(value, "lastJumpSec") ?? 0
        state.lastBackJumpMono = number(value, "lastBackJumpMono")
        state.lastBackJumpFilmSec = number(value, "lastBackJumpFilmSec")
        state.misses = Int(number(value, "misses") ?? 0)
        state.doubt = flag(value, "doubt") ?? false
        return state
    }

    func nextListen(now: Double) -> FollowListen {
        guard let value = invoke(tracker, "nextListen", [now]), value.isObject else {
            return FollowListen(wait: 1, clip: 8)
        }
        return FollowListen(wait: number(value, "waitSec") ?? 1, clip: number(value, "clipSec") ?? 8)
    }

    func hurry() {
        invoke(tracker, "hurry", [])
    }

    func reset() {
        invoke(tracker, "reset", [])
    }

    func plan(_ state: FollowTrackerState, shift: Double, options: FollowPlanOptions) -> FollowPlan {
        guard let film = state.filmSec else { return .waiting(1, "not locked") }
        let chosen = options.importantOnly ? importantCues : allCues
        guard let cues = chosen else { return .waiting(1, "no lines") }
        var now: [String: Any] = ["status": state.status.rawValue, "filmSec": film + shift]
        if let mono = state.lastBackJumpMono { now["lastBackJumpMono"] = mono }
        if let back = state.lastBackJumpFilmSec { now["lastBackJumpFilmSec"] = back }
        var choices: [String: Any] = [
            "secPerChar": options.secPerChar,
            "leadSec": options.leadSec,
            "toleranceSec": options.toleranceSec,
        ]
        if let spoken { choices["spoken"] = spoken }
        guard let answer = invoke(library, "planCues", [cues, now, choices]), answer.isObject else {
            return .waiting(1, "error")
        }
        let action = text(answer, "action") ?? "wait"
        if action == "speak", let id = text(answer, "id"), let words = text(answer, "text"), !words.isEmpty {
            var plan = FollowPlan(action: .speak)
            plan.id = id
            plan.text = words
            plan.short = flag(answer, "short") ?? false
            plan.estSec = number(answer, "estSec") ?? 0
            plan.waitSec = 0
            plan.reason = text(answer, "reason") ?? ""
            return plan
        }
        return .waiting(number(answer, "waitSec") ?? 1, text(answer, "reason") ?? "")
    }

    func spoke(_ id: String, now: Double, filmSec: Double) {
        let record: [String: Any] = ["monoSec": now, "filmSec": filmSec]
        spoken?.setValue(record, forProperty: id)
    }

    func forget(_ id: String) {
        _ = spoken?.deleteProperty(id)
    }

    /// Makes a fingerprint from 8 kHz sound, the server's way. The tests use
    /// it to fingerprint a made-up film; the app never does.
    func fingerprint(_ samples: [Int16]) -> Data? {
        guard let input = int16Array(samples),
              let made = invoke(library, "fingerprint", [input]), made.isObject,
              let encoded = invoke(library, "encode", [made]), encoded.isObject else { return nil }
        return bytes(of: encoded)
    }

    // MARK: JavaScript plumbing

    /// Calls `method` on `target`. nil when the call threw (the message is
    /// kept in lastError) or there is no target.
    @discardableResult
    private func invoke(_ target: JSValue?, _ method: String, _ arguments: [Any]) -> JSValue? {
        guard let target else { return nil }
        context.exception = nil
        let result: JSValue? = target.invokeMethod(method, withArguments: arguments)
        let raised: JSValue? = context.exception
        if let thrown = raised, !thrown.isUndefined, !thrown.isNull {
            let words: String? = thrown.toString()
            lastError = words ?? "a JavaScript error"
            context.exception = nil
            return nil
        }
        return result
    }

    /// A clip as one Int16Array: made once, filled with one copy.
    private func int16Array(_ samples: [Int16]) -> JSValue? {
        let ctx = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard let object = JSObjectMakeTypedArray(ctx, kJSTypedArrayTypeInt16Array, samples.count, &exception),
              exception == nil else { return nil }
        if !samples.isEmpty {
            guard let target = JSObjectGetTypedArrayBytesPtr(ctx, object, &exception), exception == nil else { return nil }
            samples.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                if let base = raw.baseAddress { target.copyMemory(from: base, byteCount: raw.count) }
            }
        }
        let value: JSValue? = JSValue(jsValueRef: object, in: context)
        return value
    }

    /// The fingerprint as one Uint8Array, filled with one copy.
    private func uint8Array(_ data: Data) -> JSValue? {
        let ctx = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard let object = JSObjectMakeTypedArray(ctx, kJSTypedArrayTypeUint8Array, data.count, &exception),
              exception == nil else { return nil }
        if !data.isEmpty {
            guard let target = JSObjectGetTypedArrayBytesPtr(ctx, object, &exception), exception == nil else { return nil }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                if let base = raw.baseAddress { target.copyMemory(from: base, byteCount: raw.count) }
            }
        }
        let value: JSValue? = JSValue(jsValueRef: object, in: context)
        return value
    }

    /// The bytes of a typed array, copied out.
    private func bytes(of value: JSValue) -> Data? {
        let ctx = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard let object = JSValueToObject(ctx, value.jsValueRef, &exception), exception == nil else { return nil }
        let length = JSObjectGetTypedArrayByteLength(ctx, object, &exception)
        guard exception == nil, length > 0,
              let source = JSObjectGetTypedArrayBytesPtr(ctx, object, &exception), exception == nil else { return nil }
        return Data(bytes: source, count: length)
    }

    private func number(_ object: JSValue, _ key: String) -> Double? {
        let found: JSValue? = object.forProperty(key)
        guard let value = found, value.isNumber else { return nil }
        let result = value.toDouble()
        return result.isFinite ? result : nil
    }

    private func flag(_ object: JSValue, _ key: String) -> Bool? {
        let found: JSValue? = object.forProperty(key)
        guard let value = found, value.isBoolean else { return nil }
        return value.toBool()
    }

    private func text(_ object: JSValue, _ key: String) -> String? {
        let found: JSValue? = object.forProperty(key)
        guard let value = found, !value.isUndefined, !value.isNull else { return nil }
        let words: String? = value.toString()
        return words
    }
}
