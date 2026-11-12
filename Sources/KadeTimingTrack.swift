import Foundation

/* Nov 11 2026: THE FACE TRACK INWORLD'S OWN TIMING DATA GIVES.
 *
 * A line-for-line port of the website's
 * client/src/components/Chat/character/timing-track.mjs (fork c31def456).
 * When a request asks for it (`timing: true` on read-aloud and auto-read,
 * `faces: true` in a call's hello), the voice proxy puts a small JSON
 * "timing track" inside the WAV as a `kdtm` chunk between `fmt ` and `data`:
 *
 *   { v: 1, src: "inworld", set: "oxr" | "iw11", dur,
 *     vis: [[start, end, shape]], w?: [[start, end, text]], cov: [[start, end]] }
 *
 * Integer milliseconds from the first sample of `data`. `vis` says which mouth
 * shape shows at every moment (Inworld's lip-sync, derived from the audio,
 * laughs included); `cov` says which stretches it speaks for.
 *
 * Two jobs here, both pure Foundation so TimingTrackTests can run them:
 *  1. WAV safety. A WAV with a track no longer has its audio at byte 44.
 *     Every reader in this app already walks the chunks (StreamingWavParser,
 *     and Apple's own AVAudioPlayer / AVAudioFile), and `strippingTrack`
 *     removes the chunk before Apple's parsers ever see it, so the bytes they
 *     get are the plain WAV they always got.
 *  2. The mouth. The 15 OpenXR shapes (or Inworld's 11 phone classes) map onto
 *     the nine mouth-sheet panels every rig uses; each frame shows the shape
 *     that fills most of it, a lip closure (p, b, m, f, v) never vanishes
 *     between frames, and the lips lead the sound by 40 ms. Outside the
 *     track's coverage, or with no track (Fish voices, the streamed lane, old
 *     clips), the callers keep the loudness and viseme hash, unchanged.
 *
 * Not ported: `wordAnchors` (the app speaks one sentence per clip and only a
 * clip's leading direction moves the face, so there is no mid-clip direction
 * to place). The bracketed sounds ([laugh], [sigh]) ARE ported as moments.
 *
 * Golden picks: TimingTrackTests/timing-golden.json is written from the
 * website's own module (dev/timing-track/golden.mjs). Change both together.
 */
struct KadeTimingTrack {
    enum ShapeSet: String { case oxr, iw11 }
    struct Span { let start: Double; let end: Double; let shape: String }
    struct Word { let start: Double; let end: Double; let text: String }
    struct Cover { let start: Double; let end: Double }

    static let version = 1
    static let maxBytes = 512 * 1024
    /// Lips move just ahead of the sound they make.
    static let leadMs = 40.0
    /// Half a frame: each frame shows the shape that fills most of a 50 ms
    /// window, so consecutive 24 fps frames leave no moment unseen.
    static let halfFrameMs = 25.0
    /// A closure wins its frame when it fills 10 ms of it, or half of itself
    /// when shorter than 20 ms.
    static let closureMs = 10.0
    /// A track belongs to its own take: its `dur` within 250 ms of the audio.
    static let fitToleranceMs = 250.0
    static let loud = 0.55
    static let quiet = 0.25
    /// Local off switch (the website's localStorage kadeFaceTimings = '0').
    static let switchKey = "kadeFaceTimings"

    let set: ShapeSet
    let durationMs: Double
    let spans: [Span]
    let words: [Word]
    let coverage: [Cover]

    // MARK: - The table every rig shares

    /// Mouth sheet panels: 0 closed, 1 slightly open, 2 open, 3 round "oh",
    /// 4 pursed "oo", 5 spread "ee", 6 pressed, 7 teeth nearly together,
    /// 8 wide open (CharacterMotion.viseme, the sheet rig, Angel's mouth roles,
    /// the puppet engine and the living paintings all use this index). One
    /// value, or [quiet, normal, loud].
    static let oxrPanels: [String: [Int]] = [
        "sil": [0], "PP": [6], "FF": [7], "TH": [1], "DD": [1], "kk": [1, 1, 2],
        "CH": [7], "SS": [7], "nn": [1], "RR": [4], "aa": [2, 2, 8], "E": [5],
        "ih": [1, 5, 5], "oh": [3], "ou": [4],
    ]
    static let iw11Panels: [String: [Int]] = [
        "sil": [0], "bmp": [6], "aei": [2, 2, 8], "o": [3], "ee": [5], "fv": [7],
        "th": [1], "l": [1], "r": [4], "qw": [4], "u": [4], "chjsh": [7], "cdgknstxyz": [1],
    ]
    static let closures: Set<String> = ["PP", "FF", "bmp", "fv"]

    /// The panel for one shape at a given loudness (0...1, the strength
    /// CharacterMotion.pose computes as `mouth`), or nil for an unknown shape.
    static func shapePanel(_ shape: String, set: ShapeSet, strength: Double = 0.4) -> Int? {
        let table = set == .oxr ? oxrPanels : iw11Panels
        guard let entry = table[shape], !entry.isEmpty else { return nil }
        if entry.count < 3 { return entry[0] }
        if strength >= loud { return entry[2] }
        return strength < quiet ? entry[0] : entry[1]
    }

    /// The website's voiceMessagePose strength, from a player's output level.
    static func strength(level: Double) -> Double {
        level.isFinite ? max(0, min(1, (level - 0.008) * 5)) : 0
    }

    // MARK: - Reading a WAV

    /// Where things sit in a RIFF/WAVE buffer, found by walking the chunks of
    /// the FIRST RIFF only. Never trusts a fixed 44-byte header.
    struct Layout {
        /// fmt's byte rate (bytes of audio per second), when fmt was seen.
        var byteRate: Double?
        /// Offset of the first PCM byte (just past the data chunk header).
        var dataStart: Int?
        /// The data chunk's declared size; nil for the streaming sentinel.
        var dataDeclared: Int?
        /// The kdtm chunk's whole extent, header and pad byte included.
        var trackChunk: Range<Int>?
        /// The kdtm payload.
        var trackBody: Range<Int>?
        /// The RIFF size field said 0xFFFFFFFF (the streamed lane).
        var streamingSizes = false
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i]) | (UInt32(data[i + 1]) << 8) | (UInt32(data[i + 2]) << 16) | (UInt32(data[i + 3]) << 24)
    }

    private static func id(_ data: Data, _ offset: Int, is text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard offset >= 0, offset + bytes.count <= data.count else { return false }
        for k in 0..<bytes.count where data[data.startIndex + offset + k] != bytes[k] { return false }
        return true
    }

    /// Walks to `data`. Nil when this is not a RIFF/WAVE buffer.
    static func layout(_ data: Data) -> Layout? {
        guard data.count >= 12, id(data, 0, is: "RIFF"), id(data, 8, is: "WAVE") else { return nil }
        var result = Layout()
        let riff = u32(data, 4)
        result.streamingSizes = riff == 0xFFFF_FFFF
        let end = min(data.count, 8 + Int(riff))
        var at = 12
        while at + 8 <= end {
            let size = Int(u32(data, at + 4))
            if id(data, at, is: "fmt ") {
                if at + 8 + 12 <= data.count {
                    let rate = Double(u32(data, at + 8 + 8))
                    if rate > 0 { result.byteRate = rate }
                }
            } else if id(data, at, is: "kdtm") {
                if result.trackChunk == nil {
                    let bodyEnd = at + 8 + size
                    result.trackBody = at + 8 ..< max(at + 8, min(bodyEnd, end))
                    result.trackChunk = at ..< max(at + 8, min(bodyEnd + size % 2, end))
                }
            } else if id(data, at, is: "data") {
                result.dataStart = at + 8
                result.dataDeclared = size == 0xFFFF_FFFF || result.streamingSizes ? nil : size
                return result
            }
            at += 8 + size + size % 2
        }
        return result
    }

    /// The track a WAV carries, unchecked against the audio's length; nil for
    /// no kdtm chunk, a chunk after `data`, broken JSON, another version, a
    /// chunk over 512 KB, or spans that are not sorted. Never throws.
    /// (The website's readTimingTrack.)
    static func parse(wav data: Data) -> KadeTimingTrack? {
        guard let walk = Self.layout(data), let body = walk.trackBody,
              let chunk = walk.trackChunk else { return nil }
        let declared = Int(u32(data, chunk.lowerBound + 4))
        guard declared <= maxBytes, body.count == declared else { return nil }
        let slice = data.subdata(in: data.startIndex + body.lowerBound ..< data.startIndex + body.upperBound)
        return parse(json: slice)
    }

    /// The track, only when it belongs to this WAV's own audio (its `dur`
    /// within 250 ms of the data chunk). `headerOnly`: the buffer is just the
    /// start of a streamed response, so only a real declared data size can
    /// prove the fit (the streaming sentinel never carries a track anyway).
    static func read(wav data: Data, headerOnly: Bool = false) -> KadeTimingTrack? {
        guard let walk = Self.layout(data), let track = Self.parse(wav: data),
              let rate = walk.byteRate, rate > 0, let start = walk.dataStart else { return nil }
        let available = max(0, data.count - start)
        let bytes: Int
        if headerOnly {
            guard let declared = walk.dataDeclared else { return nil }
            bytes = declared
        } else {
            bytes = walk.dataDeclared.map { min($0, available) } ?? available
        }
        return track.fits(seconds: Double(bytes) / rate) ? track : nil
    }

    /// The same WAV with the kdtm chunk cut out and the RIFF size fixed, so
    /// AVAudioPlayer / AVAudioFile see exactly the plain WAV they always got.
    /// A WAV with no track comes back byte for byte; anything that is not a
    /// RIFF/WAVE buffer comes back untouched.
    static func strippingTrack(_ data: Data) -> Data {
        guard let walk = Self.layout(data), let chunk = walk.trackChunk,
              chunk.upperBound <= data.count else { return data }
        var out = Data(capacity: data.count - chunk.count)
        out.append(data.subdata(in: data.startIndex ..< data.startIndex + chunk.lowerBound))
        out.append(data.subdata(in: data.startIndex + chunk.upperBound ..< data.endIndex))
        if !walk.streamingSizes {
            let size = UInt32(clamping: max(0, out.count - 8))
            for k in 0..<4 { out[out.startIndex + 4 + k] = UInt8(truncatingIfNeeded: size >> (UInt32(k) * 8)) }
        }
        return out
    }

    // MARK: - Reading the JSON

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    /// [start, end, ...] with 0 <= start < end, both finite.
    private static func span(_ value: Any?) -> (start: Double, end: Double, items: [Any])? {
        guard let a = value as? [Any], a.count >= 2, let s = number(a[0]), let e = number(a[1]),
              e > s, s >= 0 else { return nil }
        return (s, e, a)
    }

    static func parse(json: Data) -> KadeTimingTrack? {
        guard let object = try? JSONSerialization.jsonObject(with: json, options: []) else { return nil }
        return make(object)
    }

    /// The website's validTrack, then the typed track.
    static func make(_ object: Any) -> KadeTimingTrack? {
        guard let track = object as? [String: Any], number(track["v"]) == Double(version),
              let setName = track["set"] as? String, let set = ShapeSet(rawValue: setName),
              let dur = number(track["dur"]), dur > 0,
              let vis = track["vis"] as? [Any], !vis.isEmpty,
              let cov = track["cov"] as? [Any], !cov.isEmpty else { return nil }
        var spans: [Span] = []
        spans.reserveCapacity(vis.count)
        for item in vis {
            guard let found = span(item), found.items.count >= 3,
                  let shape = found.items[2] as? String else { return nil }
            if let last = spans.last, found.start < last.end { return nil } // sorted, no overlap
            spans.append(Span(start: found.start, end: found.end, shape: shape))
        }
        var coverage: [Cover] = []
        for item in cov {
            guard let found = span(item) else { return nil }
            if let last = coverage.last, found.start < last.end { return nil }
            coverage.append(Cover(start: found.start, end: found.end))
        }
        var words: [Word] = []
        if let raw = track["w"] {
            guard let list = raw as? [Any] else { return nil }
            for item in list {
                guard let a = item as? [Any], a.count >= 3, let s = number(a[0]), let e = number(a[1]),
                      let text = a[2] as? String else { return nil }
                // A real span, or a zero-length word (Inworld times some that way).
                guard (e > s && s >= 0) || e == s else { return nil }
                if let last = words.last, s < last.start { return nil }
                words.append(Word(start: s, end: e, text: text))
            }
        }
        return KadeTimingTrack(set: set, durationMs: dur, spans: spans, words: words, coverage: coverage)
    }

    // MARK: - The mouth at a moment

    /// The track only if it belongs to audio of this length (seconds).
    func fits(seconds: Double) -> Bool {
        seconds.isFinite && abs(durationMs - seconds * 1000) <= Self.fitToleranceMs
    }

    /// First index whose end is after `ms`.
    private static func firstEndingAfter(_ ends: (Int) -> Double, count: Int, _ ms: Double) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ends(mid) <= ms { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func covered(atMs ms: Double) -> Bool {
        guard ms.isFinite else { return false }
        let i = Self.firstEndingAfter({ coverage[$0].end }, count: coverage.count, ms)
        return i < coverage.count && coverage[i].start <= ms
    }

    /// The shape at one instant, nil outside coverage. Covered time with no
    /// span is "sil". (The website's trackAt.)
    func shape(atMs ms: Double) -> String? {
        guard covered(atMs: ms) else { return nil }
        let i = Self.firstEndingAfter({ spans[$0].end }, count: spans.count, ms)
        return i < spans.count && spans[i].start <= ms ? spans[i].shape : "sil"
    }

    /// The mouth panel for the frame around `ms`, or nil when the track does
    /// not speak for this moment: the caller then uses its loudness method.
    /// The frame shows the shape that fills most of it, except that a lip
    /// closure of 10 ms or more wins. (The website's trackPanelAt.)
    func panel(atMs ms: Double, strength: Double = 0.4) -> Int? {
        guard ms.isFinite, covered(atMs: ms) else { return nil }
        let a = ms - Self.halfFrameMs, b = ms + Self.halfFrameMs
        // Insertion order matters: the first shape to reach the largest
        // weight wins a tie, as in the website's Map.
        var order: [String] = []
        var weight: [String: Double] = [:]
        var spoken = 0.0
        var closure: String?
        var closureOverlap = 0.0
        var i = Self.firstEndingAfter({ spans[$0].end }, count: spans.count, a)
        while i < spans.count && spans[i].start < b {
            let span = spans[i]
            i += 1
            let overlap = min(b, span.end) - max(a, span.start)
            if overlap <= 0 { continue }
            spoken += overlap
            if weight[span.shape] == nil { order.append(span.shape) }
            weight[span.shape, default: 0] += overlap
            if Self.closures.contains(span.shape),
               overlap >= min(Self.closureMs, (span.end - span.start) / 2),
               overlap > closureOverlap {
                closure = span.shape
                closureOverlap = overlap
            }
        }
        if let closure { return Self.shapePanel(closure, set: set, strength: strength) }
        // Covered time with no span is a closed mouth (the seam between pieces).
        let gap = max(0, b - a - spoken)
        if gap > 0 {
            if weight["sil"] == nil { order.append("sil") }
            weight["sil", default: 0] += gap
        }
        var best = "sil", most = -1.0
        for shape in order {
            let w = weight[shape] ?? 0
            if w > most { best = shape; most = w }
        }
        return Self.shapePanel(best, set: set, strength: strength) ?? 0
    }

    /// The panel for a clip's playhead (seconds into this clip's audio), drawn
    /// `leadMs` ahead of the sound.
    func panel(atSeconds seconds: Double, strength: Double) -> Int? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return panel(atMs: seconds * 1000 + Self.leadMs, strength: strength)
    }

    // MARK: - Little sounds and heard words

    /// The bracketed sounds the voice made ([laugh], [sigh]...), with their
    /// start times. The caller turns a tag into a face moment the same way a
    /// leading %%%laugh%%% direction does (CharacterCue).
    var sounds: [(ms: Double, tag: String)] {
        words.compactMap { (word: Word) -> (ms: Double, tag: String)? in
            let text = word.text
            guard text.count >= 3, text.count <= 42, text.hasPrefix("["), text.hasSuffix("]") else { return nil }
            let inner = String(text.dropFirst().dropLast())
            guard !inner.isEmpty, !inner.contains("]"), !inner.contains("\n") else { return nil }
            return (word.start, inner)
        }
    }

    /// Spoken words (no bracketed sounds) that had ENDED by `ms`: what a
    /// listener heard in full before an interruption at that moment.
    func wordsHeard(beforeMs ms: Double) -> [String] {
        guard ms.isFinite else { return [] }
        return words.filter { $0.end <= ms && !($0.text.hasPrefix("[") && $0.text.hasSuffix("]")) }.map(\.text)
    }
}

/// When the app asks the voice lane for timing tracks: only while a face that
/// can use one is showing, the portrait setting is on, and the local switch
/// (UserDefaults `kadeFaceTimings`, absent = on) has not turned it off.
/// Asking costs no extra characters (measured Nov 11 2026), and without an
/// ask every response is byte-identical to before.
enum KadeFaceTimings {
    static let portraitsKey = "kadeVoicePortraits"

    static func allowed(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: KadeTimingTrack.switchKey) as? Bool) != false
            && (defaults.object(forKey: portraitsKey) as? Bool) != false
    }

    /// Read-aloud and auto-read: a face for this speaker is on screen now.
    static func shouldAsk(agentID: String?, demand: KadeFaceTimingDemand = .shared,
                          defaults: UserDefaults = .standard) -> Bool {
        guard let agentID, !agentID.isEmpty, allowed(defaults) else { return false }
        return demand.isShowing(agentID)
    }

    /// A call with a character: the call stage always draws that character's
    /// face while the portrait setting is on (CallView.callPortrait).
    static func shouldAskOnCall(agentID: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let agentID, !agentID.isEmpty else { return false }
        return allowed(defaults)
    }
}

/// Which characters have a portrait on screen right now. Portraits report
/// their own appear/disappear; a count per character, so two portraits of
/// the same face (a row and the stage) never cancel each other.
final class KadeFaceTimingDemand: @unchecked Sendable {
    static let shared = KadeFaceTimingDemand()
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func appeared(_ agentID: String?) {
        guard let agentID, !agentID.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        counts[agentID, default: 0] += 1
    }

    func disappeared(_ agentID: String?) {
        guard let agentID, !agentID.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let next = (counts[agentID] ?? 0) - 1
        counts[agentID] = next > 0 ? next : nil
    }

    func isShowing(_ agentID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (counts[agentID] ?? 0) > 0
    }
}
