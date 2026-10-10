import Foundation

/// Original vector artwork shared with Angel's neutral SVG avatar. The narrow
/// command vocabulary is data, never executable source or a general SVG parser.
struct CharacterAngelVectorArt: Decodable {
    struct Command: Decodable {
        let op: String
        let v: [Double]
        var isValid: Bool {
            let lengths = ["M": 2, "L": 2, "Q": 4, "C": 6, "Z": 0]
            guard let count = lengths[op], v.count == count else { return false }
            return v.allSatisfy { $0.isFinite && (-128...1152).contains($0) }
        }
    }
    struct Shape: Decodable {
        let id: String
        let group: String
        let path: [Command]
        let fill: String
        let stroke: String?
        let strokeWidth: Double?
        let opacity: Double?
    }
    struct Stop: Decodable {
        let at: Double
        let color: String
        let opacity: Double?
    }
    struct Paint: Decodable {
        let kind: String
        let start: [Double]?
        let end: [Double]?
        let center: [Double]?
        let radius: Double?
        let stops: [Stop]
    }
    struct Eye: Decodable {
        let cx: Double
        let cy: Double
        let width: Double
        let height: Double
        let irisRadius: Double
    }
    struct Mouth: Decodable {
        let cx: Double
        let cy: Double
        let width: Double
        let height: Double
    }
    struct Cheek: Decodable {
        let cx: Double
        let cy: Double
        let rx: Double
        let ry: Double
    }
    struct Features: Decodable {
        let eyes: [Eye]
        let mouth: Mouth
        let cheeks: [Cheek]
    }

    let schema: Int
    let canvas: Double
    let shapes: [Shape]
    let gradients: [String: Paint]
    let pivots: [String: [Double]]
    let features: Features
    static let groups = ["leftWing", "rightWing", "body", "head", "halo"]

    static func colorIsValid(_ value: String) -> Bool {
        guard value.first == "#", [4, 7, 9].contains(value.count) else { return false }
        return value.dropFirst().allSatisfy { $0.isHexDigit }
    }

    var isValid: Bool {
        func point(_ values: [Double]?) -> Bool {
            guard let values, values.count == 2 else { return false }
            return values.allSatisfy { $0.isFinite && (0...canvas).contains($0) }
        }
        func fraction(_ value: Double?) -> Bool {
            value.map { $0.isFinite && (0...1).contains($0) } ?? true
        }
        guard schema == 1, canvas == 1024, !shapes.isEmpty, shapes.count <= 1500,
              Set(shapes.map(\.id)).count == shapes.count,
              Set(shapes.map(\.group)) == Set(Self.groups),
              Set(pivots.keys) == Set(Self.groups),
              pivots.values.allSatisfy({ point($0) }), gradients.count <= 64 else { return false }
        for paint in gradients.values {
            guard (2...12).contains(paint.stops.count),
                  paint.stops.allSatisfy({ $0.at.isFinite && (0...1).contains($0.at)
                      && Self.colorIsValid($0.color) && fraction($0.opacity) }),
                  zip(paint.stops, paint.stops.dropFirst()).allSatisfy({ pair in pair.0.at <= pair.1.at }) else { return false }
            if paint.kind == "linear" {
                guard point(paint.start), point(paint.end), paint.start != paint.end else { return false }
            } else if paint.kind == "radial" {
                guard point(paint.center), let radius = paint.radius,
                      radius.isFinite, radius > 0, radius <= canvas * 2 else { return false }
            } else { return false }
        }
        for shape in shapes {
            guard !shape.id.isEmpty, shape.id.count <= 128,
                  (2...80).contains(shape.path.count), shape.path.first?.op == "M",
                  shape.path.allSatisfy(\.isValid), fraction(shape.opacity),
                  shape.fill == "none" || Self.colorIsValid(shape.fill) || gradients[shape.fill] != nil,
                  shape.stroke.map({ Self.colorIsValid($0) || gradients[$0] != nil }) ?? true,
                  shape.strokeWidth.map({ $0.isFinite && $0 > 0 && $0 <= 30 }) ?? true,
                  (shape.stroke == nil) == (shape.strokeWidth == nil) else { return false }
        }
        guard features.eyes.count == 2, features.cheeks.count == 2 else { return false }
        for eye in features.eyes {
            guard point([eye.cx, eye.cy]), [eye.width, eye.height, eye.irisRadius].allSatisfy(\.isFinite),
                  (60...200).contains(eye.width), (35...150).contains(eye.height),
                  (10...70).contains(eye.irisRadius), eye.irisRadius < eye.width / 2 else { return false }
        }
        let mouth = features.mouth
        guard point([mouth.cx, mouth.cy]), [mouth.width, mouth.height].allSatisfy(\.isFinite),
              (60...200).contains(mouth.width), (30...160).contains(mouth.height) else { return false }
        return features.cheeks.allSatisfy {
            point([$0.cx, $0.cy]) && [$0.rx, $0.ry].allSatisfy(\.isFinite)
                && (10...100).contains($0.rx) && (10...70).contains($0.ry)
        }
    }
}

/// Common identity/size rule for raster busts and Angel's vector puppet. This
/// only recognizes art; it never adds a server agent to the signed-in roster.
enum CharacterPuppetRegistration {
    static func approved(stage: Bool, side: Double,
                         agentID: String?, avatarPath: String?) -> Bool {
        guard stage, side.isFinite, side >= 160,
              CharacterMotion.prepared(id: agentID, path: avatarPath) else { return false }
        return agentID == CharacterMotion.angelID || CharacterBustArtwork.approved(
            stage: stage, side: side, agentID: agentID, avatarPath: avatarPath) != nil
    }
}
