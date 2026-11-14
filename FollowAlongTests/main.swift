import CryptoKit
import Foundation

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

var count = 0
func check(_ ok: Bool, _ label: String) {
    if !ok { print("FAILED: \(label)"); exit(1) }
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
        print("FAILED: could not read \(relative) under \(root)")
        exit(1)
    }
    return text
}

func readData(_ relative: String) -> Data {
    let url = rootURL.appendingPathComponent(relative)
    guard let data = try? Data(contentsOf: url) else {
        print("FAILED: could not read \(relative) under \(root)")
        exit(1)
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
    print("Follow along timing (\(label)): 10 minute film, fingerprint \(Int(printMillis)) ms, load \(Int(loadMillis)) ms, 8 s matches \(times.map { String(Int($0)) }.joined(separator: ", ")) ms")
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
check(FollowWords.gone == "The original video is no longer on the server, so a follow-along track cannot be made. Describe it again to get one.", "server: original gone")
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
        print("FAILED: the sample track did not read: \(error)")
        exit(1)
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
    check(part.printOffset(printSeconds: 1900) == 5400, "a part's own fingerprint starts where the part does")
    check(part.printOffset(printSeconds: 7300) == 0, "a whole film's fingerprint for a part starts at 0")
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
    let recorded = readText("FollowAlongTests/syncprint.js.sha256").trimmingCharacters(in: .whitespacesAndNewlines)
    check(digest == FollowAlongEngine.scriptSHA256, "Sources/syncprint.js matches FollowAlongEngine.scriptSHA256 (re-copy it with dev/follow-along/vendor-syncprint.py)")
    check(digest == recorded, "Sources/syncprint.js matches FollowAlongTests/syncprint.js.sha256, the checksum the server copy is tested against")
    check(!script.contains(13), "LF line endings, byte for byte")
    let attributes = readText(".gitattributes")
    check(attributes.contains("Sources/syncprint.js -text"), "git never changes the copy's line endings")
}

// MARK: - syncprint.js in real JavaScriptCore

do {
    let script = readText("Sources/syncprint.js")
    let maker: FollowAlongEngine
    do {
        maker = try FollowAlongEngine(script: script)
    } catch {
        print("FAILED: syncprint.js did not load in JavaScriptCore: \(error)")
        exit(1)
    }
    check(maker.version.hasPrefix("1."), "syncprint \(maker.version) loaded")
    let film = madeUpFilm(seconds: 90, seed: 0x1234_5678)
    guard let bytes = maker.fingerprint(film) else {
        print("FAILED: no fingerprint (\(maker.lastError ?? "no JavaScript error"))")
        exit(1)
    }
    check(bytes.count > 1000 && Array(bytes.prefix(4)) == Array("SYPR".utf8), "a fingerprint, starting SYPR (\(bytes.count) bytes)")

    let engine: FollowAlongEngine
    do {
        engine = try FollowAlongEngine(script: script)
        try engine.load(print: bytes)
    } catch {
        print("FAILED: the fingerprint did not load: \(error)")
        exit(1)
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
    print("Follow along: one 8 s match took \(Int(first.millis)) ms in JavaScriptCore (JIT \(jitOff ? "off" : "on"))")
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
    for forbidden in ["AVAudioFile", "AVAudioRecorder", "write(to:", "URLSession", "uploadTask", "FileHandle"] {
        check(!audio.contains(forbidden), "the microphone's sound is never written or sent (\(forbidden))")
    }
    check(audio.contains("setPreferredInput") && audio.contains(".builtInMic"), "the phone's own microphone")
    check(audio.contains("MPRemoteCommandCenter") && audio.contains("MPNowPlayingInfoCenter"), "lock screen and earbud buttons")
    check(audio.contains("interruptionNotification") && audio.contains("routeChangeNotification"), "calls and earbuds are watched")
    check(audio.contains("elementFocusedNotification"), "it waits for VoiceOver before it speaks")

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
