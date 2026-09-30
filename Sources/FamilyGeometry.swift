import Foundation

// MARK: - Family history: drawing maths (Sep 29 2026)
//
// The few numbers Swift works out itself. The server already did the hard
// part (the tree in box units, the timeline lanes, the caption cues); this
// only turns those into points. Foundation only, in Doubles, so
// run-family-tests.sh checks it on Linux; the views convert to CGFloat.

struct FHPoint: Equatable {
    var x: Double
    var y: Double
}

/// A slice of the DNA fan, in degrees. 0 points right and angles grow
/// clockwise on screen, so the upper half of the circle runs 180 to 360.
struct FHArc: Equatable {
    var start: Double
    var end: Double

    var sweep: Double { end - start }
    var middle: Double { (start + end) / 2 }
}

/// The tree chart's three size steps. A bigger step lays the tree out again
/// with bigger boxes (text stays sharp), rather than zooming a picture of it.
enum FamilyTreeScale: String, CaseIterable {
    case fit, normal, large

    var factor: Double {
        switch self {
        case .fit: return 0.75
        case .normal: return 1.0
        case .large: return 1.35
        }
    }
}

/// Box sizes for the chart, in points, before a size step.
struct FamilyTreeMetrics: Equatable {
    var boxWidth: Double = 150
    var boxHeight: Double = 124
    var gapX: Double = 16
    var rowHeight: Double = 164

    func scaled(_ scale: FamilyTreeScale) -> FamilyTreeMetrics {
        let f = scale.factor
        return FamilyTreeMetrics(boxWidth: boxWidth * f, boxHeight: boxHeight * f, gapX: gapX * f, rowHeight: rowHeight * f)
    }

    /// The top-left corner of a box at `x` box units along row `row`.
    func origin(x: Double, row: Int) -> FHPoint {
        FHPoint(x: x * (boxWidth + gapX), y: Double(row) * rowHeight)
    }

    /// The middle of that box (where SwiftUI's .position puts it).
    func center(x: Double, row: Int) -> FHPoint {
        let o = origin(x: x, row: row)
        return FHPoint(x: o.x + boxWidth / 2, y: o.y + boxHeight / 2)
    }

    /// The whole chart: `width` box units wide, `rows` rows high.
    func canvas(width: Double, rows: Int) -> FHPoint {
        let w = max(0, width) * (boxWidth + gapX) - gapX
        let h = Double(max(0, rows - 1)) * rowHeight + boxHeight
        return FHPoint(x: max(boxWidth, w), y: max(boxHeight, h))
    }
}

enum FamilyGeometry {
    // MARK: Home: the faces on a gentle arc

    /// Centres for `count` faces of size `face` in a frame, the middle ones
    /// highest, every face wholly inside the frame.
    static func faceArc(count: Int, width: Double, height: Double, face: Double) -> [FHPoint] {
        guard count > 0, width > 0, height > 0 else { return [] }
        let size = min(face, width, height)
        let half = size / 2
        let top = half
        let bottom = max(top, height - half)
        let sag = min(bottom - top, size * 0.5)
        if count == 1 { return [FHPoint(x: width / 2, y: top)] }
        let left = half
        let right = max(left, width - half)
        let step = (right - left) / Double(count - 1)
        let middle = (left + right) / 2
        let reach = max(1, (right - left) / 2)
        return (0..<count).map { (i: Int) -> FHPoint in
            let x = left + Double(i) * step
            let t = abs(x - middle) / reach
            return FHPoint(x: x, y: top + sag * t * t)
        }
    }

    // MARK: DNA: the paper fan

    /// `count` equal slices of a fan. The whole fan is the upper half circle
    /// (180°); a half fan (one side of the family) is a quarter (90°), the
    /// left quarter for a father's side, the right for a mother's.
    static func fanWedges(count: Int, half: Bool, rightSide: Bool = false) -> [FHArc] {
        guard count > 0 else { return [] }
        let sweep: Double = half ? 90 : 180
        let from: Double = (half && rightSide) ? 270 : 180
        let each = sweep / Double(count)
        return (0..<count).map { (i: Int) -> FHArc in
            FHArc(start: from + Double(i) * each, end: from + Double(i + 1) * each)
        }
    }

    /// A point on a circle round `center`, `degrees` from the right and
    /// growing clockwise on screen (y grows downwards), so 270 is straight up.
    static func point(center: FHPoint, radius: Double, degrees: Double) -> FHPoint {
        let radians: Double = degrees * Double.pi / 180
        return FHPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
    }

    /// One wedge of a ring as a closed outline: out along the outer arc from
    /// its start to its end, then back along the inner arc. Points, never an
    /// arc call, so which way "clockwise" means can never flip the drawing.
    static func wedgeOutline(center: FHPoint, inner: Double, outer: Double, arc: FHArc, steps: Int = 12) -> [FHPoint] {
        let n: Int = max(1, steps)
        var out: [FHPoint] = []
        for i in 0...n {
            let t: Double = Double(i) / Double(n)
            out.append(point(center: center, radius: outer, degrees: arc.start + arc.sweep * t))
        }
        for i in 0...n {
            let t: Double = Double(i) / Double(n)
            out.append(point(center: center, radius: max(0, inner), degrees: arc.end - arc.sweep * t))
        }
        return out
    }

    /// How big a face sits in each wedge: big for parents and grandparents,
    /// small further out, none past 16 wedges (the list names them).
    static func fanFaceSize(slots: Int) -> Double {
        switch slots {
        case ...2: return 64
        case 3...4: return 56
        case 5...8: return 36
        case 9...16: return 22
        default: return 0
        }
    }

    // MARK: Where and when: a decade's band

    /// The middle of lane `lane` of `lanes` across a band `width` wide.
    static func laneX(lane: Int, lanes: Int, width: Double) -> Double {
        let n = max(1, lanes)
        let clamped = min(max(0, lane), n - 1)
        return (Double(clamped) + 0.5) * width / Double(n)
    }

    /// Where a year sits in a decade's band `height` high: the decade's end
    /// at the top, its start at the bottom ("scroll down to go back in time").
    static func yearY(_ year: Double, decade: Int, height: Double) -> Double {
        let start = Double(decade)
        let clamped = min(max(year, start), start + 10)
        return (start + 10 - clamped) / 10 * height
    }

    /// The part of a lifeline inside one decade's band (top and bottom), or
    /// nil when the life does not touch that decade.
    static func barSpan(from: Int, to: Int, decade: Int, height: Double) -> (top: Double, bottom: Double)? {
        let lo = Double(min(from, to))
        let hi = Double(max(from, to)) + 1
        let start = Double(decade)
        let end = start + 10
        guard hi > start, lo < end else { return nil }
        return (top: yearY(min(hi, end), decade: decade, height: height),
                bottom: yearY(max(lo, start), decade: decade, height: height))
    }

    // MARK: The map: a place's dot for one decade

    /// A dot's size and opacity from its count; a place with nobody that
    /// decade fades out instead of being removed (nothing is inserted or
    /// removed on the map, so nothing jumps).
    static func mapDot(count: Int, maxCount: Int, minSize: Double = 10, maxSize: Double = 36) -> (size: Double, opacity: Double) {
        guard count > 0, maxCount > 0 else { return (minSize, 0) }
        let ratio = min(1, Double(count) / Double(maxCount))
        return (minSize + (maxSize - minSize) * ratio.squareRoot(), 0.55 + 0.45 * ratio)
    }

    // MARK: Listen: the sentence being read

    /// The cue playing at `fraction` (0 to 1) of a part: the last cue that has
    /// started. Nil before the first.
    static func cueIndex(_ cues: [FHCue], at fraction: Double) -> Int? {
        var found: Int? = nil
        for (i, cue) in cues.enumerated() where cue.start <= fraction {
            found = i
        }
        return found
    }

    /// Whether a part's cues are in order, never overlap, and end at 1.
    static func cuesInOrder(_ cues: [FHCue], tolerance: Double = 0.001) -> Bool {
        guard let last = cues.last else { return true }
        var previousEnd = 0.0
        for cue in cues {
            if cue.start < previousEnd - tolerance || cue.end < cue.start { return false }
            previousEnd = cue.end
        }
        return abs(last.end - 1) <= tolerance
    }

    /// A part's cues in seconds: the server's own when it sent them, else
    /// the fraction cues stretched over the part's length.
    static func cuesInSeconds(_ timed: [FHCue], fractions: [FHCue], duration: Double) -> [FHCue] {
        if !timed.isEmpty { return timed }
        let length: Double = max(0, duration)
        return fractions.map { (cue: FHCue) -> FHCue in
            FHCue(text: cue.text, start: cue.start * length, end: cue.end * length)
        }
    }

    /// Letters and digits only, lower case: how a sentence is found in the
    /// paragraph it came from (spaces, chips and punctuation aside).
    static func sentenceKey(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// For every part and every sentence in it, the story block it is read
    /// from (-1 when it cannot be found). It reads on from where the last
    /// sentence was found (the rest of that block, then the blocks after),
    /// so a sentence that appears twice is found in reading order.
    static func cueBlocks(chunks: [FHChunk], blocks: [FHBlock]) -> [[Int]] {
        let keys: [String] = blocks.map { sentenceKey($0.plainText) }
        var at = 0
        var from: String.Index? = keys.first?.startIndex
        var out: [[Int]] = []
        for chunk in chunks {
            var row: [Int] = []
            for cue in chunk.cues {
                let needle: String = sentenceKey(cue.text)
                var found = -1
                if needle.isEmpty {
                    row.append(found)
                    continue
                }
                if at < keys.count, let start = from, start <= keys[at].endIndex,
                   let hit = keys[at].range(of: needle, range: start..<keys[at].endIndex) {
                    found = at
                    from = hit.upperBound
                } else {
                    var b = at + 1
                    while b < keys.count {
                        if let hit = keys[b].range(of: needle) {
                            found = b
                            at = b
                            from = hit.upperBound
                            break
                        }
                        b += 1
                    }
                    if found < 0, let first = keys.firstIndex(where: { $0.contains(needle) }),
                       let hit = keys[first].range(of: needle) {
                        found = first
                        at = first
                        from = hit.upperBound
                    }
                }
                row.append(found)
            }
            out.append(row)
        }
        return out
    }

    // MARK: Climb: the trail of faces back to you

    /// Keeps the first (you) and the last `keep - 1` steps, so the trail fits.
    static func trimTrail<T>(_ trail: [T], keep: Int) -> [T] {
        guard keep > 0 else { return [] }
        guard trail.count > keep else { return trail }
        if keep == 1 { return [trail[0]] }
        return [trail[0]] + Array(trail.suffix(keep - 1))
    }
}
