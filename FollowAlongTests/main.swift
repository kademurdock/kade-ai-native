import AVFoundation
import CryptoKit
import Foundation
import JavaScriptCore

// Nov 14 2026: Tellavision "Follow along" (TELLAVISION_SYNC_DESIGN_2026-11-13.md,
// Parts 5.3 to 5.5). The phone listens to a film on her TV, finds its place
// with syncprint, and speaks the description lines in the gaps.
//
// What this proves on the build Mac, with no phone: every sentence is worded
// right, the track reads correctly, the rules react rightly to lock, pause,
// loss, skip, call and end, the lines held for a pause, the settings, the
// voice speed, the 16-second memory, the report is numbers only, the copy of
// syncprint.js is the one the server ships (its checksum), and syncprint.js
// itself runs in real JavaScriptCore: a made-up film is fingerprinted, a noisy
// clip is found at the right second, the tracker locks, and the planner picks
// the right line. Source checks keep the sheet free of lazy containers and the
// microphone sound off disk and off the network.
//
// run-follow-along-tests.sh passes the repository folder. With
// FOLLOW_ALONG_TIMING_ONLY=1 it only times the matcher (the script runs that
// a second time with JavaScriptCore's JIT switched off, as inside the app).
//
// Nov 14 2026 review: the loop (FollowAlongLoop.swift) runs here too, on the
// made-up film with a clock the test moves (Start again says lines again,
// queued sound is not each checked again, an ended film's minutes count), and
// the microphone capture (FollowAlongCapture.swift) turns test tones into
// 8 kHz through a change of format.
//
// The contract check (Nov 14 2026, evening): the website's real answers
// (FollowAlongTests/server-samples) are read by the app's own code, and the
// server's real fingerprint finds 8 seconds of the film's own sound.

// Line by line even into a file, so a crash still shows where it stopped.
setvbuf(stdout, nil, _IOLBF, 0)

var count = 0

func section(_ name: String) {
    print("Follow along tests: \(name)")
}

/// Text for a GitHub annotation line (the check's results can then be read
/// without a token: a public repository's annotations are open to anyone).
func annotation(_ text: String) -> String {
    text.replacingOccurrences(of: "%", with: "%25")
        .replacingOccurrences(of: "\r", with: "%0D")
        .replacingOccurrences(of: "\n", with: "%0A")
}

func fatal(_ message: String) -> Never {
    print("FAILED: \(message)")
    print("::error title=Follow along tests::FAILED: \(annotation(message))")
    exit(1)
}

func check(_ ok: Bool, _ label: String) {
    if !ok { fatal(label) }
    count += 1
}

func near(_ a: Double?, _ b: Double, _ within: Double) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= within
}

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let rootURL = URL(fileURLWithPath: root, isDirectory: true)
let timingOnly = ProcessInfo.processInfo.environment["FOLLOW_ALONG_TIMING_ONLY"] == "1"
let jitOff = (ProcessInfo.processInfo.environment["JSC_useJIT"] ?? "").lowercased() == "false"

func readText(_ relative: String) -> String {
    let url = rootURL.appendingPathComponent(relative)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        fatal("could not read \(relative) under \(root)")
    }
    return text
}

func readData(_ relative: String) -> Data {
    let url = rootURL.appendingPathComponent(relative)
    guard let data = try? Data(contentsOf: url) else {
        fatal("could not read \(relative) under \(root)")
    }
    return data
}

// MARK: - A made-up film (the same steps as the Node prototype)

/// xorshift32: the same numbers as the JavaScript prototype's.
struct XorShift {
    var state: UInt32
    init(_ seed: UInt32) { state = seed == 0 ? 1 : seed }
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return Double(state) / 4_294_967_296
    }
}

/// Tones that change every tenth to third of a second, like busy music, at
/// 8 kHz, with a little hiss.
func madeUpFilm(seconds: Double, seed: UInt32) -> [Int16] {
    var random = XorShift(seed)
    let rate = 8000.0
    let total = Int(seconds * rate)
    var mix = [Double](repeating: 0, count: total)
    var start = 0
    while start < total {
        let length = Int((0.12 + random.next() * 0.25) * rate)
        let low = 350 + random.next() * 2900
        let high = min(3300, low * (1.25 + random.next() * 0.35))
        let loudness = 0.25 + random.next() * 0.35
        let attack = 0.01 * rate
        let release = 0.03 * rate
        var index = 0
        while index < length && start + index < total {
            var gain = 1.0
            if Double(index) < attack { gain = Double(index) / attack }
            let left = Double(length - 1 - index)
            if left < release { gain = min(gain, left / release) }
            let phase = 2 * Double.pi * Double(index) / rate
            mix[start + index] += loudness * gain * (sin(phase * low) + 0.6 * sin(phase * high))
            index += 1
        }
        start += length
    }
    var out = [Int16](repeating: 0, count: total)
    for index in 0..<total {
        let value = mix[index] * 0.5 + (random.next() - 0.5) * 0.004
        out[index] = Int16(max(-32767, min(32767, (value * 32767).rounded())))
    }
    return out
}

/// What the phone's microphone hears: the film quieter, with room noise.
func heardClip(_ film: [Int16]?, from startSec: Double, seconds: Double, gain: Double, noise: Double, seed: UInt32) -> [Int16] {
    var random = XorShift(seed)
    let first = Int(startSec * 8000)
    let total = Int(seconds * 8000)
    var out = [Int16](repeating: 0, count: total)
    for index in 0..<total {
        var value = 0.0
        if let film { value = Double(film[first + index]) / 32767 * gain }
        value += (random.next() - 0.5) * 2 * noise
        out[index] = Int16(max(-32767, min(32767, (value * 32767).rounded())))
    }
    return out
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Helpers for the loop and the capture

/// A clock the test moves by hand; the loop reads it on its own queue.
final class TestClock {
    private let lock = NSLock()
    private var value: Double

    init(_ start: Double) {
        value = start
    }

    var now: Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ time: Double) {
        lock.lock()
        value = time
        lock.unlock()
    }
}

/// What a loop said, collected from its queue.
final class Said {
    private let lock = NSLock()
    private var items: [FollowLoopOutput] = []

    func add(_ item: FollowLoopOutput) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    /// Everything said since the last take.
    func take() -> [FollowLoopOutput] {
        lock.lock()
        let taken = items
        items = []
        lock.unlock()
        return taken
    }
}

/// A matcher that answers as the test says, and notes each check.
final class ScriptedMatcher: FollowMatching {
    var printSeconds = 600.0
    var listen = FollowListen(wait: 0, clip: 2)
    var tracker = FollowTrackerState()
    /// Where each checked clip began, on the clock.
    private(set) var checks: [Double] = []
    private(set) var resets = 0

    func setCues(_ cues: [FollowCue], offset: Double) {}

    func check(_ clip: [Int16], clipStart: Double, now: Double) -> FollowCheck {
        checks.append(clipStart)
        var result = FollowCheck()
        result.reason = "no match"
        result.clipSec = Double(clip.count) / 8000
        result.startMono = clipStart
        return result
    }

    func state(now: Double) -> FollowTrackerState { tracker }
    func nextListen(now: Double) -> FollowListen { listen }
    func hurry() {}
    func reset() { resets += 1 }
    func plan(_ state: FollowTrackerState, shift: Double, options: FollowPlanOptions) -> FollowPlan { .waiting(1, "scripted") }
    func spoke(_ id: String, now: Double, filmSec: Double) {}
    func forget(_ id: String) {}
}

/// A tracker and planner scripted for the check before a line (syncprint's
/// README loop). The film plays at real speed from film second 10 at clock
/// 2000; one line, "k1", may be said from film second 30 to 40 (clock 2020
/// to 2030). Each check answers with the next scripted result and keeps
/// the misses as syncprint's tracker does: two in a row, and it holds.
final class PreLineMatcher: FollowMatching {
    enum Answer { case silence, quietFilm, noMatch, found }

    var printSeconds = 600.0
    var answers: [Answer]
    /// Misses in a row, and the clip start of the last good fix.
    var misses = 0
    var lastFix = 2000.0
    /// After one miss, the tracker's own 8 second check at once (its schedule).
    var recheckAtOnce = true
    /// From `doubtFrom` to `doubtUntil` a doubtful match waits for its second
    /// opinion: the tracker holds.
    var doubtFrom = 0.0
    var doubtUntil = 0.0
    /// Where each checked clip began, on the clock, and how long it was.
    private(set) var checks: [Double] = []
    private(set) var lengths: [Double] = []
    /// How often the loop asked for a check at the next chance.
    private(set) var hurries = 0
    private var said: Set<String> = []

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    func film(_ now: Double) -> Double { 10 + (now - 2000) }

    func setCues(_ cues: [FollowCue], offset: Double) {}

    func check(_ clip: [Int16], clipStart: Double, now: Double) -> FollowCheck {
        checks.append(clipStart)
        lengths.append(Double(clip.count) / 8000)
        var result = FollowCheck()
        result.clipSec = Double(clip.count) / 8000
        result.startMono = clipStart
        result.expectQuiet = false
        result.clipDb = -30
        let answer: Answer = answers.isEmpty ? .noMatch : answers.removeFirst()
        switch answer {
        case .silence:
            result.reason = "silence"
            result.clipDb = -70
            misses += 1
        case .quietFilm:
            // The film itself is nearly silent here: syncprint excuses the miss.
            result.reason = "silence"
            result.expectQuiet = true
            result.clipDb = -70
        case .noMatch:
            result.reason = "no match"
            misses += 1
        case .found:
            result.found = true
            result.reason = "ok"
            result.filmSec = film(clipStart)
            misses = 0
            lastFix = clipStart
        }
        return result
    }

    func state(now: Double) -> FollowTrackerState {
        var state = FollowTrackerState()
        let doubtful = now >= doubtFrom && now < doubtUntil
        state.status = misses >= 2 || doubtful ? .holding : .locked
        state.filmSec = film(now)
        state.sinceLastFixSec = now - lastFix
        state.misses = misses
        state.doubt = doubtful
        return state
    }

    func nextListen(now: Double) -> FollowListen {
        FollowListen(wait: misses == 1 && recheckAtOnce ? 0 : 999, clip: 8)
    }

    func hurry() { hurries += 1 }
    func reset() { said = [] }

    func plan(_ state: FollowTrackerState, shift: Double, options: FollowPlanOptions) -> FollowPlan {
        guard state.status == .locked, let at = state.filmSec, at >= 30, at <= 40, !said.contains("k1") else {
            return .waiting(1, "scripted")
        }
        var plan = FollowPlan(action: .speak)
        plan.id = "k1"
        plan.text = "A kite climbs."
        plan.estSec = 1
        return plan
    }

    func spoke(_ id: String, now: Double, filmSec: Double) { said.insert(id) }
    func forget(_ id: String) { said.remove(id) }
}

/// Collects what the microphone capture hands on.
final class SoundCollector: FollowSoundSink {
    var samples: [Int16] = []
    var ends: [Double] = []

    func receive(_ samples: [Int16], endingAt end: Double) {
        self.samples.append(contentsOf: samples)
        ends.append(end)
    }
}

/// The text of one function in a source file, from its signature to its
/// closing brace.
func body(_ signature: String, in text: String) -> String {
    guard let start = text.range(of: signature) else { fatal("\(signature) is missing") }
    var depth = 0
    var opened = false
    var index = start.lowerBound
    while index < text.endIndex {
        let char = text[index]
        if char == "{" {
            depth += 1
            opened = true
        } else if char == "}" {
            depth -= 1
            if opened && depth == 0 { return String(text[start.lowerBound...index]) }
        }
        index = text.index(after: index)
    }
    fatal("\(signature) never ends")
}

func isPrepared(_ output: FollowLoopOutput) -> Bool {
    if case .prepared = output { return true }
    return false
}

func spokenId(_ output: FollowLoopOutput) -> String? {
    if case .speak(let id, _) = output { return id }
    return nil
}

/// A status sentence's words, and whether Follow along stops after it.
func sentence(_ output: FollowLoopOutput) -> (text: String, stops: Bool)? {
    if case .sentence(let text, _, let stops) = output { return (text, stops) }
    return nil
}

func reported(_ output: FollowLoopOutput) -> FollowReport? {
    if case .report(let report) = output { return report }
    return nil
}

// MARK: - Timing only (the second run, JIT switched off)

if timingOnly {
    let script = readText("Sources/syncprint.js")
    guard let maker = try? FollowAlongEngine(script: script) else {
        print("Follow along timing: syncprint.js did not load")
        exit(1)
    }
    let film = madeUpFilm(seconds: 600, seed: 0x2468ACE)
    let began = Date()
    guard let bytes = maker.fingerprint(film) else {
        print("Follow along timing: no fingerprint (\(maker.lastError ?? "no error"))")
        exit(1)
    }
    let printMillis = Date().timeIntervalSince(began) * 1000
    guard let engine = try? FollowAlongEngine(script: script) else { exit(1) }
    let loadBegan = Date()
    do { try engine.load(print: bytes) } catch {
        print("Follow along timing: the fingerprint did not load")
        exit(1)
    }
    let loadMillis = Date().timeIntervalSince(loadBegan) * 1000
    var times: [Double] = []
    for (index, second) in [123.4, 377.0, 512.6].enumerated() {
        let clip = heardClip(film, from: second, seconds: 8, gain: 0.5, noise: 0.05, seed: UInt32(7 + index))
        let result = engine.check(clip, clipStart: 1000 + Double(index) * 30, now: 1008 + Double(index) * 30)
        times.append(result.millis)
        if !result.found { print("Follow along timing: a clip at \(second) s was not found") }
    }
    let label = jitOff ? "JIT off" : "JIT on"
    let line = "10 minute film, fingerprint \(Int(printMillis)) ms, load \(Int(loadMillis)) ms, 8 s matches \(times.map { String(Int($0)) }.joined(separator: ", ")) ms"
    print("Follow along timing (\(label)): \(line)")
    print("::notice title=Follow along timing \(label)::\(annotation(line))")
    exit(0)
}

// MARK: - The exact words (design 5.3)

check(FollowWords.listening == "Listening for your film.", "1: listening")
check(FollowWords.stillListening == "Still listening. Turn the TV up, or move the phone closer.", "2: still listening")
check(FollowWords.cantFind == "I can't find this film yet. Check that it is playing, and that it is the same film.", "3: can't find")
check(FollowWords.found(12 * 60 + 40) == "Found your place: 12 minutes in.", "4: found your place, minutes")
check(FollowWords.found(42) == "Found your place: the beginning.", "4: in the first minute, the beginning")
check(FollowWords.covers(startSec: 0, endSec: 5400, filmSeconds: 7300) == "This track covers the first 1 hour 30 minutes.", "5: a track for the first part")
check(FollowWords.covers(startSec: 0, endSec: 7300, filmSeconds: 7300) == nil, "5: a whole film says nothing about parts")
check(FollowWords.covers(startSec: 5400, endSec: 7300, filmSeconds: 7300) == "This track covers from 1 hour 30 minutes to the end.", "5: a track for the last part")
check(FollowWords.covers(startSec: 1800, endSec: 3600, filmSeconds: 7300) == "This track covers from 30 minutes to 1 hour.", "5: a track for a middle part")
check(FollowWords.paused == "The film seems to be paused. I will carry on when it plays.", "6: paused")
check(FollowWords.lost == "I lost the film. I am listening for it.", "7: lost")
check(FollowWords.backInStep(47 * 60 + 5) == "Back in step: 47 minutes in.", "8: back in step")
check(FollowWords.skipped(to: 3900, ahead: true) == "You skipped ahead to 1 hour 5 minutes.", "9: skipped ahead")
check(FollowWords.skipped(to: 31 * 60 + 59, ahead: false) == "You went back to 31 minutes.", "9: went back")
check(FollowWords.skipped(to: 20, ahead: false) == "You went back to the beginning.", "9: back to the beginning")
check(FollowWords.descriptionsPaused == "Descriptions paused." && FollowWords.descriptionsOn == "Descriptions on.", "10: paused and on")
check(FollowWords.earbudsGone == "Earbuds disconnected. Descriptions paused.", "11: earbuds")
check(FollowWords.ended == "The film has ended. Follow along is off.", "12: ended")
check(FollowWords.stopped == "Follow along is off. The microphone is off.", "13: stop")
check(FollowWords.noFilm == "I have not heard the film for 10 minutes. Follow along is off.", "14: ten minutes")
check(FollowWords.whereAmI(47 * 60) == "47 minutes in, in step.", "15: where am I, in step")
check(FollowWords.whereAmI(nil) == "Not in step. Listening.", "15: where am I, not in step")
check(FollowWords.whereAmI(10) == "The beginning, in step.", "15: where am I at the beginning")
check(FollowWords.callNotification == "Follow along stopped for a call. Open Kade-AI to carry on.", "16: the call notification")
check(FollowWords.stoppedByCall == "Stopped by a call.", "16: the screen after a call")
check(FollowWords.micDenied == "Kade-AI is not allowed to use the microphone. Open Settings, then Kade-AI, and turn Microphone on.", "17: microphone not allowed")
check(FollowWords.couldNotStart == "Follow along could not start on this phone.", "failure: JavaScript")
check(FollowWords.micBusy == "The microphone is busy. Try again after your call.", "failure: microphone busy")
check(FollowWords.trackEnds == "This track ends here. Follow along is off.", "failure: a part ends")
check(FollowWords.gone == "The original video is no longer stored, so Follow along can't be made for this copy. Bringing the video in again makes a new described copy that can follow along.", "server: original gone")
check(FollowWords.privacy == "Your phone listens only to find your place in the film. The sound is checked on this phone. It is never saved and never sent anywhere. The microphone stays on until you press Stop or the film ends.", "the privacy sentence")
check(FollowWords.button == "Follow along with my TV", "the button")
check(FollowWords.buttonHint == "Your phone listens for the film on another screen and speaks the descriptions in step.", "the button's hint")
check(FollowWords.paused(held: ["A kite climbs", "She runs back."]) == "The film seems to be paused. Here are the 2 lines I held. A kite climbs. She runs back. I will carry on when it plays.",
      "6, with held lines: read in order, each a sentence")
check(FollowWords.paused(held: ["A kite climbs."]) == "The film seems to be paused. Here is the line I held. A kite climbs. I will carry on when it plays.", "6, with one held line")
check(FollowWords.paused(held: []) == FollowWords.paused, "6, nothing held: the plain sentence")

// Time words.
check(FollowWords.place(0) == "the beginning" && FollowWords.place(59.9) == "the beginning", "the first minute is the beginning")
check(FollowWords.place(60) == "1 minute in" && FollowWords.place(119) == "1 minute in", "1 minute, singular")
check(FollowWords.place(3600) == "1 hour in" && FollowWords.place(7200) == "2 hours in", "whole hours")
check(FollowWords.place(3660) == "1 hour 1 minute in" && FollowWords.place(7500) == "2 hours 5 minutes in", "hours and minutes")
check(FollowWords.clock(.infinity) == "the beginning" && FollowWords.clock(-5) == "the beginning", "a broken time is the beginning")
check(FollowWords.length(5400) == "1 hour 30 minutes" && FollowWords.length(5395) == "1 hour 30 minutes" && FollowWords.length(10) == "1 minute",
      "a length is to the nearest minute, at least one")
check(FollowWords.sentence("A sign reads: Closed") == "A sign reads: Closed." && FollowWords.sentence("Why?") == "Why?", "a line becomes a sentence")

// MARK: - The track (design 5.1)

let sample = readData("FollowAlongTests/sample-track.json")
let track: FollowTrack = {
    do {
        return try FollowTrack.read(sample)
    } catch {
        fatal("the sample track did not read: \(error)")
    }
}()
check(track.format == "kade-follow-track" && track.version == 1, "the format and version")
check(track.job == "sample-job-1" && track.copyVersion == 3 && track.title == "The Kite" && track.language == "en", "the job, copy, title and language")
check(track.filmSeconds == 90 && track.covers == FollowTrack.Span(startSec: 0, endSec: 90), "the film's length and what the track covers")
check(track.print.bytes == 6296 && track.print.sha256 == "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", "the fingerprint's size and checksum, lower case")
check(track.plannedAt?.secPerChar == 0.042 && track.plannedAt?.rate == 1.5, "the server's planned pace")
check(track.credit?.start == "Audio description by Kade-AI." && track.credit?.end == "Described by Kade-AI. More at kademurdock dot com.", "the credits")
check(track.cues.count == 4, "four usable lines; the one with no end is left out")
check(track.cues.map { $0.id } == ["1:1", "2:1", "1:2", "7"], "lines in film order; a number id is read as text")
check(track.cues[0].importance == 3 && track.cues[0].shortText == "A kite climbs." && track.cues[0].fit == "full", "a line's fields")
check(track.cues[2].startSec == 62 && track.cues[2].importance == 1 && track.cues[2].reading, "a number or flag sent as text still counts")
check(track.cues[3].importance == 2 && track.cues[3].shortText == nil, "missing fields take their usual values")
check(track.quiet.count == 3, "quiet gaps; the broken one is left out")
check(track.warning?.hasPrefix("AI descriptions can miss") == true, "the warning")
check(!track.isPart && track.reachesFilmEnd, "a whole-film track")
check(track.printOffset(printSeconds: 90) == 0 && track.endInPrint(printSeconds: 90) == 90, "a whole film's fingerprint starts at 0")

func readTrack(_ json: String) -> Result<FollowTrack, FollowTrack.Problem> {
    do {
        return .success(try FollowTrack.read(Data(json.utf8)))
    } catch let problem as FollowTrack.Problem {
        return .failure(problem)
    } catch {
        return .failure(.notATrack)
    }
}
let goodPrint = #""print": {"format": 1, "bytes": 10, "sha256": "0000000000000000000000000000000000000000000000000000000000000000"}"#
switch readTrack(#"{"format": "something else", "version": 1, "filmSeconds": 10, \#(goodPrint)}"#) {
case .failure(let problem): check(problem == .notATrack, "another format is not a track")
case .success: check(false, "another format is not a track")
}
switch readTrack(#"{"format": "kade-follow-track", "version": 2, "filmSeconds": 10, \#(goodPrint)}"#) {
case .failure(let problem): check(problem == .newerVersion, "a newer track asks for a newer app")
case .success: check(false, "a newer track asks for a newer app")
}
switch readTrack(#"{"format": "kade-follow-track", "version": 1, "filmSeconds": 10}"#) {
case .failure(let problem): check(problem == .noPrint, "a track with no fingerprint is refused")
case .success: check(false, "a track with no fingerprint is refused")
}
switch readTrack("not json") {
case .failure(let problem): check(problem == .notATrack, "broken text is not a track")
case .success: check(false, "broken text is not a track")
}
check(FollowTrack.Problem.newerVersion.words.contains("Update"), "the newer-track words say to update")
switch readTrack(#"{"format": "kade-follow-track", "filmSeconds": 7300, "covers": {"startSec": 5400, "endSec": 7300}, \#(goodPrint), "cues": []}"#) {
case .success(let part):
    check(part.version == 1, "a track with no version is version 1")
    check(part.isPart && part.reachesFilmEnd, "a track for the last part")
    check(part.printOffset(printSeconds: 1900) == 5400, "a part's own fingerprint starts where the part does (the server's contract: covers.startSec)")
    check(part.endInPrint(printSeconds: 1900) == 1900, "the part ends at its fingerprint's end")
    check(part.title == "Your film" && part.language == "en", "a missing title and language")
case .failure: check(false, "a part track reads")
}
switch readTrack(#"{"format": "kade-follow-track", "filmSeconds": 7300, "covers": {"startSec": 5400, "endSec": 7300}, "print": {"bytes": 10, "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "startSec": 5400}}"#) {
case .success(let part): check(part.printOffset(printSeconds: 7300) == 5400, "the server may say where the fingerprint starts")
case .failure: check(false, "a track with print.startSec reads")
}

// MARK: - The rules (design 5.3: lock, pause, loss, skip, end)

func locked(_ film: Double, jumped: Double? = nil) -> FollowTrackerState {
    var state = FollowTrackerState()
    state.status = .locked
    state.filmSec = film
    if let jumped {
        state.justJumped = true
        state.lastJumpSec = jumped
    }
    return state
}

func status(_ status: FollowTrackerState.Status, _ film: Double? = nil) -> FollowTrackerState {
    var state = FollowTrackerState()
    state.status = status
    state.filmSec = film
    return state
}

func found(_ film: Double, db: Double = -30) -> FollowCheck {
    var result = FollowCheck()
    result.found = true
    result.filmSec = film
    result.reason = "ok"
    result.expectQuiet = false
    result.clipDb = db
    return result
}

func missed(_ reason: String, db: Double = -30, expectQuiet: Bool? = false) -> FollowCheck {
    var result = FollowCheck()
    result.reason = reason
    result.expectQuiet = expectQuiet
    result.clipDb = db
    return result
}

do {
    var judge = FollowJudge(now: 0, endSec: 90, part: false)
    check(judge.tick(state: status(.searching), now: 5).isEmpty, "searching: nothing said in the first seconds")
    check(judge.tick(state: status(.searching), now: 20) == [.stillListening], "20 seconds: still listening")
    check(judge.tick(state: status(.searching), now: 30).isEmpty, "said once")
    check(judge.tick(state: status(.searching), now: 60) == [.cantFind], "60 seconds: can't find")
    check(judge.tick(state: status(.searching), now: 70).isEmpty, "said once")
    check(judge.checked(found(47), state: locked(55), now: 75) == [.found(55)], "it locks: found your place")
    check(judge.phase == .inStep, "in step")
    check(judge.tick(state: locked(56), now: 76).isEmpty, "in step: nothing more")
    check(judge.tick(state: status(.searching), now: 400).isEmpty, "no second 20 or 60 second line after it found the film")
}

do {
    var judge = FollowJudge(now: 0, endSec: 7200, part: false)
    _ = judge.checked(found(100), state: locked(108), now: 10)
    check(judge.checked(found(300), state: locked(308, jumped: 192), now: 40) == [.skipped(308, ahead: true)], "a skip ahead is said")
    check(judge.checked(found(200), state: locked(208, jumped: -100), now: 60) == [.skipped(208, ahead: false)], "a skip back is said")
    check(judge.checked(found(205), state: locked(213, jumped: 5), now: 70).isEmpty, "a small correction is not a skip")
    check(judge.checked(found(205), state: locked(213, jumped: -7.9), now: 71).isEmpty, "under 8 seconds is not a skip")
}

do {
    var judge = FollowJudge(now: 0, endSec: 7200, part: false)
    _ = judge.checked(found(100, db: -30), state: locked(108), now: 10)
    check(judge.heard.level == -30, "the film's level in the room is learned from good matches")
    check(judge.checked(missed("silence"), state: locked(130), now: 30).isEmpty, "one quiet check is not a pause")
    check(judge.checked(missed("silence"), state: status(.holding, 131), now: 31) == [.paused], "two quiet checks in a row: paused")
    check(judge.phase == .paused, "paused")
    check(judge.checked(missed("silence"), state: status(.lost), now: 60).isEmpty, "paused, then the tracker gives up: no lost line over the pause")
    check(judge.checked(found(120), state: locked(128, jumped: -40), now: 90) == [.backInStep(128)], "the film plays again: back in step, not a skip")
    check(judge.phase == .inStep, "in step again")
}

do {
    var judge = FollowJudge(now: 0, endSec: 7200, part: false)
    _ = judge.checked(found(100, db: -30), state: locked(108), now: 10)
    check(judge.checked(missed("no match", db: -50), state: locked(130), now: 30).isEmpty, "a quiet miss by the phone's own measure")
    check(judge.checked(missed("no match", db: -50), state: status(.holding, 131), now: 31) == [.paused], "two: paused, even when syncprint did not say silence")
    var noisy = FollowJudge(now: 0, endSec: 7200, part: false)
    _ = noisy.checked(found(100, db: -30), state: locked(108), now: 10)
    _ = noisy.checked(missed("no match", db: -31), state: locked(130), now: 30)
    _ = noisy.checked(missed("no match", db: -29), state: status(.holding, 131), now: 31)
    check(noisy.phase == .inStep, "loud misses (an advert, talking) are not a pause")
    check(noisy.checked(missed("no match", db: -29), state: status(.lost), now: 50) == [.lost], "the tracker gives up: lost the film")
    check(noisy.checked(found(400), state: locked(408, jumped: 250), now: 90) == [.backInStep(408)], "found again after a loss: back in step")
    var quietFilm = FollowJudge(now: 0, endSec: 7200, part: false)
    _ = quietFilm.checked(found(100, db: -30), state: locked(108), now: 10)
    _ = quietFilm.checked(missed("silence", expectQuiet: true), state: locked(130), now: 30)
    _ = quietFilm.checked(missed("silence", expectQuiet: true), state: locked(131), now: 31)
    check(quietFilm.phase == .inStep, "silence where the film itself is quiet is not a pause")
    var mixed = FollowJudge(now: 0, endSec: 7200, part: false)
    _ = mixed.checked(found(100, db: -30), state: locked(108), now: 10)
    _ = mixed.checked(missed("silence"), state: locked(130), now: 30)
    _ = mixed.checked(missed("no match", db: -30), state: locked(131), now: 31)
    _ = mixed.checked(missed("silence"), state: status(.holding, 132), now: 32)
    check(mixed.phase == .inStep, "quiet checks must come in a row")
    var unplaced = FollowJudge(now: 0, endSec: 7200, part: false)
    _ = unplaced.checked(found(100, db: -30), state: locked(108), now: 10)
    _ = unplaced.checked(missed("silence", expectQuiet: nil), state: locked(130), now: 30)
    check(unplaced.checked(missed("silence", expectQuiet: nil), state: status(.holding, 131), now: 31) == [.paused],
          "syncprint's silence counts when no place was expected (its README: expectQuiet not true)")
    var unplacedQuiet = FollowJudge(now: 0, endSec: 7200, part: false)
    _ = unplacedQuiet.checked(found(100, db: -30), state: locked(108), now: 10)
    _ = unplacedQuiet.checked(missed("no match", db: -60, expectQuiet: nil), state: locked(130), now: 30)
    _ = unplacedQuiet.checked(missed("no match", db: -60, expectQuiet: nil), state: status(.holding, 131), now: 31)
    check(unplacedQuiet.phase == .inStep, "the phone's own loudness needs a place where the film should be loud")
}

do {
    var judge = FollowJudge(now: 0, endSec: 90, part: false)
    _ = judge.checked(found(10), state: locked(18), now: 18)
    check(judge.tick(state: locked(89), now: 89).isEmpty, "before the end")
    check(judge.tick(state: status(.holding, 95), now: 95).isEmpty, "holding past the end is not the end (paused near the end)")
    check(judge.tick(state: locked(89.6), now: 96) == [.ended(part: false)], "the end of the film")
    check(judge.tick(state: locked(91), now: 97).isEmpty && judge.phase == .ended, "said once, then nothing")
    var part = FollowJudge(now: 0, endSec: 1900, part: true)
    _ = part.checked(found(1880), state: locked(1888), now: 1888)
    check(part.tick(state: locked(1899.8), now: 1900) == [.ended(part: true)], "the end of a part: this track ends here")
    var silent = FollowJudge(now: 0, endSec: 7200, part: false)
    check(silent.tick(state: status(.searching), now: 599).count <= 2, "not yet")
    check(silent.tick(state: status(.searching), now: 600).contains(.noFilm), "10 minutes with no film: off")
    check(silent.tick(state: status(.searching), now: 601).isEmpty, "said once")
    var later = FollowJudge(now: 0, endSec: 7200, part: false)
    _ = later.checked(found(100), state: locked(108), now: 100)
    check(!later.tick(state: status(.holding, 400), now: 699).contains(.noFilm), "the 10 minutes run from the last time the film was heard")
    check(later.tick(state: status(.lost), now: 700).contains(.noFilm), "10 minutes after the film was last heard: off")
}

// The words that go with each event.
do {
    let found = FollowJudge.words(for: .found(47 * 60), track: track, offset: 0)
    check(found.text == "Found your place: 47 minutes in. Audio description by Kade-AI.", "found: the place, then the opening credit")
    check(found.sound == .rising, "found: two rising notes")
    check(FollowJudge.words(for: .found(30), track: track, offset: 0, firstCredit: false).text == "Found your place: the beginning.", "no credit when it was said already")
    let back = FollowJudge.words(for: .backInStep(600), track: track, offset: 0)
    check(back.text == "Back in step: 10 minutes in." && back.sound == .rising, "back in step: rising notes")
    let paused = FollowJudge.words(for: .paused, track: track, offset: 0, held: ["She runs back."])
    check(paused.text == "The film seems to be paused. Here is the line I held. She runs back. I will carry on when it plays." && paused.sound == .falling,
          "paused: falling notes, then the held line")
    check(FollowJudge.words(for: .lost, track: track, offset: 0).sound == .falling, "lost: falling notes")
    check(FollowJudge.words(for: .skipped(3900, ahead: true), track: track, offset: 0).sound == nil, "a skip has no sound")
    check(FollowJudge.words(for: .ended(part: false), track: track, offset: 0).text
          == "Described by Kade-AI. More at kademurdock dot com. The film has ended. Follow along is off.", "the end: the closing credit, then off")
    check(FollowJudge.words(for: .ended(part: true), track: track, offset: 0).text == "This track ends here. Follow along is off.", "the end of a part")
    check(FollowJudge.words(for: .skipped(100, ahead: true), track: track, offset: 5400).text == "You skipped ahead to 1 hour 31 minutes.",
          "a part's fingerprint seconds become film seconds")
    switch readTrack(#"{"format": "kade-follow-track", "filmSeconds": 7300, "covers": {"startSec": 0, "endSec": 5400}, \#(goodPrint)}"#) {
    case .success(let first):
        let words = FollowJudge.words(for: .found(65), track: first, offset: 0)
        check(words.text == "Found your place: 1 minute in. This track covers the first 1 hour 30 minutes.", "a part says what it covers, once, after locking")
    case .failure: check(false, "a first-part track reads")
    }
}

// MARK: - Lines that do not fit, held for a pause

do {
    var holder = FollowHolder(cues: track.cues, offset: 0)
    holder.moved(to: 49)
    check(holder.sweep(filmSec: 54.4, spoken: [], importantOnly: false).isEmpty, "a window still open (with its half second) is not held")
    let first = holder.sweep(filmSec: 54.6, spoken: [], importantOnly: false)
    check(first.map { $0.id } == ["1:1"], "a window that closed unspoken: held")
    check(holder.sweep(filmSec: 58, spoken: ["2:1"], importantOnly: false).isEmpty, "a spoken line is never held")
    check(holder.sweep(filmSec: 66, spoken: [], importantOnly: true).isEmpty, "important lines only: a least important line is not held")
    check(holder.sweep(filmSec: 81, spoken: [], importantOnly: false).map { $0.id } == ["7"], "the next one")
    check(holder.takeAll().map { $0.id } == ["1:1", "7"] && holder.held.isEmpty, "read in film order, then the list is empty")
    var chime = FollowHolder(cues: [], offset: 0)
    check(chime.mayChime(now: 100) && !chime.mayChime(now: 110) && chime.mayChime(now: 115.1), "never two chimes within 15 seconds")
    var late = FollowHolder(cues: track.cues, offset: 0)
    late.moved(to: 60)
    check(late.sweep(filmSec: 85, spoken: [], importantOnly: false).map { $0.id } == ["1:2", "7"], "only lines from where she got in step")
    late.moved(to: 52)
    check(late.held.isEmpty, "a skip forgets the held lines")
    check(late.sweep(filmSec: 58, spoken: [], importantOnly: false).map { $0.id } == ["1:1", "2:1"], "after a skip back, the lines there count again")
    var paused = FollowHolder(cues: track.cues, offset: 0)
    paused.moved(to: 49)
    paused.pass(filmSec: 70)
    check(paused.sweep(filmSec: 71, spoken: [], importantOnly: false).isEmpty, "lines passing while descriptions are paused are let go")
    var many = FollowHolder(cues: (0..<20).map { FollowCue(id: "\($0)", startSec: Double($0), endSec: Double($0) + 0.5, at: nil, until: nil, text: "Line \($0)", shortText: nil, importance: 2, reading: false, fit: nil) }, offset: 0)
    many.moved(to: 0)
    _ = many.sweep(filmSec: 100, spoken: [], importantOnly: false)
    check(many.held.count == FollowHolder.keep && many.held.first?.id == "12", "at most 8 held; the oldest go first")
    var shifted = FollowHolder(cues: track.cues, offset: 40)
    shifted.moved(to: 9)
    check(shifted.sweep(filmSec: 14.6, spoken: [], importantOnly: false).map { $0.id } == ["1:1"], "a part's lines are moved into fingerprint seconds")
}

// MARK: - Settings, voice speed, memory, loudness, the level watch

do {
    let fresh = FollowAlongSettings()
    check(fresh.voice == .phone && fresh.speed == nil && fresh.amount == .everything && fresh.sounds == nil && fresh.heldChime && fresh.nudge == 0,
          "defaults: her phone's voice, same as VoiceOver, everything, sounds follow Sound effects, chime on, on time")
    check(fresh.soundsOn(soundEffects: true) && !fresh.soundsOn(soundEffects: false), "sounds follow Sound effects to begin with")
    var mine = fresh
    mine.sounds = false
    check(!mine.soundsOn(soundEffects: true), "her own choice wins")
    check(FollowAlongSettings.clampNudge(0.34) == 0.3 && FollowAlongSettings.clampNudge(-3) == -1 && FollowAlongSettings.clampNudge(.nan) == 0,
          "the nudge is tenths, at most one second either way")
    check(FollowAlongSettings.nudgeWords(0) == "On time" && FollowAlongSettings.nudgeWords(0.3) == "0.3 seconds earlier"
          && FollowAlongSettings.nudgeWords(-1) == "1 second later", "the nudge in words")
    check(FollowAlongSettings.speedWords(nil, voiceOver: true) == "Same as VoiceOver" && FollowAlongSettings.speedWords(nil, voiceOver: false) == "Usual speed"
          && FollowAlongSettings.speedWords(1.5, voiceOver: true) == "1.5 times" && FollowAlongSettings.speedWords(0.75, voiceOver: true) == "0.75 times"
          && FollowAlongSettings.speedWords(2, voiceOver: true) == "2 times", "the speed in words")
    check(FollowAlongSettings.clampSpeed(1.4) == 1.5 && FollowAlongSettings.clampSpeed(9) == 2 && FollowAlongSettings.clampSpeed(-1) == nil, "a speed snaps to the list")
    check(FollowAlongSettings.speechRate(for: 1, usual: 0.5, slowest: 0, fastest: 1) == 0.5
          && FollowAlongSettings.speechRate(for: 2, usual: 0.5, slowest: 0, fastest: 1) == 0.75
          && FollowAlongSettings.speechRate(for: 0.75, usual: 0.5, slowest: 0, fastest: 1) == 0.4375, "speeds to the speech engine's rate")
    let suite = "kade.followAlong.tests.\(UUID().uuidString)"
    if let defaults = UserDefaults(suiteName: suite) {
        var saved = FollowAlongSettings()
        saved.speed = 1.25
        saved.amount = .important
        saved.sounds = true
        saved.heldChime = false
        saved.nudge = -0.4
        saved.save(defaults)
        check(FollowAlongSettings.load(defaults) == saved, "settings are kept on the phone")
        defaults.set(Data(#"{"speed": 7, "nudge": 5, "voice": "nonsense"}"#.utf8), forKey: FollowAlongSettings.key)
        let odd = FollowAlongSettings.load(defaults)
        check(odd.speed == 2 && odd.nudge == 1 && odd.voice == .phone && odd.heldChime, "odd saved values are kept in range")
        defaults.removePersistentDomain(forName: suite)
    } else {
        check(false, "a test settings store")
    }
}

do {
    var pace = FollowPace()
    check(pace.secPerChar == FollowPace.fallback, "before anything is measured: syncprint's own guess")
    pace.measured(characters: 25, seconds: 1.5)
    check(near(pace.secPerChar, 0.06, 1e-9), "the first status sentence gives a first reading")
    pace.measured(characters: 3, seconds: 1)
    pace.measured(characters: 40, seconds: 100)
    check(pace.samples.count == 1, "a too-short or broken timing is ignored")
    for value in [0.05, 0.07, 0.08, 0.04, 0.09, 0.06, 0.05, 0.07, 0.06, 0.08, 0.05] { pace.measured(characters: 100, seconds: value * 100) }
    check(pace.samples.count == FollowPace.keep, "only the last ten are kept")
    check(near(pace.median, 0.065, 1e-9), "the middle value")
    pace.overran()
    check(near(pace.secPerChar, 0.0715, 1e-9), "a line that ran past its window makes the number go up")
    for _ in 0..<200 { pace.inTime() }
    check(pace.stretch == 1, "and it settles back")
}

do {
    var ring = FollowRing(seconds: 16)
    check(ring.last(1) == nil, "empty: nothing to study")
    let second = [Int16](repeating: 100, count: 8000)
    for index in 1...10 { ring.append(second, endingAt: 100 + Double(index)) }
    check(ring.seconds == 10, "ten seconds kept")
    if let clip = ring.last(6) {
        check(clip.samples.count == 48_000 && near(clip.start, 104, 1e-9), "a 6 second clip starts 6 seconds before the newest sound")
    } else {
        check(false, "a 6 second clip")
    }
    for index in 11...30 { ring.append([Int16](repeating: Int16(index), count: 8000), endingAt: 100 + Double(index)) }
    check(ring.seconds == 16, "only the last 16 seconds are kept")
    if let clip = ring.last(16) {
        check(clip.samples.first == 15 && clip.samples.last == 30 && near(clip.start, 114, 1e-9), "oldest first, the right times")
    } else {
        check(false, "a 16 second clip")
    }
    check(ring.last(17) == nil, "never more than it holds")
    ring.append([Int16](repeating: 1, count: 800), endingAt: 200)
    check(near(ring.seconds, 0.1, 1e-9), "a jump in the clock starts the memory afresh: no clip joins two stretches")
    ring.append([Int16](repeating: 1, count: 800), endingAt: 200.12)
    check(near(ring.seconds, 0.2, 1e-9), "small timing wobble is not a jump")
    ring.clear()
    check(ring.count == 0 && ring.endTime == nil, "cleared")
}

do {
    check(FollowLoudness.db([Int16](repeating: 0, count: 100)) == -120, "digital silence")
    let wave = (0..<8000).map { Int16((sin(2 * Double.pi * 440 * Double($0) / 8000) * 32767).rounded()) }
    check(near(FollowLoudness.db(wave), -3.01, 0.05), "a full-scale tone is about -3 dB")
    let quieter = wave.map { Int16(Double($0) * 0.1) }
    check(near(FollowLoudness.db(quieter), -23.01, 0.1), "a tenth of it is 20 dB quieter")
    var heard = FollowHeard()
    check(heard.level == nil, "nothing heard yet")
    for value in [-30.0, -28, -35, -120, -31] { heard.add(value) }
    check(heard.level == -30, "the middle of what was heard; silence is ignored")
}

do {
    var watch = FollowLevelWatch()
    check(!watch.block(db: -60, heard: nil), "before the film was heard: never")
    var fired: [Int] = []
    for index in 1...40 { if watch.block(db: -60, heard: -30) { fired.append(index) } }
    check(fired == [6, 14, 22, 30], "quiet: a check after 3 seconds, then every 4 seconds, at most 4 times")
    check(!watch.block(db: -31, heard: -30) && watch.quietBlocks == 0, "loud again: it starts over")
    check(!watch.block(db: -40, heard: -30), "10 dB under is not quiet enough")
}

// MARK: - Sounds and the report

do {
    let rising = FollowSounds.samples(.rising)
    let falling = FollowSounds.samples(.falling)
    let held = FollowSounds.samples(.held)
    check(rising.count == falling.count && rising.count > 4000, "two short notes, about a quarter second")
    check(near(FollowSounds.seconds(.held), 0.7, 0.01), "the held chime is a soft ring of 0.7 seconds")
    check((rising.map { abs(Int($0)) }.max() ?? 0) <= Int(0.12 * 32767) + 1, "the notes are quiet")
    check((held.map { abs(Int($0)) }.max() ?? 0) <= Int(0.07 * 32767) + 1, "the chime is softer still")
    check(rising.first == 0 && abs(Int(rising.last ?? 99)) < 200 && abs(Int(held.last ?? 99)) < 50, "nothing clicks at either end")
    func pitch(_ samples: ArraySlice<Int16>) -> Int {
        var crossings = 0
        var last = samples.first ?? 0
        for value in samples.dropFirst() {
            if (last < 0) != (value < 0) { crossings += 1 }
            last = value
        }
        return crossings
    }
    let half = rising.count / 2
    check(pitch(rising[0..<half]) < pitch(rising[half...]), "rising: low then high")
    check(pitch(falling[0..<half]) > pitch(falling[half...]), "falling: high then low")
}

do {
    var report = FollowReport()
    report.minutesListened = 12.5
    report.secondsToLock = 9.3
    report.checked(found(10))
    var miss = missed("no match")
    miss.millis = 120
    report.checked(miss)
    report.note(.skipped(10, ahead: true))
    report.note(.paused)
    report.linesSpoken = 14
    report.secondsPerLetter = 0.061
    report.batteryStart = 0.82
    let text = report.text()
    let lines = text.split(separator: "\n").map(String.init)
    let shape = try! NSRegularExpression(pattern: #"^[a-z ,]+: -?[0-9]+(\.[0-9]+)?$"#)
    check(lines.allSatisfy { shape.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }, "the report is labels and numbers only")
    check(text.contains("seconds to lock on: 9.3") && text.contains("failed checks: 1") && text.contains("skips: 1")
          && text.contains("battery percent at start: 82") && text.contains("voice seconds per letter: 0.061"), "the report's numbers")
    check(!text.contains("battery percent now"), "a number not known is left out")
    // syncprint's README: the tracker's playing rate belongs in the test report.
    check(!text.contains("playing rate"), "no playing rate before the film was found")
    var timed = report
    timed.playingRate = 1.04
    let rated = timed.text()
    check(rated.contains("film playing rate: 1.040"), "the film's playing rate is in the report, to three places")
    check(rated.split(separator: "\n").map(String.init).allSatisfy { shape.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil },
          "with the rate, still labels and numbers only")

    // Nov 14 2026 review: after Stop the phone stops measuring the battery,
    // so the copy carries the level from when listening stopped.
    let afterStop = report.copied(nudge: 0.2, batteryStart: 0.9, batteryNow: nil, batteryAtStop: 0.85).text()
    check(afterStop.contains("battery percent now: 85") && afterStop.contains("battery percent at start: 90")
          && afterStop.contains("timing nudge seconds: 0.2"), "after Stop: the battery as it was when listening stopped, and her nudge")
    let whileListening = report.copied(nudge: 0, batteryStart: 0.9, batteryNow: 0.88, batteryAtStop: 0.85).text()
    check(whileListening.contains("battery percent now: 88"), "while listening: the battery now")
    check(!report.copied(nudge: 0, batteryStart: nil, batteryNow: nil, batteryAtStop: nil).text().contains("battery"), "no battery known: none reported")
}

// MARK: - How long VoiceOver reads before Follow along may speak

section("VoiceOver's reading time")
do {
    let settle = KadeAudioSessionPolicy.voiceOverSettle
    check(FollowVoiceOverTime.reading(label: "Stop", value: nil, hint: nil, secPerChar: 0.04) == settle,
          "a short label: the usual 1.5 seconds, never less")
    let hint = "Stops the descriptions. The phone keeps listening, so it stays in step. Magic Tap does the same."
    let withHint = FollowVoiceOverTime.reading(label: "Pause descriptions", value: nil, hint: hint, secPerChar: 0.05)
    let expected = Double("Pause descriptions".count + FollowVoiceOverTime.traitLetters) * 0.05 + FollowVoiceOverTime.hintPause + Double(hint.count) * 0.05
    check(near(withHint, expected, 1e-9) && withHint > 5 && withHint < 8,
          "a button with a hint: its label, its kind, a pause, then its hint, at her voice's speed (\(withHint) seconds), longer than the old 1.5")
    check(FollowVoiceOverTime.reading(label: "Timing", value: "0.3 seconds earlier", hint: nil, secPerChar: 0.1)
          == Double("Timing".count + "0.3 seconds earlier".count + FollowVoiceOverTime.traitLetters) * 0.1, "a value is read with the label")
    check(FollowVoiceOverTime.reading(label: String(repeating: "a", count: 300), value: nil, hint: hint, secPerChar: 0.065) == FollowVoiceOverTime.longest,
          "never more than 8 seconds: a line that misses its window is held for the next pause, not lost")
    check(FollowVoiceOverTime.reading(label: "Where am I?", value: nil, hint: hint, secPerChar: .nan)
          == FollowVoiceOverTime.reading(label: "Where am I?", value: nil, hint: hint, secPerChar: FollowPace.fallback),
          "no measured speed yet: the usual guess")
    let words = "Test report copied. It holds numbers only."
    check(near(FollowVoiceOverTime.announcement(words, secPerChar: 0.065), Double(words.count) * 0.065 + 0.3, 1e-9),
          "an announcement of the app's own holds the voice back while VoiceOver says it")
}

// MARK: - The audio session: Follow along owns it like a film (KadeAudioSessionPolicy)

do {
    let plan = KadeAudioSessionPolicy.plan(for: .followAlong)
    check(plan.category == .playAndRecord && plan.mode == .standard, "Follow along: play and record, default mode (no voice chat: it would treat the TV as noise)")
    check(plan.options == [.allowBluetoothA2DP, .defaultToSpeaker], "A2DP only and the loudspeaker; no hands-free profile, so earbuds keep their music quality")
    check(plan.records && !plan.voiceProcessing && !plan.mixes && !plan.ducksOthers, "the microphone, no voice processing, not mixed, never ducks")
    check(!plan.notifyOthersOnDeactivation, "an owner like a film: letting go afterwards does not wake a podcast it stopped")
    var holds = KadeAudioHolds()
    holds.take("Follow along")
    holds.hold("Follow along")
    check(!holds.isQuiet(now: 7200), "two hours of listening: never quiet to the keeper")
    let moment = KadeAudioSessionPolicy.Moment(switchOn: true, quiet: holds.isQuiet(now: 7200), micHeld: true, liveFaceUp: false,
                                               category: .playAndRecord, mode: .standard)
    check(KadeAudioSessionPolicy.release(moment) != .release, "the keeper never lets go under Follow along")
    check(holds.handBack("Follow along") && holds.isQuiet(now: 7201), "it hands the session back when it stops")
    let after = KadeAudioSessionPolicy.Moment(switchOn: true, quiet: true, micHeld: false, liveFaceUp: false, category: .playback, mode: .standard)
    check(KadeAudioSessionPolicy.release(after) == .release, "then the keeper lets go, so VoiceOver is back to its own level")
}

// MARK: - The copy of syncprint.js is the one the server ships

do {
    let script = readData("Sources/syncprint.js")
    let digest = sha256Hex(script)
    let recordedFile = readText("FollowAlongTests/syncprint.js.sha256")
    let recorded = String(recordedFile.prefix(64))
    check(digest == FollowAlongEngine.scriptSHA256, "Sources/syncprint.js matches FollowAlongEngine.scriptSHA256 (re-copy it with dev/follow-along/vendor-syncprint.py)")
    check(digest == recorded, "Sources/syncprint.js matches FollowAlongTests/syncprint.js.sha256")
    // Nov 14 2026 review: nothing compared the app's copy with the server's.
    // Both checksum files now share the server's format, so a copy of one can
    // be compared with the other byte for byte, and the release step
    // (dev/follow-along/compare-syncprint.py) compares the two copies.
    check(recordedFile == "\(digest)  syncprint.js\n",
          "the checksum file is in the server's own format (the sha256, two spaces, syncprint.js), so the two projects' files compare byte for byte")
    check(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("dev/follow-along/compare-syncprint.py").path),
          "the release step that compares the app's copy with the server's is there")
    check(!script.contains(13), "LF line endings, byte for byte")
    let attributes = readText(".gitattributes")
    check(attributes.contains("Sources/syncprint.js -text"), "git never changes the copy's line endings")
}

// MARK: - syncprint.js in real JavaScriptCore

section("syncprint.js in JavaScriptCore")
do {
    let script = readText("Sources/syncprint.js")
    let maker: FollowAlongEngine
    do {
        maker = try FollowAlongEngine(script: script)
    } catch {
        fatal("syncprint.js did not load in JavaScriptCore: \(error)")
    }
    check(maker.version.hasPrefix("1."), "syncprint \(maker.version) loaded")
    let film = madeUpFilm(seconds: 90, seed: 0x1234_5678)
    guard let bytes = maker.fingerprint(film) else {
        fatal("no fingerprint (\(maker.lastError ?? "no JavaScript error"))")
    }
    check(bytes.count > 1000 && Array(bytes.prefix(4)) == Array("SYPR".utf8), "a fingerprint, starting SYPR (\(bytes.count) bytes)")

    let engine: FollowAlongEngine
    do {
        engine = try FollowAlongEngine(script: script)
        try engine.load(print: bytes)
    } catch {
        fatal("the fingerprint did not load: \(error)")
    }
    check(near(engine.printSeconds, 90, 0.1), "the fingerprint is 90 seconds long")
    var broken = bytes
    broken[broken.count / 2] ^= 0xFF
    if let other = try? FollowAlongEngine(script: script) {
        do {
            try other.load(print: broken)
            check(false, "a damaged fingerprint is refused (its own checksum)")
        } catch let failure as FollowAlongEngine.Failure {
            check(failure == .print, "a damaged fingerprint is refused (its own checksum)")
        } catch {
            check(false, "a damaged fingerprint is refused with the right reason")
        }
    }

    // The microphone hears second 47 to 55 at clock time 1000 to 1008.
    let clip = heardClip(film, from: 47, seconds: 8, gain: 0.5, noise: 0.05, seed: 99)
    let first = engine.check(clip, clipStart: 1000, now: 1008)
    check(first.found && first.reason == "ok", "a noisy clip is found (\(first.reason), score aside, \(Int(first.millis)) ms)")
    check(near(first.filmSec, 47, 0.1), "at the right second: \(first.filmSec ?? -1)")
    check(first.clipSec == 8 && first.clipDb < -5, "the clip's length and level")
    var state = engine.state(now: 1008)
    check(state.status == .locked, "the tracker locks")
    check(near(state.filmSec, 55, 0.2), "and knows the film is at 55 now: \(state.filmSec ?? -1)")
    check(state.rate == 1, "the tracker's playing rate is read: exactly 1 at real speed (\(state.rate))")
    let later = engine.state(now: 1010.5)
    check(near(later.filmSec, 57.5, 0.2), "its clock runs on: \(later.filmSec ?? -1)")
    let listen = engine.nextListen(now: 1008)
    check(listen.wait >= 15 && listen.clip == 6, "in step: the next check in 20 to 30 seconds, a 6 second clip")
    engine.hurry()
    check(engine.nextListen(now: 1008).wait == 0, "hurry: check at the next chance")

    // The planner picks the right line.
    engine.setCues(track.cues, offset: 0)
    let options = FollowPlanOptions(secPerChar: 0.06)
    state = locked(51)
    var plan = engine.plan(state, shift: 0, options: options)
    check(plan.action == .speak && plan.id == "1:1" && plan.text == "A red kite climbs over the hill." && !plan.short, "at 51 s: the kite line, in full")
    engine.spoke("1:1", now: 1009, filmSec: 51)
    plan = engine.plan(locked(52), shift: 0, options: options)
    check(plan.action == .wait, "a line said once is not said again")
    plan = engine.plan(locked(55.6), shift: 0, options: options)
    check(plan.action == .speak && plan.id == "2:1" && plan.text == "She runs back." && plan.short, "a tight gap: the short line")
    plan = engine.plan(locked(55.0), shift: 0.7, options: options)
    check(plan.action == .speak && plan.id == "2:1", "the output delay starts a line early")
    plan = engine.plan(locked(62.2), shift: 0, options: options)
    check(plan.action == .speak && plan.id == "1:2", "everything that fits: the least important line too")
    var important = options
    important.importantOnly = true
    plan = engine.plan(locked(62.2), shift: 0, options: important)
    check(plan.action == .wait, "important lines only: not that one")
    engine.forget("1:1")
    plan = engine.plan(locked(51), shift: 0, options: options)
    check(plan.action == .speak && plan.id == "1:1", "a line that never started can be said")
    plan = engine.plan(status(.holding, 51), shift: 0, options: options)
    check(plan.action == .wait, "holding: nothing is said")
    // Nov 14 2026 review: Start again (after Stop, or Listen again after a
    // call) forgets the lines said along with the place.
    engine.spoke("1:1", now: 1020, filmSec: 51)
    check(engine.plan(locked(51), shift: 0, options: options).action == .wait, "said in this run: not said again")
    engine.reset()
    plan = engine.plan(locked(51), shift: 0, options: options)
    check(plan.action == .speak && plan.id == "1:1", "after a reset (Start again), a line said in the last run can be said again")
    check(engine.state(now: 1030).status == .searching, "and the tracker looks for the film afresh")
    check(engine.lastError == nil, "no JavaScript errors: \(engine.lastError ?? "")")

    // Not this film: room noise is not found, and the tracker is not fooled.
    if let fresh = try? FollowAlongEngine(script: script) {
        try? fresh.load(print: bytes)
        let noise = heardClip(nil, from: 0, seconds: 8, gain: 0, noise: 0.2, seed: 5)
        let result = fresh.check(noise, clipStart: 2000, now: 2008)
        check(!result.found && result.filmSec == nil, "noise in the room is not the film (\(result.reason))")
        check(fresh.state(now: 2008).status == .searching, "the tracker keeps looking")
    }

    // A pause: two quiet checks where the film should be loud, then the film plays on.
    if let paused = try? FollowAlongEngine(script: script) {
        try? paused.load(print: bytes)
        var judge = FollowJudge(now: 990, endSec: 90, part: false)
        var events: [FollowEvent] = []
        func run(_ clip: [Int16], start: Double) {
            let result = paused.check(clip, clipStart: start, now: start + Double(clip.count) / 8000)
            events += judge.checked(result, state: paused.state(now: start + Double(clip.count) / 8000), now: start + Double(clip.count) / 8000)
        }
        run(heardClip(film, from: 20, seconds: 8, gain: 0.5, noise: 0.02, seed: 1), start: 1000)
        run(heardClip(film, from: 40, seconds: 6, gain: 0.5, noise: 0.02, seed: 2), start: 1020)
        run(heardClip(nil, from: 0, seconds: 6, gain: 0, noise: 0.004, seed: 3), start: 1030)
        run(heardClip(nil, from: 0, seconds: 8, gain: 0, noise: 0.004, seed: 4), start: 1036.5)
        run(heardClip(film, from: 50, seconds: 8, gain: 0.5, noise: 0.02, seed: 5), start: 1060)
        check(events == [.found(28), .paused, .backInStep(58)] || events.count == 3, "found, paused, back in step: \(events)")
        if events.count == 3, case .found(let at) = events[0], case .backInStep(let back) = events[2] {
            check(near(at, 28, 0.3) && events[1] == .paused && near(back, 58, 0.3), "the right places: \(events)")
        } else {
            check(false, "found, paused, back in step: \(events)")
        }
    }

    // syncprint's README loop tells the tracker about a match as of the clock
    // after the match finished (a match takes a third of a second or more on
    // a phone), so a jump is dated then, not when the check began.
    if let timed = try? FollowAlongEngine(script: script) {
        try? timed.load(print: bytes)
        let lock = timed.check(heardClip(film, from: 40, seconds: 8, gain: 0.5, noise: 0.02, seed: 21), clipStart: 3000, now: 3008)
        // The film is sent back to second 20 while the clock expects 70: two
        // clips of new sound, back to back (the second is a second opinion).
        var told = 0.0
        var moved = FollowTrackerState()
        for (index, start) in [3030.0, 3038.0].enumerated() where moved.status != .locked || moved.lastBackJumpMono == nil {
            let back = timed.check(heardClip(film, from: 20 + 8 * Double(index), seconds: 8, gain: 0.5, noise: 0.02, seed: UInt32(22 + index)),
                                   clipStart: start, now: start + 8)
            told = start + 8 + back.millis / 1000
            moved = timed.state(now: told)
        }
        check(lock.found && moved.status == .locked && near(moved.lastBackJumpMono, told, 1e-6) && told > 3038,
              "the tracker hears of a match as of the clock after it: the jump back is dated \(moved.lastBackJumpMono ?? -1), the match ended at \(told)")
    }

    // syncprint 1.1.1: a doubtful far match waits for a second opinion from
    // NEW sound, up to 8 seconds (1.1.0 checked again every second), and a
    // clip that holds the doubtful sound again cannot confirm it. The loop
    // holds and says nothing meanwhile (see "the check before a line");
    // nothing in the app counts on the old one-second wait.
    let probeContext: JSContext? = JSContext()
    if let probe = probeContext {
        _ = probe.evaluateScript(script)
        let answer: JSValue? = probe.evaluateScript("""
            (function () {
              var t = SyncPrint.createTracker();
              t.onMatch({ found: true, filmSec: 100, confidence: 1, clipSec: 8, reason: 'ok' }, 1000, 1008);
              t.onMatch({ found: true, filmSec: 400, confidence: 0.5, clipSec: 6, reason: 'ok' }, 1030, 1036);
              var held = t.state(1036.5);
              var wait = t.nextListen(1037).waitSec;
              t.onMatch({ found: true, filmSec: 402, confidence: 0.5, clipSec: 8, reason: 'ok' }, 1032, 1040);
              var again = t.state(1040);
              t.onMatch({ found: true, filmSec: 406, confidence: 0.5, clipSec: 8, reason: 'ok' }, 1036, 1044);
              var fresh = t.state(1044);
              return [held.status, held.doubt, wait, again.status, fresh.status, fresh.justJumped].join(',');
            })()
            """)
        let words: String = answer?.toString() ?? "nothing"
        check(words == "holding,true,7,holding,locked,true",
              "syncprint 1.1.1's doubt: it holds, waits for new sound (7 more seconds, not 1), an old-sound clip does not confirm, new sound does (\(words))")
    } else {
        check(false, "a JavaScriptCore context for the tracker")
    }
    print("Follow along: one 8 s match took \(Int(first.millis)) ms in JavaScriptCore (JIT \(jitOff ? "off" : "on"))")
    print("::notice title=Follow along match::one 8 s match took \(Int(first.millis)) ms in JavaScriptCore")
}

// MARK: - The loop on the made-up film (real JavaScriptCore, a clock the test moves)

section("the loop on a made-up film")
do {
    let script = readText("Sources/syncprint.js")
    let film = madeUpFilm(seconds: 90, seed: 0x1234_5678)
    guard let maker = try? FollowAlongEngine(script: script), let bytes = maker.fingerprint(film) else {
        fatal("the loop test's fingerprint")
    }
    let engine: FollowAlongEngine
    do {
        engine = try FollowAlongEngine(script: script)
        try engine.load(print: bytes)
    } catch {
        fatal("the loop test's matcher: \(error)")
    }
    let clock = TestClock(1000)
    let said = Said()
    let queue = DispatchQueue(label: "follow-along-tests.loop")
    let gate = FollowSpeechGate()
    let loop = FollowAlongLoop(queue: queue, gate: gate, clock: { clock.now }, trail: { _ in }, deliver: { said.add($0) })
    loop.prepare(track: track, matcher: engine, settings: FollowAlongSettings())
    // As with earbuds: the microphone never hears the phone, and no output delay.
    loop.update(lead: 0, outputDelay: 0, echoRisk: false)
    queue.sync {}
    check(said.take().contains { isPrepared($0) }, "the loop gets ready on the sample track")

    /// Plays film seconds `from` to `to` to the loop in half-second blocks,
    /// heard from clock time `at`, as the microphone hands them over. It plays
    /// the player's part too: a line handed out is said at once.
    func play(from: Double, to: Double, at start: Double) -> [(output: FollowLoopOutput, at: Double)] {
        var heard: [(output: FollowLoopOutput, at: Double)] = []
        var second = from
        var seed: UInt32 = 500
        while second + 0.5 <= to + 1e-9 {
            let samples = heardClip(film, from: second, seconds: 0.5, gain: 0.5, noise: 0.02, seed: seed)
            let end = start + (second + 0.5 - from)
            clock.set(end + 0.02)
            loop.receive(samples, endingAt: end)
            queue.sync {}
            for output in said.take() {
                heard.append((output: output, at: clock.now))
                if case .speak(let id, let text) = output {
                    gate.speaking = false
                    loop.finished(cue: id, started: true, seconds: Double(text.count) * 0.06, characters: text.count, now: clock.now)
                }
            }
            second += 0.5
            seed += 1
        }
        queue.sync {}
        return heard
    }

    // The first run: found, then the kite line in its gap (50 to 54 s).
    loop.start(now: 1000)
    let firstRun = play(from: 30, to: 60, at: 1000)
    let firstLines = firstRun.compactMap { spokenId($0.output) }
    check(firstRun.contains { sentence($0.output)?.text == "Found your place: the beginning. Audio description by Kade-AI." },
          "the loop finds its place in the made-up film and says so, with the credit")
    check(firstLines.contains("1:1"), "and hands out the kite line in its gap (\(firstLines))")
    clock.set(clock.now + 0.5)
    let firstStop = clock.now
    loop.stop()
    queue.sync {}
    _ = said.take()

    // Stop, then Start listening again, and the film played from the same
    // place again (Nov 14 review: the last run's record kept every line it
    // had said silent for good).
    let secondStart = 1100.0
    clock.set(secondStart)
    loop.start(now: secondStart)
    let secondRun = play(from: 30, to: 90, at: secondStart)
    let secondLines = secondRun.compactMap { spokenId($0.output) }
    check(secondRun.contains { sentence($0.output)?.text == "Found your place: the beginning." },
          "Start again: found again, the credit not said twice")
    check(secondLines.contains("1:1"), "Start again on the same part of the film: the kite line is said again (\(secondLines))")

    // The film ends: the closing credit, then off. Its minutes count too.
    guard let ending = secondRun.first(where: { sentence($0.output)?.stops == true }) else {
        fatal("the film's end is said, and Follow along stops")
    }
    check(sentence(ending.output)?.text == "Described by Kade-AI. More at kademurdock dot com. The film has ended. Follow along is off.",
          "the end of the film: the closing credit, then off")
    loop.stop()  // what the player does after that sentence
    queue.sync {}
    guard let last = said.take().compactMap({ reported($0) }).last else { fatal("a report after the end") }
    let both = ((firstStop - 1000) + (ending.at - secondStart)) / 60
    check(near(last.minutesListened, both, 1e-9),
          "minutes listened count both runs, the one the film ended too (\(last.minutesListened) of \(both))")
    check(last.linesSpoken >= 2 && last.checks >= 4, "the report counts the lines and the checks (\(last.linesSpoken) lines, \(last.checks) checks)")
    check(near(last.playingRate, 1, 0.01) && last.text().contains("film playing rate: "),
          "the report carries the tracker's playing rate: about 1 for a film at real speed (\(last.playingRate ?? -1))")
}

// MARK: - The loop under a slow check (a scripted matcher)

section("the loop under a slow check")
do {
    let clock = TestClock(2000)
    let said = Said()
    let queue = DispatchQueue(label: "follow-along-tests.backlog")
    let matcher = ScriptedMatcher()
    let loop = FollowAlongLoop(queue: queue, gate: FollowSpeechGate(), clock: { clock.now }, trail: { _ in }, deliver: { said.add($0) })
    loop.prepare(track: track, matcher: matcher, settings: FollowAlongSettings())
    loop.update(lead: 0, outputDelay: 0, echoRisk: false)
    loop.start(now: 2000)
    queue.sync {}
    check(matcher.resets == 1, "Start resets the matcher")
    let block = [Int16](repeating: 0, count: 4000)
    var end = 2000.0
    for _ in 0..<4 {
        end += 0.5
        clock.set(end + 0.01)
        loop.receive(block, endingAt: end)
        queue.sync {}
    }
    check(matcher.checks.count == 1, "the schedule runs as the sound arrives: one check once 2 seconds are in memory")
    // A slow check held the queue: 20 blocks queued up behind it.
    queue.suspend()
    for _ in 0..<20 {
        end += 0.5
        loop.receive(block, endingAt: end)
    }
    clock.set(end + 0.01)
    queue.resume()
    queue.sync {}
    check(matcher.checks.count == 2,
          "20 blocks that queued up behind a slow check go into memory, and only the newest runs a check (\(matcher.checks.count - 1) ran): the loop never falls behind")
    check(near(matcher.checks.last, end - 2, 1e-9), "and that check studies the newest sound")
    loop.stop()
    queue.sync {}
    _ = said.take()
}

// MARK: - The check before a line (syncprint 1.1.1's README loop, a scripted tracker)

/// What a loop handed out, with the checks made by then and the clock time.
typealias Heard = (output: FollowLoopOutput, checks: Int, at: Double)

/// Runs a loop on a PreLineMatcher from clock 2000 for `seconds`, in half
/// second blocks. As with earbuds the microphone never hears the phone;
/// with `ownSound`, the phone's own speaker sounded then and the microphone
/// heard it. It plays the player's part too: a line handed out is said at once.
func runPreLine(_ matcher: PreLineMatcher, seconds: Double, ownSound: (start: Double, end: Double)? = nil) -> [Heard] {
    let clock = TestClock(2000)
    let said = Said()
    let queue = DispatchQueue(label: "follow-along-tests.preline")
    let gate = FollowSpeechGate()
    let loop = FollowAlongLoop(queue: queue, gate: gate, clock: { clock.now }, trail: { _ in }, deliver: { said.add($0) })
    loop.prepare(track: track, matcher: matcher, settings: FollowAlongSettings())
    loop.update(lead: 0, outputDelay: 0, echoRisk: ownSound != nil)
    loop.start(now: 2000)
    if let sound = ownSound { loop.soundStarted(at: sound.start, until: sound.end) }
    queue.sync {}
    _ = said.take()
    var heard: [Heard] = []
    let block = [Int16](repeating: 0, count: 4000)
    var end = 2000.0
    while end + 0.5 <= 2000 + seconds + 1e-9 {
        end += 0.5
        clock.set(end + 0.01)
        loop.receive(block, endingAt: end)
        queue.sync {}
        for output in said.take() {
            heard.append((output: output, checks: matcher.checks.count, at: clock.now))
            if case .speak(let id, let text) = output {
                gate.speaking = false
                loop.finished(cue: id, started: true, seconds: Double(text.count) * 0.06, characters: text.count, now: clock.now)
            }
        }
    }
    loop.stop()
    queue.sync {}
    return heard
}

/// The lines handed out, with the checks made by then and when.
func spokenLines(_ heard: [Heard]) -> [(id: String, checks: Int, at: Double)] {
    heard.compactMap { item in spokenId(item.output).map { (id: $0, checks: item.checks, at: item.at) } }
}

section("the check before a line")
do {
    // The clock is 20 seconds old when the line falls due, so the loop checks
    // the film first; the check finds it, and the line is said.
    let playing = PreLineMatcher([.found])
    let control = spokenLines(runPreLine(playing, seconds: 24))
    let controlIds: [String] = control.map { $0.id }
    let controlChecks: Int = control.first?.checks ?? -1
    check(controlIds == ["k1"] && controlChecks == 1 && playing.checks.count == 1,
          "a stale clock: one check before the line finds the film, then the line is said (\(controlIds), \(playing.checks.count) checks)")

    // A paused TV right before the line: the check hears silence. syncprint's
    // README says a line is said only while misses is 0, so one silent check
    // must not let it through. The tracker checks again at once and, after
    // two misses, holds; the phone says the film seems to be paused.
    let paused = PreLineMatcher([.silence, .silence])
    let pausedRun = runPreLine(paused, seconds: 24)
    let pausedIds: [String] = spokenLines(pausedRun).map { $0.id }
    check(pausedIds.isEmpty, "a paused TV right before a line: one silent check, and the line is not said (\(pausedIds))")
    check(paused.checks.count == 2, "the tracker checks once more at once, then holds (\(paused.checks.count) checks)")
    check(pausedRun.contains { sentence($0.output)?.text == FollowWords.paused }, "two silent checks: the film seems to be paused")

    // A check that missed for another reason (noise, talking), then the
    // tracker's own check at once finds the film: the line waits for it.
    let missedOnce = PreLineMatcher([.noMatch, .found])
    let late = spokenLines(runPreLine(missedOnce, seconds: 24))
    let lateIds: [String] = late.map { $0.id }
    let lateChecks: Int = late.first?.checks ?? -1
    check(lateIds == ["k1"] && lateChecks == 2,
          "one missed check holds the line until a check finds the film again (\(lateIds), said after \(lateChecks) checks)")

    // The film's own quiet stretch: syncprint excuses the miss and trusts
    // its clock (misses stay 0), so the line is said after the one check.
    let quiet = PreLineMatcher([.quietFilm])
    let trusted: [String] = spokenLines(runPreLine(quiet, seconds: 24)).map { $0.id }
    check(trusted == ["k1"] && quiet.checks.count == 1,
          "a quiet stretch of the film: one check, then the line (\(trusted), \(quiet.checks.count) checks)")

    // One check per line (the README's checkedFor): when the tracker does not
    // check again by itself, the loop does not check on every tick either,
    // and the line still waits while the miss stands.
    let once = PreLineMatcher([.noMatch, .noMatch])
    once.recheckAtOnce = false
    let onceLines = spokenLines(runPreLine(once, seconds: 26))
    check(onceLines.isEmpty && once.checks.count == 1,
          "one check before a line, not one on every tick, and no line while it missed (\(once.checks.count) checks)")

    // A fresh clock with one miss on the record (a quick check after the
    // room went quiet missed): no check is due, and the line still waits.
    let missOnRecord = PreLineMatcher([])
    missOnRecord.misses = 1
    missOnRecord.lastFix = 2015
    missOnRecord.recheckAtOnce = false
    let onRecordIds: [String] = spokenLines(runPreLine(missOnRecord, seconds: 24)).map { $0.id }
    check(onRecordIds.isEmpty && missOnRecord.checks.isEmpty,
          "a fresh clock with one miss on the record: the line is not said (only while misses is 0) (\(onRecordIds))")
    let freshClock = PreLineMatcher([])
    freshClock.lastFix = 2015
    let freshIds: [String] = spokenLines(runPreLine(freshClock, seconds: 24)).map { $0.id }
    check(freshIds == ["k1"] && freshClock.checks.isEmpty,
          "the same with no miss: the line is said with no check, the clock being fresh (\(freshIds))")

    // A doubtful match: the tracker holds while its second opinion waits for
    // new sound (up to 8 seconds in syncprint 1.1.1). Nothing is said
    // meanwhile, not even that the film was lost; the line comes after.
    let doubtful = PreLineMatcher([])
    doubtful.lastFix = 2016
    doubtful.doubtFrom = 2019
    doubtful.doubtUntil = 2026
    let doubtRun = runPreLine(doubtful, seconds: 30)
    let afterDoubt = spokenLines(doubtRun)
    let doubtIds: [String] = afterDoubt.map { $0.id }
    let doubtAt: Double = afterDoubt.first?.at ?? -1
    check(doubtIds == ["k1"] && doubtAt >= 2026,
          "a doubtful match: no line while the tracker holds for its second opinion, the line after (\(doubtIds) at \(doubtAt))")
    let sentences = doubtRun.compactMap { sentence($0.output)?.text }
    check(sentences == ["Found your place: the beginning. Audio description by Kade-AI."],
          "while a doubtful match waits, nothing else is said: no lost, no pause (\(sentences))")

    // The phone's own speaker sounded in the last 6 seconds, so they cannot
    // be studied. The line waits, not counted as checked, until 4 clean
    // seconds have come in since the phone stopped (from 0.3 seconds after
    // its sound ended). That stretch is checked, and the line is said only
    // when the check finds the film (Nov 14 integration review: the line was
    // said on the next tick with no check at all).
    let echo = PreLineMatcher([.found])
    let echoLines = spokenLines(runPreLine(echo, seconds: 26, ownSound: (start: 2018, end: 2019.5)))
    let echoIds: [String] = echoLines.map { $0.id }
    let echoAt: Double = echoLines.first?.at ?? -1
    let echoChecks: Int = echoLines.first?.checks ?? -1
    check(echoIds == ["k1"] && echoChecks == 1 && echo.hurries >= 1,
          "the phone's own sound in the 6 seconds before a line: the line waits for a check, and is said after it (\(echoIds) after \(echoChecks) checks, \(echo.hurries) hurries)")
    let echoStart: Double = echo.checks.first ?? -1
    let echoLength: Double = echo.lengths.first ?? -1
    check(echoStart > 2019.79 && echoLength > 3.99 && echoLength < 6.01 && echoAt >= 2023.8,
          "that check studies clean sound only: 4 to 6 seconds, from 0.3 seconds after the phone stopped (\(echoStart) for \(echoLength) s, the line at \(echoAt))")
    // The same with the TV paused: the check hears silence, so the line
    // waits; the tracker's own longer second look hears silence too, and the
    // pause is said. The line is never said over the paused TV.
    let echoPaused = PreLineMatcher([.silence, .silence])
    let echoPausedRun = runPreLine(echoPaused, seconds: 30, ownSound: (start: 2018, end: 2019.5))
    let echoPausedIds: [String] = spokenLines(echoPausedRun).map { $0.id }
    check(echoPausedIds.isEmpty && echoPaused.checks.count == 2,
          "the phone's own sound, then a paused TV: no line, one check, then the tracker's second look (\(echoPausedIds), \(echoPaused.checks.count) checks)")
    check(echoPausedRun.contains { sentence($0.output)?.text == FollowWords.paused }, "and the pause is said")
}

// MARK: - The phone's own speaker, lines close together (the real tracker)
//
// Nov 14 2026 integration review: on the phone's own speaker the check before
// a line never ran. When the phone had made any sound in the last 6 seconds,
// the line was counted as checked and the tracker was hurried, but its own
// check needs the same 6 clean seconds; on the next tick the line was said
// with no check at all. With lines close together no check ran again, and the
// lines went on over a paused TV. Here the real syncprint (matcher, tracker
// and planner) follows the made-up film through the loop on the phone's own
// speaker. The test plays the player's part: the phone says each line and
// sentence for 0.06 seconds a letter, and the microphone hears that as loud
// noise. A line comes every 5 seconds. The TV is paused at film second 45 and
// plays on 20 seconds later.

typealias NotedCheck = (at: Double, start: Double, seconds: Double, found: Bool, reason: String)

/// A matcher that hands every call to the real one, and notes each check.
final class NotingMatcher: FollowMatching {
    let inner: FollowMatching
    private(set) var checks: [NotedCheck] = []

    init(_ inner: FollowMatching) {
        self.inner = inner
    }

    var printSeconds: Double { inner.printSeconds }

    func setCues(_ cues: [FollowCue], offset: Double) {
        inner.setCues(cues, offset: offset)
    }

    func check(_ clip: [Int16], clipStart: Double, now: Double) -> FollowCheck {
        let result = inner.check(clip, clipStart: clipStart, now: now)
        checks.append((at: now, start: clipStart, seconds: Double(clip.count) / 8000, found: result.found, reason: result.reason))
        return result
    }

    func state(now: Double) -> FollowTrackerState { inner.state(now: now) }
    func nextListen(now: Double) -> FollowListen { inner.nextListen(now: now) }
    func hurry() { inner.hurry() }
    func reset() { inner.reset() }

    func plan(_ state: FollowTrackerState, shift: Double, options: FollowPlanOptions) -> FollowPlan {
        inner.plan(state, shift: shift, options: options)
    }

    func spoke(_ id: String, now: Double, filmSec: Double) { inner.spoke(id, now: now, filmSec: filmSec) }
    func forget(_ id: String) { inner.forget(id) }
}

/// What a run on the phone's speaker handed out, with the clock time, and
/// every check it made.
struct SpeakerRun {
    var said: [(output: FollowLoopOutput, at: Double)] = []
    var checks: [NotedCheck] = []

    var lines: [(id: String, at: Double)] {
        said.compactMap { item in spokenId(item.output).map { (id: $0, at: item.at) } }
    }

    /// When a sentence starting with these words was first handed out.
    func firstSentence(_ start: String) -> Double? {
        said.first { (sentence($0.output)?.text ?? "").hasPrefix(start) }?.at
    }

    /// syncprint's README rule, over the whole run: a line is said only when
    /// a check found the film in the 15 seconds before it, and no check has
    /// missed since. The lines that break it.
    var unchecked: [String] {
        lines.compactMap { line -> String? in
            let before = checks.filter { $0.at <= line.at + 1e-6 }
            guard let lastFound = before.last(where: { $0.found }) else { return line.id }
            let missedSince = before.contains { $0.at > lastFound.at && !$0.found }
            let age: Double = line.at - lastFound.start
            return age > 15.000001 || missedSince ? line.id : nil
        }
    }
}

/// One run on the phone's own speaker. The made-up film plays on the TV from
/// clock 1000 at film second 0, stops at clock `pauseAt`, and plays on from
/// clock `resumeAt`. The sound comes in quarter seconds, as from a phone.
func runOnSpeaker(engine: FollowAlongEngine, film: [Int16], track speakerTrack: FollowTrack,
                  pauseAt: Double, resumeAt: Double, until: Double) -> SpeakerRun {
    let matcher = NotingMatcher(engine)
    let clock = TestClock(1000)
    let said = Said()
    let queue = DispatchQueue(label: "follow-along-tests.speaker")
    let gate = FollowSpeechGate()
    let loop = FollowAlongLoop(queue: queue, gate: gate, clock: { clock.now }, trail: { _ in }, deliver: { said.add($0) })
    loop.prepare(track: speakerTrack, matcher: matcher, settings: FollowAlongSettings())
    // The phone's own speaker: the microphone hears the phone.
    loop.update(lead: 0, outputDelay: 0, echoRisk: true)
    loop.start(now: 1000)
    queue.sync {}
    _ = said.take()
    let block = 0.25
    let letter = 0.06
    var run = SpeakerRun()
    // What the phone is saying (a line has its id), and the sentence waiting its turn.
    var saying: (id: String?, text: String, start: Double, end: Double, stops: Bool)?
    var waiting: (text: String, stops: Bool)?
    // When the phone's own speaker sounded, for the microphone.
    var sounds: [(start: Double, end: Double)] = []
    func begin(_ id: String?, _ text: String, at time: Double, stops: Bool) {
        let end = time + Double(text.count) * letter
        saying = (id: id, text: text, start: time, end: end, stops: stops)
        gate.speaking = true
        loop.soundStarted(at: time, until: nil)
        sounds.append((start: time, end: end))
    }
    var step = 1
    var seed: UInt32 = 900
    playing: while true {
        let end = 1000 + Double(step) * block
        if end > until + 1e-9 { break }
        step += 1
        let now = end + 0.02
        // The player: speech that has ended by now.
        if let done = saying, done.end <= now {
            saying = nil
            gate.speaking = waiting != nil
            loop.soundEnded(at: done.end)
            if let id = done.id {
                loop.finished(cue: id, started: true, seconds: done.end - done.start, characters: done.text.count, now: done.end)
            } else {
                loop.sentenceSpoken(characters: done.text.count, seconds: done.end - done.start)
            }
            if done.stops { break playing }
            if let next = waiting {
                waiting = nil
                begin(nil, next.text, at: done.end, stops: next.stops)
            }
        }
        // What the microphone hears in this quarter second: the TV (the film,
        // or the quiet room while it is paused), and the phone's own voice.
        let from = end - block
        var heard: [Int16]
        if from < pauseAt {
            heard = heardClip(film, from: from - 1000, seconds: block, gain: 0.5, noise: 0.02, seed: seed)
        } else if from >= resumeAt {
            heard = heardClip(film, from: pauseAt - 1000 + (from - resumeAt), seconds: block, gain: 0.5, noise: 0.02, seed: seed)
        } else {
            heard = heardClip(nil, from: 0, seconds: block, gain: 0, noise: 0.02, seed: seed)
        }
        let voice = heardClip(nil, from: 0, seconds: block, gain: 0, noise: 0.3, seed: seed &+ 7000)
        seed &+= 1
        let sounding = sounds.filter { $0.end > from && $0.start < end }
        if !sounding.isEmpty {
            for index in heard.indices {
                let time = from + Double(index) / 8000
                if sounding.contains(where: { time >= $0.start && time < $0.end }) {
                    heard[index] = Int16(max(-32767, min(32767, Int(heard[index]) + Int(voice[index]))))
                }
            }
        }
        clock.set(now)
        loop.receive(heard, endingAt: end)
        queue.sync {}
        for output in said.take() {
            run.said.append((output: output, at: now))
            switch output {
            case .speak(let id, let text):
                if saying == nil, waiting == nil {
                    begin(id, text, at: now, stops: false)
                } else {
                    loop.finished(cue: id, started: false, seconds: nil, characters: text.count, now: now)
                }
            case .sentence(let text, _, let stops):
                // A sentence takes over from a line being said.
                if let cut = saying, let id = cut.id {
                    saying = nil
                    if let index = sounds.lastIndex(where: { $0.start == cut.start }) { sounds[index].end = now }
                    loop.soundEnded(at: now)
                    loop.finished(cue: id, started: true, seconds: nil, characters: cut.text.count, now: now)
                }
                gate.speaking = true
                if saying == nil {
                    begin(nil, text, at: now, stops: stops)
                } else {
                    waiting = (text: text, stops: stops)
                }
            case .chime:
                let length = FollowSounds.seconds(.held) + 0.1
                loop.soundStarted(at: now, until: now + length)
                sounds.append((start: now, end: now + length))
            default:
                break
            }
        }
    }
    loop.stop()
    queue.sync {}
    run.checks = matcher.checks
    return run
}

section("the phone's own speaker")
do {
    let script = readText("Sources/syncprint.js")
    let film = madeUpFilm(seconds: 90, seed: 0x1234_5678)
    guard let maker = try? FollowAlongEngine(script: script), let bytes = maker.fingerprint(film) else {
        fatal("the speaker test's fingerprint")
    }
    let engine: FollowAlongEngine
    do {
        engine = try FollowAlongEngine(script: script)
        try engine.load(print: bytes)
    } catch {
        fatal("the speaker test's matcher: \(error)")
    }
    // Fourteen lines, one every 5 seconds from film second 14, each about two seconds long.
    let texts = [
        "A red kite climbs over the hill.", "The boy runs after the string.", "A dog barks at the kite.",
        "Clouds roll in from the sea.", "The kite dips toward the trees.", "The boy pulls the line hard.",
        "Rain begins to fall.", "They run for the barn.", "The barn door slams shut.",
        "Lightning lights the field.", "The kite lies in the mud.", "The boy smiles anyway.",
        "The sun comes out again.", "A rainbow spans the hill.",
    ]
    let cues = texts.enumerated().map { index, text in
        #"{"id": "c\#(index + 1)", "startSec": \#(14 + 5 * index), "endSec": \#(18.5 + 5 * Double(index)), "text": "\#(text)", "importance": 2}"#
    }
    let credit = #""credit": {"start": "Audio description by Kade-AI.", "end": "Described by Kade-AI. More at kademurdock dot com."}"#
    let speakerTrack: FollowTrack
    switch readTrack(#"{"format": "kade-follow-track", "version": 1, "filmSeconds": 90, \#(goodPrint), \#(credit), "cues": [\#(cues.joined(separator: ", "))]}"#) {
    case .success(let made):
        speakerTrack = made
    case .failure(let problem):
        fatal("the speaker test's track: \(problem)")
    }
    check(speakerTrack.cues.count == 14 && speakerTrack.cues[1].startSec == 19 && speakerTrack.cues[1].endSec == 23.5,
          "fourteen lines, 5 seconds apart")

    let run = runOnSpeaker(engine: engine, film: film, track: speakerTrack, pauseAt: 1045, resumeAt: 1065, until: 1090)
    let lines = run.lines
    let playing = lines.filter { $0.at < 1045 }
    let overPause = lines.filter { $0.at >= 1045.5 && $0.at < 1065 }
    let playingOn = lines.filter { $0.at >= 1065 }
    check(run.unchecked.isEmpty,
          "the phone's own speaker, a line every 5 seconds: each line is said only after a check found the film in the 15 seconds before it, none missed since (unchecked \(run.unchecked); \(lines.count) lines, \(run.checks.count) checks)")
    check(playing.count >= 6, "while the film plays the lines are said, a moment late when a check comes first (\(playing.map { $0.id }))")
    let shortChecks = run.checks.filter { $0.at > 1010 && $0.at < 1045 && $0.found }.filter { $0.seconds > 3.99 && $0.seconds < 5.99 }
    check(!shortChecks.isEmpty, "a check between lines studies the 4 seconds or more heard since the phone last spoke, and finds the film")
    check(overPause.isEmpty, "the TV paused: no line is said over it (\(overPause.map { $0.id }))")
    if let pausedAt = run.firstSentence("The film seems to be paused.") {
        check(pausedAt - 1045 <= 12, "the pause is said within 12 seconds on the phone's speaker (\(pausedAt - 1045) s)")
    } else {
        check(false, "the pause is said: \(run.said.compactMap { sentence($0.output)?.text })")
    }
    let backAt: Double = run.firstSentence("Back in step") ?? -1
    check(backAt >= 1065 && backAt - 1065 <= 12, "the TV plays on: back in step (\(backAt - 1065) s)")
    check(playingOn.count >= 2, "and the lines go on (\(playingOn.map { $0.id }))")
    check(engine.lastError == nil, "no JavaScript errors on the speaker run: \(engine.lastError ?? "")")
}

// MARK: - A loop that never got its track

do {
    let said = Said()
    let queue = DispatchQueue(label: "follow-along-tests.unready")
    let loop = FollowAlongLoop(queue: queue, gate: FollowSpeechGate(), clock: { 5 }, trail: { _ in }, deliver: { said.add($0) })
    loop.start(now: 5)
    queue.sync {}
    check(said.take() == [.sentence(FollowWords.couldNotStart, sound: nil, stops: true)],
          "Start on a loop with no track says it could not start, and stops: the microphone is never left on doing nothing")
}

// MARK: - The microphone's sound to 8 kHz, through a change of format

section("the microphone capture")
do {
    let sink = SoundCollector()
    guard let mono48 = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
          let stereo44 = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
          let capture = FollowAlongCapture(from: mono48, sink: sink) else {
        fatal("a capture for a 48 kHz microphone")
    }
    var clockSeconds = 500.0
    var lastStart = clockSeconds
    /// A 440 Hz tone, `buffers` of 4096 frames, as a microphone tap hands them over.
    func feed(_ format: AVAudioFormat, buffers: Int) {
        var frame = 0
        for _ in 0..<buffers {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
                  let channels = buffer.floatChannelData else { fatal("a test buffer") }
            buffer.frameLength = 4096
            for channel in 0..<Int(format.channelCount) {
                for index in 0..<4096 {
                    channels[channel][index] = Float(0.5 * sin(2 * Double.pi * 440 * Double(frame + index) / format.sampleRate))
                }
            }
            lastStart = clockSeconds
            capture.take(buffer, at: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: clockSeconds)))
            frame += 4096
            clockSeconds += 4096.0 / format.sampleRate
        }
    }
    feed(mono48, buffers: 12)
    let first = sink.samples.count
    check(first > 8000 && first <= 8300, "48 kHz from the phone's microphone becomes 8 kHz: about 8192 samples for 1.02 seconds (\(first))")
    check(near(sink.ends.last, lastStart + 4096.0 / 48_000.0, 0.001), "each piece carries the clock time it ended at")
    feed(stereo44, buffers: 11)
    let added = sink.samples.count - first
    check(added > 7950 && added < 8300,
          "earbuds change the microphone to 44.1 kHz, two channels: the capture makes a new converter and carries on (\(added) samples)")
    check(near(sink.ends.last, lastStart + 4096.0 / 44_100.0, 0.001), "with the new rate's timing")
    let tail = Array(sink.samples.suffix(4000))
    var crossings = 0
    for index in 1..<tail.count where (tail[index - 1] < 0) != (tail[index] < 0) { crossings += 1 }
    check(crossings > 420 && crossings < 460, "after the change it is still the 440 Hz tone (\(crossings) zero crossings in half a second)")
}


// MARK: - Which finished copy a kept track is of (the Nov 14 contract)

section("the kept track's stamp")
do {
    func answer(_ json: String) -> DVTrackAnswer? { DVTrackAnswer.read(Data(json.utf8)) }
    let trackJSON = #"{"format": "kade-follow-track", "version": 1, "filmSeconds": 90, "print": {"format": 1, "bytes": 10, "sha256": "0000000000000000000000000000000000000000000000000000000000000000"}, "cues": []}"#
    let stamp = "2026-11-14T10:00:00.000Z"

    // GET (and POST) /jobs/:id/track, ready: the answer carries the
    // finishedAt of the copy its track was built from.
    if let ready = answer(#"{"follow": "ready", "version": 3, "track": \#(trackJSON), "printUrl": "https://example.invalid/print.sypr", "expiresAt": "2026-11-14T16:00:00.000Z", "finishedAt": "2026-11-14T10:00:00.000Z"}"#) {
        check(ready.isReady && ready.state == "ready" && ready.printLink == "https://example.invalid/print.sypr", "a ready answer reads as before")
        check(ready.finishedAt == stamp, "it carries the finishedAt of the copy its track was built from")
    } else {
        check(false, "a ready answer with finishedAt reads")
    }
    let nullStamp = answer(#"{"follow": "ready", "track": \#(trackJSON), "printUrl": "https://example.invalid/p", "finishedAt": null}"#)
    check(nullStamp?.isReady == true && nullStamp?.finishedAt == nil, "finishedAt null (a copy with none): no stamp, and the answer still reads")
    let noStamp = answer(#"{"follow": "ready", "track": \#(trackJSON), "printUrl": "https://example.invalid/p"}"#)
    check(noStamp?.isReady == true && noStamp?.finishedAt == nil, "no finishedAt (an older server): no stamp, and still ready")
    check(answer(#"{"follow": "making", "message": "Being made.", "finishedAt": "  "}"#)?.finishedAt == nil, "an empty stamp is none")
    check(answer(#"{"follow": "ready", "track": \#(trackJSON), "printUrl": "https://example.invalid/p", "finishedAt": 1763114400000}"#)?.finishedAt == "1763114400000",
          "a number is written the way the job's own reader writes it")
    check(answer(#"{"follow": "ready", "track": \#(trackJSON), "printUrl": "https://example.invalid/p", "finishedAt": true}"#)?.finishedAt == nil,
          "a yes or no is not a stamp")

    // A kept track is used only when its stamp is the copy's finishedAt now.
    check(FollowTrackStamp.matches(stamp, "2026-11-14T10:00:00.000Z"), "the same finished copy: the kept track is used")
    check(!FollowTrackStamp.matches(stamp, "2026-11-14T11:30:00.000Z"),
          "the copy was finished again under the same version (Describe the rest): the track is fetched again")
    check(!FollowTrackStamp.matches(nil, stamp), "a track kept before the stamp existed: fetched again")
    check(!FollowTrackStamp.matches(stamp, nil) && !FollowTrackStamp.matches(nil, nil), "a copy with no finishedAt: fetched again")
    check(FollowTrackStamp.matches("2026-11-14T10:00:00Z", stamp), "the same moment written without milliseconds is the same copy")
    check(!FollowTrackStamp.matches("", "") && !FollowTrackStamp.matches("x", "y"), "empty or different text is no match")

    // meta.json of a track kept before the contract has no stamp: it still
    // reads, and the track is fetched again once.
    let old = Data(#"{"title": "The Kite", "job": "j1", "copyVersion": 2, "filmSeconds": 90, "coversStart": 0, "coversEnd": 90, "lines": 4, "bytes": 7000, "savedAt": 1763100000}"#.utf8)
    if let meta = try? JSONDecoder().decode(FollowTrackMeta.self, from: old) {
        check(meta.finishedAt == nil && meta.job == "j1" && meta.copyVersion == 2, "an old kept track's meta.json still reads, with no stamp")
        check(!FollowTrackStamp.matches(meta.finishedAt, stamp), "so an old kept track is stale: one extra request")
    } else {
        check(false, "an old meta.json reads")
    }
    let kept = FollowTrackMeta(title: "The Kite", job: "j1", copyVersion: 2, filmSeconds: 90, coversStart: 0, coversEnd: 90,
                               lines: 4, bytes: 7000, savedAt: 1763100000, finishedAt: stamp)
    if let data = try? JSONEncoder().encode(kept), let back = try? JSONDecoder().decode(FollowTrackMeta.self, from: data) {
        check(back == kept && back.finishedAt == stamp, "a kept track's meta.json keeps the answer's finishedAt")
    } else {
        check(false, "meta.json with a stamp is written and read back")
    }

    // The described video screen and the store need a phone, so their
    // source is checked.
    let screenSource = readText("Sources/DescribedVideoView.swift")
    let opener = body("private func openFollowAlong() async", in: screenSource)
    check(opener.contains("finishedCopies.first(where: { $0.number == viewVersion })?.finishedAt")
          && opener.contains("followStore.stored(job: current.id, version: viewVersion, finishedAt: finishedAt)")
          && opener.contains("followStore.fetch(jobId: current.id, version: viewVersion, service: service)"),
          "Follow along with my TV uses a kept track only when its stamp is this copy's finishedAt now, and otherwise fetches it again")
    let storeSource = readText("Sources/FollowAlongStore.swift")
    check(body("func stored(job: String, version: Int, finishedAt: String?)", in: storeSource).contains("FollowTrackStamp.matches(kept.finishedAt, finishedAt)"),
          "the store hands back a kept track only when the stamps match")
    check(!storeSource.contains("func stored(job: String, version: Int) ->"), "no lookup of a kept track that ignores the stamp")
    let fetcher = body("func fetch(jobId: String, version: Int, service: DescribedVideoService)", in: storeSource)
    check(fetcher.components(separatedBy: "finishedAt: answer.finishedAt").count - 1 == 2,
          "a fetched track is kept with the answer's finishedAt, and replaces the kept track and fingerprint")

    // A kept track opened from "Follow-along tracks on this phone" (Nov 14
    // integration review: the list opened it with no stamp check, so after
    // Describe the rest it kept the preview's short track). While its copy is
    // on the server's list, the same rule as the button; as it is when the
    // video is off the list or the phone is offline.
    check(FollowKeptTrack.openAsIs(stamp: stamp, listed: true, finishedAt: "2026-11-14T10:00:00Z"),
          "the list: the same finished copy, so the kept track opens")
    check(!FollowKeptTrack.openAsIs(stamp: stamp, listed: true, finishedAt: "2026-11-14T11:30:00.000Z"),
          "the list: the copy was finished again (Describe the rest), so the track is fetched again first")
    check(!FollowKeptTrack.openAsIs(stamp: nil, listed: true, finishedAt: stamp) && !FollowKeptTrack.openAsIs(stamp: stamp, listed: true, finishedAt: nil),
          "the list: a track kept before the stamp, or a copy with no finishedAt, is fetched again")
    check(FollowKeptTrack.openAsIs(stamp: stamp, listed: false, finishedAt: nil) && FollowKeptTrack.openAsIs(stamp: nil, listed: false, finishedAt: nil),
          "the list: a video no longer on the server's list opens its kept track as it is")
    check(FollowKeptTrack.offline(URLError(.notConnectedToInternet)) && FollowKeptTrack.offline(URLError(.timedOut)),
          "the list: no internet, so the kept track opens as it is")
    check(!FollowKeptTrack.offline(URLError(.cancelled)) && !FollowKeptTrack.offline(CancellationError())
          && !FollowKeptTrack.offline(FollowAlongEngine.Failure.print),
          "the list: any other failure is said, not hidden behind the kept track")
    let row = body("private func followTrackRow(_ item: FollowStoredTrack)", in: screenSource)
    check(row.contains("await openKeptTrack(item)") && !row.contains("activeSheet = .followAlong(item)"),
          "Follow-along tracks on this phone opens a kept track through the stamp check, never straight")
    let keptOpener = body("private func openKeptTrack(_ item: FollowStoredTrack) async", in: screenSource)
    check(keptOpener.contains("jobs.first(where: { $0.id == item.job })")
          && keptOpener.contains("finishedCopies.first(where: { $0.number == item.copyVersion })")
          && keptOpener.contains("FollowKeptTrack.openAsIs(stamp: item.finishedAt, listed: listedCopy != nil, finishedAt: listedCopy?.finishedAt)")
          && keptOpener.contains("followStore.fetch(jobId: item.job, version: item.copyVersion, service: service)")
          && keptOpener.contains("FollowKeptTrack.offline(error)"),
          "the list compares the kept stamp with its copy's finishedAt in the loaded list, fetches again when they differ, and opens the kept track as it is only off the list or offline")
}

// MARK: - The server's real answers (the contract check, Nov 14 2026)
//
// FollowAlongTests/server-samples holds real answers from the website's own
// Follow along code (the LibreChat fork, branch claude/tellavision-sync-20261114,
// commit 2b42b45f6), byte for byte, with the track and the fingerprint it made
// for 60 seconds of Big Buck Bunny. The app's own readers read them here:
// DVTrackAnswer and FollowTrack (FollowAlongModel.swift), and DVConfig, DVJob
// and DVCopy (DescribedVideoService.swift's wire shapes, which
// run-follow-along-tests.sh takes from the app's source). Then the server's
// fingerprint finds 8 seconds of the film's own sound in JavaScriptCore, and
// the loop says the right things on the real track.

section("the server's real answers")
do {
    let folder = "FollowAlongTests/server-samples/"
    func serverFile(_ name: String) -> Data { readData(folder + name) }
    func serverObject(_ name: String) -> [String: Any] {
        guard let found = (try? JSONSerialization.jsonObject(with: serverFile(name))) as? [String: Any] else {
            fatal("\(name) is not a JSON object")
        }
        return found
    }
    func serverAnswer(_ name: String) -> DVTrackAnswer {
        guard let read = DVTrackAnswer.read(serverFile(name)) else { fatal("\(name) does not read as a track answer") }
        return read
    }
    func serverDecoded<T: Decodable>(_ type: T.Type, _ name: String) -> T {
        do {
            return try JSONDecoder().decode(type, from: serverFile(name))
        } catch {
            fatal("\(name) does not decode as \(type): \(error)")
        }
    }
    func trackIn(_ data: Data?, _ label: String) -> FollowTrack {
        guard let data else { fatal("\(label): no track") }
        do {
            return try FollowTrack.read(data)
        } catch {
            fatal("\(label): the track does not read: \(error)")
        }
    }
    let placeholderLink = "https://storage.example.invalid/described-video/65a1f00dcafe4b1d2e3f4a5b/dce6029e937e9b4f0d712ab49635b630/sync/plan.sypr?X-Amz-Expires=21600&X-Amz-Signature=PLACEHOLDER"
    let finishedStamp = "2026-11-14T20:01:41.862Z"
    let printSum = "438b32974d6e1af035e97e6fe031fb44c15f1bc5e7a838d13519c1edd61e9bd4"

    // The files are the server's own bytes (samples.json gives the checksums).
    let trackBytes = serverFile("track.json")
    let printBytes = serverFile("plan.sypr")
    check(trackBytes.count == 4200 && sha256Hex(trackBytes) == "ecceb8aa34d6d90203aa1e3567b1d094a4106edbc24b1aa7f57407eb61b340c9",
          "track.json is the track the server saved, byte for byte")
    check(printBytes.count == 5206 && sha256Hex(printBytes) == printSum, "plan.sypr is the fingerprint the server made, byte for byte")
    check(readText(".gitattributes").contains("FollowAlongTests/server-samples/** -text"), "git never changes the samples' bytes")

    // track.json, field by field, as FollowTrack reads it.
    let saved = trackIn(trackBytes, "track.json")
    check(saved.format == "kade-follow-track" && saved.version == 1, "the server's track: its format and version")
    check(saved.job == "dce6029e937e9b4f0d712ab49635b630" && saved.copyVersion == 1, "its job and copy")
    check(saved.title == "Big Buck Bunny" && saved.language == "en", "its title (the video's name without .mp4) and language")
    check(saved.filmSeconds == 60 && saved.covers == FollowTrack.Span(startSec: 0, endSec: 60),
          "covers.endSec 60.01 is a hair past filmSeconds 60 (the plan's length against the check's): the phone keeps it inside the film")
    check(!saved.isPart && saved.reachesFilmEnd, "so it is a whole film, and the closing credit belongs at its end")
    check(saved.print == FollowTrack.Print(format: 1, bytes: 5206, sha256: printSum, startSec: nil), "the fingerprint it names: its format, size and sha256")
    check(saved.plannedAt == FollowTrack.Pace(secPerChar: 0.0417, rate: 1.5, maxRate: 2.25), "the pace the server planned at")
    check(saved.credit == FollowTrack.Credit(start: "Audio description by Kade-AI.", end: "Described by Kade-AI. More at kademurdock dot com."),
          "both credit lines")
    check(saved.warning == "AI descriptions can miss or misread visual details. Check anything important for yourself.", "the warning")
    check(saved.quiet.count == 6, "six quiet stretches")
    check(saved.quiet.first == FollowTrack.Span(startSec: 0, endSec: 4.42), "the first, as a [start, end] pair in seconds")
    check(saved.quiet.last == FollowTrack.Span(startSec: 51.9, endSec: 60.01), "the last, to the end the track covers")
    check(saved.cues.map { $0.id } == (0..<12).map { "0:\($0)" }, "all 12 lines, in the server's order")
    check(saved.cues.filter { $0.fit == "full" }.count == 5 && saved.cues.filter { $0.fit == "short" }.count == 5
          && saved.cues.filter { $0.fit == "none" }.count == 2, "five lines fit in full, five only short, two not at all")
    check(saved.cues.allSatisfy { cue in cue.importance == 2 || cue.importance == 3 }, "every line's importance, 2 or 3 here")
    check(saved.cues.allSatisfy { cue in !cue.reading && cue.shortText != nil }, "every line has a short text, and none reads the screen")
    check(saved.cues.allSatisfy { cue in cue.at != nil && cue.until != nil }, "every line has its moment and its last moment")
    let opening = saved.cues[0]
    check(opening.startSec == 0.08 && opening.endSec == 4.42, "the first line's window, in seconds")
    check(opening.at == 0.08 && opening.until == 4.43, "its moment and its last moment")
    check(opening.importance == 3 && opening.fit == "short", "its importance, and what the server expected to fit")
    check(opening.shortText == "Beside a tree, a chinchilla, a red squirrel and a brown squirrel gather.", "its short text")
    let unplaced = saved.cues[4]
    check(unplaced.id == "0:4" && unplaced.fit == "none", "a line that does not fit is kept")
    check(unplaced.startSec == 26.25 && unplaced.endSec == 26.25, "with an empty window at its own moment, where dialogue covers it")
    check(unplaced.at == 26.25 && unplaced.until == 27.75, "and its moment and last moment")
    check(saved.printOffset(printSeconds: 60.01) == 0, "a whole film: the fingerprint's second 0 is the film's (covers.startSec)")

    // GET and POST /jobs/:id/track, ready (200).
    let readyGet = serverObject("track-200-ready-get.json")
    let readyPost = serverObject("track-200-ready-post.json")
    let agreed: Set<String> = ["follow", "version", "finishedAt", "track", "printUrl", "expiresAt"]
    check(Set(readyGet.keys) == agreed && Set(readyPost.keys) == agreed, "the ready answer has exactly the agreed fields, from GET and from POST")
    check((readyGet["version"] as? NSNumber)?.intValue == 1 && readyGet["expiresAt"] is String && readyGet["track"] is [String: Any],
          "version is a number, expiresAt a date in text, the track an object")
    for name in ["track-200-ready-get.json", "track-200-ready-post.json"] {
        let ready = serverAnswer(name)
        check(ready.state == "ready" && ready.isReady && ready.reason == nil, "\(name): ready, with no reason")
        check(ready.printLink == placeholderLink, "\(name): the fingerprint's link is printUrl")
        check(ready.finishedAt == finishedStamp, "\(name): finishedAt is the copy's finishing time")
        check(trackIn(ready.trackData, name) == saved, "\(name): the track inside is the saved track, field for field")
    }
    check(sha256Hex(printBytes) == saved.print.sha256 && printBytes.count == saved.print.bytes,
          "the fingerprint is whole by the store's own test: its size and sha256 are the track's")

    // Being made (202), not asked for yet (409), cannot be made (409), switched off (404).
    for name in ["track-202-making-get.json", "track-202-making-post.json"] {
        let making = serverAnswer(name)
        check(making.state == "making" && !making.isReady && making.finishedAt == nil, "\(name): making, not ready")
        check(making.reason == "Your follow-along track is being made. It is free. Check again in a minute.", "\(name): the server's own sentence is said")
    }
    let possible = serverAnswer("track-409-possible-get.json")
    check(possible.state == "possible" && !possible.isReady && possible.reason == "This copy has no follow-along track yet. Ask for one; it is free.",
          "409 possible is read, not thrown away: the phone then asks with POST")
    for name in ["track-409-gone-get.json", "track-409-gone-post.json"] {
        let gone = serverAnswer(name)
        check(gone.state == "gone" && !gone.isReady && gone.reason == FollowWords.gone, "\(name): gone, with the server's reason, which is the phone's own words too")
    }
    let refused = serverObject("track-404-not-available-get.json")
    check(refused.count == 1 && (refused["error"] as? String) == "Follow along is not available.", "404: only the plain refusal every route uses")
    let service = readText("Sources/DescribedVideoService.swift")
    let reader = body("private func trackAnswer(", in: service)
    check(reader.contains("(200..<300).contains(http.statusCode) || http.statusCode == 409")
          && reader.contains("throw decodeError(data, status: http.statusCode, fallback: fallback)")
          && service.contains("struct E: Decodable { let error: String? }"),
          "only 2xx and 409 answers are read as track answers; a 404's error text is thrown, and said")
    check(body("func track(jobId: String, version: Int)", in: service).contains("method: \"GET\"")
          && body("func track(jobId: String, version: Int)", in: service).contains("query: [URLQueryItem(name: \"version\", value: String(version))]"),
          "GET asks for the version as ?version=N, the way the server reads it")
    check(body("func makeTrack(jobId: String, version: Int)", in: service).contains("method: \"POST\"")
          && body("func makeTrack(jobId: String, version: Int)", in: service).contains("body: [\"version\": version]"),
          "POST sends {\"version\": N}, which the server reads too")
    let download = body("func downloadData(from link: String, limit: Int)", in: service)
    check(download.contains("URLRequest(url: url)") && !download.contains("authorized") && !download.contains("Authorization"),
          "the signed fingerprint link is fetched as it is, with no sign-in header (a signed storage link refuses a second sign-in)")

    // GET /config and the jobs, read by the app's own wire shapes.
    let configOn = serverDecoded(DVConfig.self, "config.json")
    let configOff = serverDecoded(DVConfig.self, "config-off.json")
    check(configOn.followAlong == true && configOff.followAlong == false, "GET /config: followAlong true with the switch on, false with it off")
    check(configOn.voices != nil && configOff.voices != nil, "both count as the describer's config (the access check needs voices, prices or a size)")
    check(configOn.listenAhead == true && configOn.features?.describerLinks == true, "and the rest of the config reads as before")
    let readyJob = serverDecoded(DVJob.self, "job-ready.json")
    check(readyJob.id == "dce6029e937e9b4f0d712ab49635b630" && readyJob.state == "done" && readyJob.follow == "ready",
          "GET /jobs/:id: the follow word, ready")
    for (name, word) in [("job-possible.json", "possible"), ("job-making.json", "making"), ("job-gone.json", "gone")] {
        check(serverDecoded(DVJob.self, name).follow == word, "\(name): the follow word, \(word)")
    }
    let copies = readyJob.finishedCopies
    check(copies.count == 1 && copies[0].number == 1, "the job's one finished copy, version 1")
    check(copies[0].rehearsal == false && copies[0].preview == false, "not a rehearsal and not a preview")
    check(copies[0].finishedAt == finishedStamp, "with its finishedAt")
    // The stamp rule through the app's own readers, as openFollowAlong looks it up.
    let viewVersion = copies.last?.number ?? 0
    let copyStamp = readyJob.finishedCopies.first(where: { $0.number == viewVersion })?.finishedAt
    check(FollowTrackStamp.matches(serverAnswer("track-200-ready-get.json").finishedAt, copyStamp),
          "the answer's finishedAt is exactly the job's copies[].finishedAt for that version, so a track kept from it is used")
    let jobText = String(decoding: serverFile("job-ready.json"), as: UTF8.self)
    let finishedAgain = jobText.replacingOccurrences(of: "\"finishedAt\":\"\(finishedStamp)\",\"rehearsal\"",
                                                     with: "\"finishedAt\":\"2026-11-14T20:09:12.345Z\",\"rehearsal\"")
    check(finishedAgain != jobText, "a copy finished again is made from the real job")
    if let rest = try? JSONDecoder().decode(DVJob.self, from: Data(finishedAgain.utf8)) {
        let restStamp = rest.finishedCopies.first(where: { $0.number == viewVersion })?.finishedAt
        check(restStamp == "2026-11-14T20:09:12.345Z" && !FollowTrackStamp.matches(finishedStamp, restStamp),
              "after Describe the rest (the same version, finished again) the kept track is stale, so it is fetched again")
    } else {
        check(false, "the job finished again still reads")
    }

    // The server's fingerprint in real JavaScriptCore, and the film's own sound.
    let script = readText("Sources/syncprint.js")
    let matcher: FollowAlongEngine
    do {
        matcher = try FollowAlongEngine(script: script)
        try matcher.load(print: printBytes)
    } catch {
        fatal("the server's fingerprint did not load in JavaScriptCore: \(error)")
    }
    check(matcher.version == "1.1.1", "syncprint \(matcher.version) reads the server's fingerprint")
    check(near(matcher.printSeconds, 60.01, 0.01), "it holds the film's 60 seconds (\(matcher.printSeconds))")
    check(near(saved.endInPrint(printSeconds: matcher.printSeconds), 60, 1e-9), "and the track ends inside it")
    let soundData = serverFile("film-sound-29s-to-37s.s16le")
    check(soundData.count == 128_000, "8 seconds of the film's own sound, 8 kHz mono, 16-bit")
    let sound: [Int16] = stride(from: 0, to: soundData.count - 1, by: 2).map {
        Int16(bitPattern: UInt16(soundData[$0]) | UInt16(soundData[$0 + 1]) << 8)
    }
    let clean = matcher.check(sound, clipStart: 4000, now: 4008)
    check(clean.found && clean.reason == "ok" && near(clean.filmSec, 29, 0.1),
          "the film's sound from second 29 is found there in the server's fingerprint (\(clean.filmSec ?? -1), \(clean.reason))")
    let lockedOn = matcher.state(now: 4008)
    check(lockedOn.status == .locked && near(lockedOn.filmSec, 37, 0.2), "the tracker locks: the film is at 37 seconds as the clip ends (\(lockedOn.filmSec ?? -1))")
    matcher.reset()
    let noisy = matcher.check(heardClip(sound, from: 0, seconds: 8, gain: 0.5, noise: 0.02, seed: 41), clipStart: 4100, now: 4108)
    check(noisy.found && near(noisy.filmSec, 29, 0.1), "and as a phone hears it, quieter with room noise (\(noisy.filmSec ?? -1), \(noisy.reason))")

    // The planner on the real lines, at a phone voice's pace.
    matcher.setCues(saved.cues, offset: saved.printOffset(printSeconds: matcher.printSeconds))
    let pace = FollowPlanOptions(secPerChar: 0.06)
    var plan = matcher.plan(locked(0.1), shift: 0, options: pace)
    check(plan.action == .speak && plan.id == "0:0" && plan.short && plan.text == opening.shortText, "at 0.1 s: the first line, short, as the server expected")
    plan = matcher.plan(locked(18.5), shift: 0, options: pace)
    check(plan.action == .speak && plan.id == "0:3" && plan.short,
          "at 18.5 s: the fruit line; the phone decides by its own voice, so only the short text fits (the server, at 1.5x, fitted it whole)")
    plan = matcher.plan(locked(26.25), shift: 0, options: pace)
    check(plan.action == .wait, "at 26.25 s: the line with an empty window is never said over the dialogue")
    plan = matcher.plan(locked(36.2), shift: 0, options: pace)
    check(plan.action == .wait, "at 36.2 s: the butterfly line's gap of a second is too short, so it waits to be held")
    var holder = FollowHolder(cues: saved.cues, offset: 0)
    holder.moved(to: 20)
    check(holder.sweep(filmSec: 27, spoken: ["0:3"], importantOnly: true).map { $0.id } == ["0:4"],
          "in step before it: the line with an empty window is held for the next pause, important lines only too")

    // Lines with one start keep the server's order: by the moment each
    // happens, then as sent (track.ts). The planner says the first of a tie.
    switch readTrack(#"{"format": "kade-follow-track", "version": 1, "filmSeconds": 60, \#(goodPrint), "cues": [{"id": "0:10", "startSec": 36, "endSec": 40, "at": 36, "text": "B happens.", "importance": 3}, {"id": "0:9", "startSec": 36, "endSec": 40, "at": 35.5, "text": "A happens.", "importance": 3}, {"id": "1:2", "startSec": 50, "endSec": 52, "at": 50, "text": "D happens.", "importance": 2}, {"id": "1:1", "startSec": 50, "endSec": 52, "at": 50, "text": "C happens.", "importance": 2}]}"#) {
    case .success(let tied):
        check(tied.cues.map { $0.id } == ["0:9", "0:10", "1:2", "1:1"],
              "lines with one start: the earlier moment first, then the server's own order, not the id's text (\(tied.cues.map { $0.id }))")
        matcher.setCues(tied.cues, offset: 0)
        let first = matcher.plan(locked(36.1), shift: 0, options: pace)
        check(first.action == .speak && first.id == "0:9", "so the planner says the line whose moment came first (\(first.id))")
    case .failure(let problem):
        check(false, "a track with lines that share a start reads (\(problem))")
    }

    // The loop, end to end, on the real ready answer: its track, the
    // server's fingerprint, and the film's own sound as the microphone
    // hears it. The film's sound past these 8 seconds is not kept here, so
    // room noise as loud as the film follows; no check falls due before the
    // next line.
    let real = trackIn(serverAnswer("track-200-ready-get.json").trackData, "the ready answer")
    let follower: FollowAlongEngine
    do {
        follower = try FollowAlongEngine(script: script)
        try follower.load(print: printBytes)
    } catch {
        fatal("the loop's matcher on the server's fingerprint: \(error)")
    }
    let clock = TestClock(5000)
    let said = Said()
    let queue = DispatchQueue(label: "follow-along-tests.server-samples")
    let gate = FollowSpeechGate()
    let loop = FollowAlongLoop(queue: queue, gate: gate, clock: { clock.now }, trail: { _ in }, deliver: { said.add($0) })
    loop.prepare(track: real, matcher: follower, settings: FollowAlongSettings())
    loop.update(lead: 0, outputDelay: 0, echoRisk: false)
    // Her voice as the phone measures it from its own sentences: 0.05 seconds a letter.
    loop.sentenceSpoken(characters: 100, seconds: 5)
    queue.sync {}
    check(said.take().contains { output in
        if case .prepared(_, let seconds, let language, let warning) = output {
            return near(seconds, 60.01, 0.01) && language == "en" && warning == real.warning
        }
        return false
    }, "the loop gets ready on the real track and the server's fingerprint")
    loop.start(now: 5000)
    var heard: [(output: FollowLoopOutput, film: Double)] = []
    for block in 0..<31 {
        let samples = block < 16
            ? heardClip(sound, from: Double(block) * 0.5, seconds: 0.5, gain: 0.5, noise: 0.02, seed: UInt32(700 + block))
            : heardClip(nil, from: 0, seconds: 0.5, gain: 0, noise: 0.05, seed: UInt32(900 + block))
        let end = 5000 + Double(block + 1) * 0.5
        clock.set(end + 0.02)
        loop.receive(samples, endingAt: end)
        queue.sync {}
        for output in said.take() {
            heard.append((output: output, film: 29 + (clock.now - 5000)))
            if case .speak(let id, let text) = output {
                gate.speaking = false
                loop.finished(cue: id, started: true, seconds: Double(text.count) * 0.05, characters: text.count, now: clock.now)
            }
        }
    }
    loop.stop()
    queue.sync {}
    let report = said.take().compactMap { reported($0) }.last
    let events = heard.filter { item in
        if case .report = item.output { return false }
        return true
    }
    guard let foundAt = events.firstIndex(where: { sentence($0.output)?.text == "Found your place: the beginning. Audio description by Kade-AI." }) else {
        fatal("the loop finds its place in the real film and says so, with the credit: \(events.map { $0.output })")
    }
    check(near(events[foundAt].film, 37, 0.3), "found as the 8 seconds of film end (\(events[foundAt].film))")
    check(!events.contains { (sentence($0.output)?.text ?? "").contains("This track covers") },
          "a whole film: nothing about parts, though covers.endSec is past filmSeconds")
    let lines = events.compactMap { item -> (id: String, text: String, film: Double)? in
        if case .speak(let id, let text) = item.output { return (id: id, text: text, film: item.film) }
        return nil
    }
    check(lines.count == 1 && lines[0].id == "0:8" && lines[0].text == real.cues[8].shortText && near(lines[0].film, 41, 0.3),
          "then the line due next, at 41 seconds, short to fit its gap (\(lines))")
    if let chimeAt = events.firstIndex(where: { $0.output == .chime }) {
        check(chimeAt > foundAt, "the butterfly line, too long for its gap once she is in step, is held with a soft chime")
    } else {
        check(false, "the butterfly line, too long for its gap once she is in step, is held with a soft chime")
    }
    guard let lastReport = report else { fatal("a report after Stop") }
    check(lastReport.checks == 1 && lastReport.linesSpoken == 1, "the report: one check, one line said (\(lastReport.text()))")
    check(lastReport.linesHeld == 1 && lastReport.playingRate == 1, "one line held, and the film at real speed")
}

// MARK: - The sources keep the rules

do {
    let sheet = readText("Sources/FollowAlongView.swift")
    for lazy in ["LazyVStack", "LazyHStack", "LazyVGrid", "LazyHGrid", "List {", "List("] {
        check(!sheet.contains(lazy), "the sheet has no lazy container (\(lazy)): its words change while VoiceOver reads it")
    }
    check(sheet.contains(".accessibilityAction(.magicTap)"), "Magic Tap pauses and resumes the descriptions")
    check(sheet.contains("FollowWords.privacy"), "the privacy sentence is on the sheet")
    check(!sheet.contains("accessibilityFocused") && !sheet.contains("AccessibilityFocusState"), "the sheet never moves VoiceOver's focus")
    check(!sheet.contains("updatesFrequently") && !sheet.contains("UIAccessibility.post(notification: .announcement"),
          "the status line is not a live region, and the sheet posts no announcements of its own")
    let buttons = sheet.components(separatedBy: "Button(").count - 1 + sheet.components(separatedBy: "Button {").count - 1
    let hints = sheet.components(separatedBy: ".accessibilityHint(").count - 1
    check(buttons > 0 && hints >= buttons, "every control has a hint (\(hints) hints, \(buttons) buttons)")
    check(sheet.contains(".accessibilityHidden(true)"), "the line being spoken is hidden from VoiceOver, so it is not said twice")

    let audio = readText("Sources/FollowAlongAudio.swift")
    check(audio.contains("prefersAssistiveTechnologySettings = true"), "speech uses her VoiceOver voice and speed")
    check(audio.contains("KadeAudioSession.setCategory(for: .followAlong)"), "the session comes from the keeper's plan")
    for mark in ["KadeAudioSession.shared.take(Self.sessionName)", "KadeAudioSession.shared.hold(Self.sessionName)",
                 "KadeAudioSession.shared.handBack(Self.sessionName)", "KadeAudioLanes.beginRecording(", "KadeAudioLanes.endRecording("] {
        check(audio.contains(mark), "Follow along registers with the keeper and the microphone lane: \(mark)")
    }
    check(!audio.contains("setActive(false"), "it never switches the session off itself: the keeper does")
    for file in ["FollowAlongAudio.swift", "FollowAlongLoop.swift", "FollowAlongCapture.swift", "FollowAlongEngine.swift"] {
        let source = readText("Sources/\(file)")
        for forbidden in ["AVAudioFile", "AVAudioRecorder", "write(to:", "URLSession", "uploadTask", "FileHandle"] {
            check(!source.contains(forbidden), "the microphone's sound is never written or sent (\(file): \(forbidden))")
        }
    }
    check(audio.contains("setPreferredInput") && audio.contains(".builtInMic"), "the phone's own microphone")
    check(audio.contains("MPRemoteCommandCenter") && audio.contains("MPNowPlayingInfoCenter"), "lock screen and earbud buttons")
    check(audio.contains("interruptionNotification") && audio.contains("routeChangeNotification"), "calls and earbuds are watched")
    check(audio.contains("elementFocusedNotification"), "it waits for VoiceOver before it speaks")

    // Nov 14 2026 review fixes in the player (it needs a phone, so its source is checked).
    let opening = body("func open(_ item: FollowStoredTrack", in: audio)
    let closing = body("func close()", in: audio)
    let closed = body("private func finishClose()", in: audio)
    let stopped = body("private func finishStop()", in: audio)
    let micOff = body("private func stopListening()", in: audio)
    check(body("private func watchCalls()", in: audio).contains("AVAudioSession.interruptionNotification") && opening.contains("watchCalls()"),
          "calls are watched from the moment the sheet opens")
    check(!body("private func watchSession()", in: audio).contains("interruptionNotification") && !micOff.contains("unwatchCalls()"),
          "turning the microphone off keeps calls watched, so the end of a call is heard")
    check(closed.contains("unwatchCalls()"), "the sheet closing stops watching calls")
    check(body("private func interrupted(", in: audio).contains("notifyCall(active: true)"),
          "a call's end with the app away posts the notification again, with a sound")
    let rebuild = body("private func engineChanged()", in: audio)
    check(rebuild.contains("dropEngine()") && rebuild.contains("startEngine(loop: loop)") && !rebuild.contains("engine.start()"),
          "earbuds in or out: a fresh engine is built, not the stopped one started bare")
    check(body("nonisolated private static func installTap(", in: audio).contains("format: nil"),
          "the tap takes the microphone's own format, so a format read too early cannot stop the app")
    check(opening.contains("case .stopping:") && opening.contains("closeWhenStopped = false") && opening.contains("reopen = item"),
          "opened again during the last sentence: the sheet stays open and its track waits")
    check(closing.contains("reopen = nil") && stopped.contains("if let item = reopen") && stopped.contains("prepare(item)"),
          "the waiting track gets ready when the sentence is done; closing again forgets it")
    check(audio.contains("Self.deliverer(to: self, generation: generation)")
          && body("private func handle(_ output: FollowLoopOutput, from sender: Int)", in: audio).contains("guard sender == generation else { return }")
          && closed.contains("generation &+= 1"),
          "answers from a loop already let go are dropped")
    check(body("func copyReport()", in: audio).contains("report.copied(") && micOff.contains("batteryAtStop = battery"),
          "the battery when listening stopped goes into the copied report")
    check(body("private func watchVoiceOver()", in: audio).contains("focusedElementUserInfoKey") && audio.contains("FollowVoiceOverTime.reading(")
          && audio.contains("FollowVoiceOverTime.announcement("),
          "the voice waits for what VoiceOver landed on, label and hint, and for the app's own announcements")
    let screenSource = readText("Sources/DescribedVideoView.swift")
    check(body("private func releaseHeldAnnouncement()", in: screenSource).contains("guard followAlong.phase != .stopping else { return }")
          && screenSource.contains(".onChange(of: followAlong.phase)"),
          "the described video screen keeps its own line until Follow along's last sentence is done")

    let engine = readText("Sources/FollowAlongEngine.swift")
    check(engine.contains("JSObjectMakeTypedArray") && engine.contains("copyMemory"), "sound goes into JavaScript in bulk, one typed array per clip")
    check(!engine.contains("import UIKit") && !engine.contains("import AVFoundation"), "the doorway is Foundation and JavaScriptCore only")

    let project = readText("project.yml")
    check(project.contains("NSMicrophoneUsageDescription: \"Kade-AI uses your microphone when you talk to your characters or record, and when you turn on Follow along, to hear the film playing near you and keep its descriptions in step. Film sound is checked on your phone and is never saved or sent.\""),
          "the microphone sentence names Follow along plainly")
    check(project.contains("UIBackgroundModes: [audio]"), "background audio stays on")

    let switches = readText("Sources/KadeAppSwitches.swift")
    check(switches.contains("static var followAlong: Bool { on(\"kade.switch.followAlong\") }"), "the phone switch, on unless set to false")
    let screen = readText("Sources/DescribedVideoView.swift")
    check(screen.contains("KadeAppSwitches.followAlong") && screen.contains("config?.followAlong == true"),
          "the button shows only when the server and the phone switch both say so")
    let service = readText("Sources/DescribedVideoService.swift")
    check(service.contains("case followAlong") || service.contains("followAlong = c.dvBool(.followAlong)"), "the config reads followAlong")
    check(service.contains("follow = c.dvString(.follow)"), "each job reads its follow word")
    check(service.contains("\"jobs/\\(jobId)/track\""), "the track route")
}

print("Follow along: \(count) checks passed")
print("::notice title=Follow along tests::\(count) checks passed")
