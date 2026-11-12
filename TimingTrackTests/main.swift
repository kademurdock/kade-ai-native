import Foundation

// Nov 11 2026: Inworld timing tracks on the iPhone (Sources/KadeTimingTrack.swift).
// Mirrors the website's timing-track.test.mjs case for case, then pins the
// Swift picks to the website's own output for the same tracks
// (timing-golden.json, written by dev/timing-track/golden.mjs), then checks
// the app-side parts: WAV readers never assume 44 bytes, the chunk is cut out
// before Apple's parsers, the presentation and call timeline carry the track,
// and the puppet engine follows a tracked mouth. Run with
// run-timing-track-tests.sh (macOS).
var count = 0
var failures: [String] = []
func check(_ value: Bool, _ name: @autoclosure () -> String) {
    count += 1
    if !value { failures.append(name()) }
}

let environment = ProcessInfo.processInfo.environment
let root = URL(fileURLWithPath: environment["TIMING_ROOT"] ?? ".")

// MARK: - A WAV the way the voice proxy writes one

func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)] }
func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
func fmtBody(rate: UInt32 = 24000) -> [UInt8] {
    le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
}
/// RIFF / WAVE / chunks / data. `riffSize` overrides the size field (the streaming sentinel).
func wav(_ chunks: [(String, [UInt8])], pcmBytes: Int = 4800, riffSize: UInt32? = nil,
         dataSize: UInt32? = nil) -> Data {
    var body: [UInt8] = Array("WAVE".utf8)
    for (id, payload) in chunks {
        body += Array(id.utf8) + le32(UInt32(payload.count)) + payload
        if payload.count % 2 == 1 { body.append(0) }
    }
    var pcm = [UInt8](repeating: 0, count: pcmBytes)
    for i in 0..<pcmBytes { pcm[i] = UInt8(truncatingIfNeeded: i * 7 + 3) }
    body += Array("data".utf8) + le32(dataSize ?? UInt32(pcmBytes)) + pcm
    return Data(Array("RIFF".utf8) + le32(riffSize ?? UInt32(body.count)) + body)
}
func utf8(_ s: String) -> [UInt8] { Array(s.utf8) }
func json(_ object: Any) -> [UInt8] {
    Array((try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
}

/// JSON text to a Foundation value (keeps every literal below free of
/// heterogeneous-collection inference).
func j(_ text: String) -> Any { (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) ?? NSNull() }
let webTrack: [String: Any] = (j("""
{"v": 1, "src": "inworld", "set": "oxr", "dur": 1000,
 "vis": [[0, 100, "sil"], [100, 300, "aa"], [300, 310, "PP"], [310, 500, "aa"], [500, 600, "oh"]],
 "w": [[100, 300, "Hello"], [310, 480, "there"], [520, 700, "[laugh]"]],
 "cov": [[0, 700]]}
""") as? [String: Any]) ?? [:]
func withTrack(_ t: [String: Any] = webTrack, pcmBytes: Int = 4800) -> Data {
    wav([("fmt ", fmtBody()), ("kdtm", json(t))], pcmBytes: pcmBytes)
}
func edited(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
    var t = webTrack
    change(&t)
    return t
}

// MARK: - The website's cases

guard let track = KadeTimingTrack.parse(wav: withTrack()) else {
    print("timing track: the web track did not parse"); exit(1)
}
check(track.set == .oxr && track.durationMs == 1000 && track.spans.count == 5 && track.words.count == 3
      && track.coverage.count == 1, "reads kdtm between fmt and data")
let listed = wav([("LIST", utf8("INFOISFT")), ("fmt ", fmtBody()), ("kdtm", json(webTrack) + utf8(" "))])
check(KadeTimingTrack.parse(wav: listed)?.spans.count == 5, "reads kdtm after a LIST chunk, with a trailing space")

check(KadeTimingTrack.parse(wav: wav([("fmt ", fmtBody())])) == nil, "no kdtm chunk: nil")
check(KadeTimingTrack.parse(wav: wav([("fmt ", fmtBody()), ("kdtm", utf8("{\"v\":1,"))])) == nil, "broken JSON: nil")
check(KadeTimingTrack.parse(wav: withTrack(edited { $0["v"] = 2 })) == nil, "another version: nil")
check(KadeTimingTrack.parse(wav: withTrack(edited { $0["vis"] = j("[[100, 300, \"aa\"], [0, 100, \"sil\"]]") })) == nil, "unsorted spans: nil")
check(KadeTimingTrack.parse(wav: withTrack(edited { $0["vis"] = j("[[0, 0, \"aa\"]]") })) == nil, "a zero-length span: nil")
check(KadeTimingTrack.parse(wav: withTrack(edited { $0["set"] = "nope" })) == nil, "an unknown set: nil")
check(KadeTimingTrack.parse(wav: withTrack(edited { $0["cov"] = [Any]() })) == nil, "empty coverage: nil")
check(KadeTimingTrack.parse(wav: withTrack(edited { $0["pad"] = String(repeating: "x", count: 600 * 1024) })) == nil,
      "a chunk over 512 KB: nil")
check(KadeTimingTrack.parse(wav: Data([1, 2, 3, 4])) == nil, "four bytes: nil")
check(KadeTimingTrack.parse(wav: Data("ID3 not a wav at all".utf8)) == nil, "not a WAV: nil")
// kdtm AFTER data is never a track (the track always sits before the audio).
var after = wav([("fmt ", fmtBody())])
after.append(contentsOf: utf8("kdtm") + le32(UInt32(json(webTrack).count)) + json(webTrack))
check(KadeTimingTrack.parse(wav: after) == nil, "a chunk after data: nil")

let first = wav([("fmt ", fmtBody())])
var joined = first; joined.append(withTrack())
check(KadeTimingTrack.parse(wav: joined) == nil, "a second RIFF joined after the first is never read")
var joinedOtherWay = withTrack(); joinedOtherWay.append(first)
check(KadeTimingTrack.parse(wav: joinedOtherWay)?.spans.count == 5, "the first RIFF's track is read")

check(track.fits(seconds: 1.0) && track.fits(seconds: 1.24) && !track.fits(seconds: 1.3) && !track.fits(seconds: .nan),
      "a track belongs to its own take: within 250 ms")

check(track.shape(atMs: 0) == "sil" && track.covered(atMs: 0), "trackAt 0 is covered sil")
check(track.shape(atMs: 100) == "aa" && track.shape(atMs: 299.9) == "aa" && track.shape(atMs: 300) == "PP",
      "trackAt boundaries")
check(track.shape(atMs: 650) == "sil", "covered with no span is a closed mouth")
check(track.shape(atMs: 700) == nil && track.shape(atMs: 900) == nil && !track.covered(atMs: 700), "outside cov")
check(track.panel(atMs: 900) == nil, "outside cov the caller uses loudness")

var frames: [Int?] = []
var ms = 0.0
while ms < 700 { frames.append(track.panel(atMs: ms, strength: 0.4)); ms += 1000.0 / 24 }
check(frames.contains(6), "a 10 ms lip closure between two open vowels shows as pressed")
check(frames.contains(2) && frames.contains(3), "the vowels show around it")
check(track.panel(atMs: 279, strength: 0.4) == 2, "a frame that only grazes the closure keeps the vowel")
for step in [1000.0 / 24, 50.0] {
    var phase = 0.0
    while phase < step {
        var seen = false
        var at = phase
        while at < 700 && !seen { seen = track.panel(atMs: at, strength: 0.4) == 6; at += step }
        check(seen, "step \(step) phase \(phase): some frame shows the closure")
        phase += 0.5
    }
}

let oxr: [String: [Int]] = [
    "sil": [0, 0, 0], "PP": [6, 6, 6], "FF": [7, 7, 7], "TH": [1, 1, 1], "DD": [1, 1, 1], "kk": [1, 1, 2],
    "CH": [7, 7, 7], "SS": [7, 7, 7], "nn": [1, 1, 1], "RR": [4, 4, 4], "aa": [2, 2, 8], "E": [5, 5, 5],
    "ih": [1, 5, 5], "oh": [3, 3, 3], "ou": [4, 4, 4],
]
let iw11: [String: [Int]] = [
    "sil": [0, 0, 0], "bmp": [6, 6, 6], "aei": [2, 2, 8], "o": [3, 3, 3], "ee": [5, 5, 5], "fv": [7, 7, 7],
    "th": [1, 1, 1], "l": [1, 1, 1], "r": [4, 4, 4], "qw": [4, 4, 4], "u": [4, 4, 4], "chjsh": [7, 7, 7],
    "cdgknstxyz": [1, 1, 1],
]
let tables: [(KadeTimingTrack.ShapeSet, [String: [Int]], [String: [Int]])] = [
    (KadeTimingTrack.ShapeSet.oxr, oxr, KadeTimingTrack.oxrPanels),
    (KadeTimingTrack.ShapeSet.iw11, iw11, KadeTimingTrack.iw11Panels),
]
for (set, table, panels) in tables {
    check(Set(panels.keys) == Set(table.keys), "\(set) has exactly the website's shapes")
    for (shape, want) in table {
        check(KadeTimingTrack.shapePanel(shape, set: set, strength: 0.1) == want[0], "\(set) \(shape) quiet")
        check(KadeTimingTrack.shapePanel(shape, set: set, strength: 0.4) == want[1], "\(set) \(shape) normal")
        check(KadeTimingTrack.shapePanel(shape, set: set, strength: 0.8) == want[2], "\(set) \(shape) loud")
    }
}
check(KadeTimingTrack.shapePanel("unknown", set: .oxr) == nil, "an unknown shape has no panel")

// Bracketed sounds become face moments; [silence] and unknown sounds do not.
func moment(_ tag: String) -> CharacterExpression? { CharacterCue.fromSpeech("%%%" + tag + "%%%").moment }
check(track.sounds.count == 1 && track.sounds[0].ms == 520 && moment(track.sounds[0].tag) == .amused,
      "[laugh] is an amused moment at its own time")
let soundTrack = KadeTimingTrack.parse(wav: withTrack(edited {
    $0["w"] = j("[[0, 10, \"[sigh]\"], [10, 20, \"[chuckle]\"], [20, 30, \"[breath]\"], [30, 40, \"word\"]]")
}))
let soundMoments: [CharacterExpression?] = soundTrack?.sounds.map { moment($0.tag) } ?? []
check(soundMoments == [CharacterExpression.concerned, .amused, nil], "[sigh] concerned, [chuckle] amused, [breath] none")

// MARK: - Golden picks from the website's own module

let goldenURL = root.appendingPathComponent("TimingTrackTests/timing-golden.json")
if let data = try? Data(contentsOf: goldenURL),
   let golden = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
   let tracks = golden["tracks"] as? [String: Any], let cases = golden["cases"] as? [[String: Any]] {
    check((golden["leadMs"] as? NSNumber)?.doubleValue == KadeTimingTrack.leadMs, "golden lead matches")
    check(cases.count == 27, "every golden case is present (\(cases.count))")
    var built: [String: KadeTimingTrack] = [:]
    for (name, object) in tracks {
        built[name] = KadeTimingTrack.parse(wav: wav([("fmt ", fmtBody()), ("kdtm", json(object))]))
        check(built[name] != nil, "golden track \(name) parses from a WAV")
    }
    for item in cases {
        guard let name = item["track"] as? String, let t = built[name],
              let step = (item["step"] as? NSNumber)?.doubleValue, let phase = (item["phase"] as? NSNumber)?.doubleValue,
              let strength = (item["strength"] as? NSNumber)?.doubleValue, let want = item["picks"] as? String else {
            check(false, "golden case readable"); continue
        }
        var picks = ""
        var at = phase
        while at < t.durationMs {
            if let panel = t.panel(atMs: at, strength: strength) { picks += String(panel) } else { picks += "-" }
            at += step
        }
        let framesName = (item["frames"] as? String) ?? ""
        check(picks == want, "golden \(name) \(framesName) \(strength): got \(picks) want \(want)")
    }
    if let moments = golden["moments"] as? [String: [[String: Any]]] {
        for (name, list) in moments {
            let got = built[name]?.sounds.compactMap { s in moment(s.tag).map { (s.ms, $0.rawValue) } } ?? []
            let want = list.compactMap { m -> (Double, String)? in
                guard let at = (m["ms"] as? NSNumber)?.doubleValue, let e = m["expression"] as? String else { return nil }
                return (at, e)
            }
            var same = got.count == want.count
            for k in 0..<min(got.count, want.count) where got[k].0 != want[k].0 || got[k].1 != want[k].1 { same = false }
            check(same, "golden moments \(name)")
        }
    } else { check(false, "golden moments present") }
} else {
    check(false, "timing-golden.json readable at \(goldenURL.path)")
}

// MARK: - WAV readers never assume 44 bytes

let body = json(webTrack)
let tracked = withTrack(pcmBytes: 48000)
let plain = wav([("fmt ", fmtBody())], pcmBytes: 48000)
let padded = 8 + body.count + body.count % 2
if let parsed = StreamingWavParser.parseHeader(tracked) {
    check(parsed.pcmStart == 44 + padded, "the streaming parser walks past kdtm to data (\(parsed.pcmStart))")
    check(parsed.format.sampleRate == 24000 && parsed.format.numChannels == 1, "the format survives the track")
} else { check(false, "the streaming parser reads a WAV with a track") }
check(StreamingWavParser.parseHeader(plain)?.pcmStart == 44, "a plain WAV still starts at 44")
check(StreamingWavParser.pcmDuration(tracked) == 1.0, "duration counts only the audio, not the track")
if let replay = StreamingWavParser.completedWAV(wav([("fmt ", fmtBody()), ("kdtm", body)], pcmBytes: 48000,
                                                    riffSize: 0xFFFF_FFFF, dataSize: 0xFFFF_FFFF)) {
    check(KadeTimingTrack.layout(replay)?.dataDeclared == 48000, "a completed streamed WAV gets its real data size")
    check(replay.suffix(48000) == tracked.suffix(48000), "every PCM byte is kept")
} else { check(false, "a completed streamed WAV with a track") }

let layout = KadeTimingTrack.layout(tracked)
check(layout?.dataStart == 44 + padded && layout?.dataDeclared == 48000 && layout?.byteRate == 48000,
      "layout finds data past the track")
check(KadeTimingTrack.read(wav: tracked) != nil, "a track that fits its 1.0 s of audio is read")
check(KadeTimingTrack.read(wav: withTrack(pcmBytes: 4800)) == nil, "a track 0.9 s off its audio is refused")
check(KadeTimingTrack.read(wav: plain) == nil, "no track, nothing read")
let header = tracked.prefix(44 + padded + 100)
check(KadeTimingTrack.read(wav: Data(header), headerOnly: true) != nil, "a buffered response's header proves the fit")
let sentinel = wav([("fmt ", fmtBody()), ("kdtm", body)], pcmBytes: 48000, riffSize: 0xFFFF_FFFF, dataSize: 0xFFFF_FFFF)
check(KadeTimingTrack.read(wav: Data(sentinel.prefix(44 + padded + 100)), headerOnly: true) == nil,
      "a streamed header with no real size never claims a track")

// The chunk is cut out before Apple's parsers see it: exactly the plain WAV.
check(KadeTimingTrack.strippingTrack(tracked) == plain, "stripping gives the plain WAV byte for byte")
check(KadeTimingTrack.strippingTrack(plain) == plain, "a WAV with no track is untouched")
var oddBody = body
if oddBody.count % 2 == 0 { oddBody += utf8(" ") } // an odd JSON length: the chunk gets a pad byte
let odd = wav([("fmt ", fmtBody()), ("kdtm", oddBody)], pcmBytes: 48000)
check(odd.count == plain.count + 8 + oddBody.count + 1, "the odd case really carries a pad byte")
check(KadeTimingTrack.parse(wav: odd) != nil, "an odd-length track still reads")
check(KadeTimingTrack.strippingTrack(odd) == plain, "the pad byte goes with the chunk")
let streamedPlain = wav([("fmt ", fmtBody())], pcmBytes: 48000, riffSize: 0xFFFF_FFFF, dataSize: 0xFFFF_FFFF)
check(KadeTimingTrack.strippingTrack(sentinel) == streamedPlain, "a streamed size sentinel stays a sentinel")
check(KadeTimingTrack.strippingTrack(Data("ID3abc".utf8)) == Data("ID3abc".utf8), "not a WAV: untouched")
check(StreamingWavParser.parseHeader(KadeTimingTrack.strippingTrack(tracked))?.pcmStart == 44, "stripped audio starts at 44")

// MARK: - The presentation, the call timeline and the puppet engine

let fitted = KadeTimingTrack.read(wav: tracked)!
let playing = CharacterPresentation(activity: .speaking, elapsed: 0.26, outputPhase: .playing).timed(fitted)
check(playing.timingTrack != nil, "the presentation carries the track")
check(playing.timingPanel(strength: 0.4) == fitted.panel(atMs: 300, strength: 0.4), "the mouth leads the sound by 40 ms")
check(CharacterPresentation(activity: .speaking, elapsed: 0.26, outputPhase: .paused).timed(fitted)
      .timingPanel(strength: 0.4) == nil, "a paused clip falls back")
check(CharacterPresentation(activity: .speaking, elapsed: 0.26, outputPhase: .playing).timingPanel(strength: 0.4) == nil,
      "no track falls back")
check(CharacterPresentation(activity: .speaking, elapsed: 0.9, outputPhase: .playing).timed(fitted)
      .timingPanel(strength: 0.4) == nil, "outside coverage falls back")
let laughing = CharacterPresentation(activity: .speaking, elapsed: 0.45, outputPhase: .playing).timed(fitted)
check(laughing.laughing && laughing.expression == .amused && laughing.face == .laugh, "the laugh shows when it is heard")
let after2 = CharacterPresentation(activity: .speaking, expression: .warm, elapsed: 1.3, outputPhase: .playing).timed(fitted)
check(!after2.laughing && after2.expression == .warm, "and is gone 0.8 s later")
check(!CharacterPresentation(activity: .speaking, elapsed: 0.2, outputPhase: .playing).timed(fitted).laughing,
      "not before it")

var timeline = CharacterPlaybackTimeline()
let speaker = "agent_test"
let identity = CharacterAudioIdentity(speakerID: speaker, speech: true, expression: "neutral", moment: nil)
timeline.append(identity: identity, duration: 1.0, now: 0, track: fitted)
timeline.append(identity: identity, duration: 0.5, now: 0)
let onClip = timeline.presentation(at: 0.26, expectedID: speaker)
check(onClip?.timingTrack != nil && onClip?.timingPanel(strength: 0.4) == fitted.panel(atMs: 300, strength: 0.4),
      "a call clip with a track drives the mouth")
check(timeline.presentation(at: 1.2, expectedID: speaker)?.timingTrack == nil, "a call clip without one falls back")
let heard = timeline.heardPosition(at: 0.5)
check(heard == CharacterPlaybackTimeline.HeardPosition(clipsStarted: 2, clipNumber: 1, elapsedMs: 500,
      durationMs: 1000, speakerID: speaker, wordsHeard: ["Hello", "there"]),
      "the interrupt hook knows the clip, the time and the whole words heard (\(String(describing: heard)))")
check(timeline.heardPosition(at: 1.25)?.clipNumber == 2 && timeline.heardPosition(at: 1.25)?.wordsHeard == nil,
      "the second clip, with no track")
check(timeline.heardPosition(at: 2)?.clipNumber == 0, "after the last clip nothing is audible")
timeline.reset()
check(timeline.heardPosition(at: 0) == nil, "a reset timeline has no position")

func mouth(_ viseme: Int?, frames: Int = 30) -> [Double] {
    let motion = PuppetMotion(seed: 7)
    var out: [Double] = []
    for _ in 0..<frames {
        out = motion.update(dt: 1.0 / 24, input: PuppetMotion.Input(speaking: true, level: 0.6, viseme: viseme))
    }
    return out
}
func channel(_ values: [Double], _ c: PuppetChannel) -> Double { c.rawValue < values.count ? values[c.rawValue] : 0 }
let pressed = mouth(6), spread = mouth(5), rounded = mouth(3)
check(channel(pressed, .mouthPress) > 0.3 && channel(pressed, .mouthWide) < 0.05, "a tracked p/b/m presses the lips")
check(channel(spread, .mouthWide) > channel(spread, .mouthRound) + 0.2, "a tracked ee spreads them")
check(channel(rounded, .mouthRound) > channel(rounded, .mouthWide) + 0.2, "a tracked oh rounds them")
let untracked = mouth(nil), again = mouth(nil)
check(untracked == again, "with no track the engine is unchanged and deterministic")
check(mouth(42) == untracked, "an out-of-range panel is ignored, never a crash")

// MARK: - When the app asks

let suite = "kade.timing.tests.\(UUID().uuidString)"
if let defaults = UserDefaults(suiteName: suite) {
    let demand = KadeFaceTimingDemand()
    check(!KadeFaceTimings.shouldAsk(agentID: speaker, demand: demand, defaults: defaults), "no face showing: no ask")
    demand.appeared(speaker); demand.appeared(speaker); demand.disappeared(speaker)
    check(KadeFaceTimings.shouldAsk(agentID: speaker, demand: demand, defaults: defaults), "a face showing: ask")
    check(!KadeFaceTimings.shouldAsk(agentID: "agent_other", demand: demand, defaults: defaults), "only for that speaker")
    check(!KadeFaceTimings.shouldAsk(agentID: nil, demand: demand, defaults: defaults), "no speaker: no ask")
    check(KadeFaceTimings.shouldAskOnCall(agentID: speaker, defaults: defaults), "a call with a character asks")
    check(!KadeFaceTimings.shouldAskOnCall(agentID: nil, defaults: defaults), "a Spotter call with no character does not")
    defaults.set(false, forKey: KadeTimingTrack.switchKey)
    check(!KadeFaceTimings.shouldAsk(agentID: speaker, demand: demand, defaults: defaults)
          && !KadeFaceTimings.shouldAskOnCall(agentID: speaker, defaults: defaults), "the local switch turns it off")
    defaults.removeObject(forKey: KadeTimingTrack.switchKey)
    defaults.set(false, forKey: KadeFaceTimings.portraitsKey)
    check(!KadeFaceTimings.shouldAskOnCall(agentID: speaker, defaults: defaults), "portraits off: no ask")
    defaults.removePersistentDomain(forName: suite)
    demand.disappeared(speaker); demand.disappeared(speaker)
    check(!demand.isShowing(speaker), "counts never go below zero")
} else { check(false, "a test defaults suite") }

print("timing tracks: \(count) checks, \(failures.count) failures")
for failure in failures.prefix(40) { print("FAIL: \(failure)") }
exit(failures.isEmpty ? 0 : 1)
