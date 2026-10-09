import Foundation

/// Invoke from the existing character model test main after adding the isolated
/// source to its compiler inputs. These are behavioral geometry checks, not
/// claims that the unintegrated drawing has passed native visual review.
func runAngelVectorMotionChecks(_ check: (Bool, String) -> Void) {
    func faceValues(_ pose: AngelVectorFacialPose) -> [Double] {
        [pose.leftEye, pose.rightEye, pose.leftBrow, pose.rightBrow,
         pose.leftBrowSlope, pose.rightBrowSlope, pose.gazeX, pose.gazeY,
         pose.smile, pose.cheekLift, pose.restingMouth]
    }
    func mouthValues(_ pose: AngelVectorMouthPose) -> [Double] {
        [pose.width, pose.aperture, pose.roundness, pose.smile,
         pose.upperTeeth, pose.lowerTeeth, pose.tongue]
    }
    func ornamentValues(_ pose: AngelVectorOrnamentPose) -> [Double] {
        [pose.leftWingDegrees, pose.rightWingDegrees, pose.haloOffsetY,
         pose.haloDegrees, pose.sparkle]
    }
    let faces = CharacterFace.allCases
    check(faces.count == 17, "Angel covers all seventeen semantic faces")
    let signatures = Set(faces.map {
        faceValues(AngelVectorMotion.facial($0, blink: 0, active: true)).map { String($0) }.joined(separator: ",")
    })
    check(signatures.count == faces.count, "Angel faces have distinct geometry")
    let neutral = AngelVectorMotion.facial(.neutral, blink: 0, active: true)
    let inactive = faceValues(AngelVectorMotion.facial(.delighted, blink: 1, active: false))
    check(inactive == faceValues(neutral), "Inactive Angel resets to neutral open-eyed still art")

    for face in faces {
        let open = AngelVectorMotion.facial(face, blink: 0, active: true)
        let closed = AngelVectorMotion.facial(face, blink: 1, active: true)
        check(closed.leftEye == 0 && closed.rightEye == 0, "Angel blink closes both eyes for \(face)")
        var previousLeft = open.leftEye
        var previousRight = open.rightEye
        var monotone = true
        var finite = true
        for tick in 0...100 {
            let pose = AngelVectorMotion.facial(face, blink: Double(tick) / 100, active: true)
            monotone = monotone && pose.leftEye <= previousLeft && pose.rightEye <= previousRight
            finite = finite && faceValues(pose).allSatisfy(\.isFinite)
            previousLeft = pose.leftEye
            previousRight = pose.rightEye
        }
        check(monotone && finite, "Angel blink shrinks a finite aperture continuously for \(face)")
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            check(faceValues(AngelVectorMotion.facial(face, blink: invalid, active: true)) == faceValues(open),
                  "Invalid blink leaves authored eyes open for \(face)")
        }
        check(AngelVectorMotion.facial(face, blink: 2, active: true).leftEye == 0,
              "Out-of-range blink safely closes Angel's eyes")
    }
    let sleepy = AngelVectorMotion.facial(.tired, blink: 0, active: true)
    check(sleepy.leftEye < neutral.leftEye && sleepy.rightEye < neutral.rightEye,
          "Angel tired eyes are sleepier than her neutral eyes")
    let angry = AngelVectorMotion.facial(.angry, blink: 0, active: true)
    let sad = AngelVectorMotion.facial(.sad, blink: 0, active: true)
    check(angry.leftBrowSlope * sad.leftBrowSlope < 0 && angry.rightBrowSlope * sad.rightBrowSlope < 0,
          "Angel sad and angry inner brows move in opposite directions")
    for face in [CharacterFace.skeptical, .playful] {
        let pose = AngelVectorMotion.facial(face, blink: 0, active: true)
        check(pose.leftEye != pose.rightEye, "Angel \(face) retains asymmetric eyes")
    }

    let mouthSignatures = Set((0...8).map {
        mouthValues(AngelVectorMotion.mouth(role: $0, strength: 1, face: .neutral, active: true))
            .map { String($0) }.joined(separator: ",")
    })
    check(mouthSignatures.count == 9, "Angel has nine distinct mouth roles")
    check(AngelVectorMotion.mouth(role: 6, strength: 1, face: .neutral, active: true).aperture == 0,
          "Angel pressed lips stay geometrically closed")
    for face in faces {
        let resting = mouthValues(AngelVectorMotion.mouth(role: 0, strength: 0, face: face, active: true))
        if face != .laugh {
            for role in [-1, 9, Int.max] {
                check(mouthValues(AngelVectorMotion.mouth(role: role, strength: 1, face: face, active: true)) == resting,
                      "Unknown Angel mouth role returns her authored resting mouth")
            }
            for invalid in [Double.nan, .infinity, -.infinity, -1, 0, 0.06] {
                check(mouthValues(AngelVectorMotion.mouth(role: 8, strength: invalid, face: face, active: true)) == resting,
                      "Quiet or invalid speech level returns Angel's resting mouth")
            }
        }
        for role in 0...8 {
            let pose = AngelVectorMotion.mouth(role: role, strength: 100, face: face, active: true)
            let values = mouthValues(pose)
            check(values.allSatisfy(\.isFinite) && (0...1).contains(pose.aperture)
                  && (0...1).contains(pose.roundness) && (0.5...1.2).contains(pose.width),
                  "Angel mouth geometry stays finite and bounded")
            let still = AngelVectorMotion.mouth(role: role, strength: 1, face: face, active: false)
            check(still.aperture == 0 && still.upperTeeth == 0 && still.lowerTeeth == 0 && still.tongue == 0,
                  "Inactive Angel has no speech opening or floating teeth")
        }
    }
    let laugh = mouthValues(AngelVectorMotion.mouth(role: 0, strength: 0, face: .laugh, active: true))
    check((0...8).allSatisfy {
        mouthValues(AngelVectorMotion.mouth(role: $0, strength: 1, face: .laugh, active: true)) == laugh
    }, "Angel laugh keeps one mouth geometry across speech roles")

    let still = ornamentValues(AngelVectorOrnamentPose.still)
    for time in [Double.nan, .infinity, -.infinity, -1] {
        check(ornamentValues(AngelVectorMotion.ornaments(time: time, active: true, expression: .excited)) == still,
              "Invalid Angel ornament clock returns exact still art")
    }
    for time in [0, 0.01, 1, 30, 100000, Double.greatestFiniteMagnitude] {
        check(ornamentValues(AngelVectorMotion.ornaments(time: time, active: false, expression: .excited)) == still,
              "Inactive Angel ornaments do not move")
    }
    var ornamentBounds = true
    var quietIsSmaller = true
    for tick in 0...1000 {
        let time = Double(tick) / 12
        let pose = AngelVectorMotion.ornaments(time: time, active: true, expression: .excited)
        let quiet = AngelVectorMotion.ornaments(time: time, active: true, expression: .sad)
        ornamentBounds = ornamentBounds && ornamentValues(pose).allSatisfy(\.isFinite)
            && abs(pose.leftWingDegrees) <= 1.8 && abs(pose.rightWingDegrees) <= 1.8
            && abs(pose.haloOffsetY) <= 0.003 && abs(pose.haloDegrees) <= 0.35
            && (0.21...0.51).contains(pose.sparkle)
        quietIsSmaller = quietIsSmaller && abs(quiet.leftWingDegrees) <= abs(pose.leftWingDegrees)
            && abs(quiet.rightWingDegrees) <= abs(pose.rightWingDegrees)
    }
    check(ornamentBounds, "Angel wings, halo and slow jewel highlights stay within their reviewed motion ranges")
    check(quietIsSmaller, "Angel quieter expressions reduce wing motion")
    check(ornamentValues(AngelVectorMotion.ornaments(time: .greatestFiniteMagnitude,
          active: true, expression: .calm)).allSatisfy(\.isFinite),
          "Very large finite Angel clocks remain bounded")
}

/// Conservative control-point hulls enclose each Bezier curve. Every authored
/// point and stroke margin must survive the native group's motion extrema.
func runAngelVectorArtBoundsChecks(_ art: CharacterAngelVectorArt,
                                  _ check: (Bool, String) -> Void) {
    func rotate(_ point: [Double], around pivot: [Double], degrees: Double) -> [Double] {
        let angle = degrees * .pi / 180
        let x = point[0] - pivot[0], y = point[1] - pivot[1]
        return [pivot[0] + x * cos(angle) - y * sin(angle),
                pivot[1] + x * sin(angle) + y * cos(angle)]
    }
    var allContained = true
    for bodyAngle in [-0.4, 0, 0.4] {
        for headAngle in [-1.8, 0, 1.8] {
            for wingAngle in [-1.8, 0, 1.8] {
                for offset in [-1.5, 0, 1.5] {
                    for shape in art.shapes {
                        let margin = (shape.strokeWidth ?? 0) / 2
                        for command in shape.path {
                            for index in stride(from: 0, to: command.v.count, by: 2) {
                                var point = [command.v[index], command.v[index + 1]]
                                if shape.group == "leftWing" || shape.group == "rightWing" {
                                    point = rotate(point, around: art.pivots[shape.group]!, degrees: wingAngle)
                                } else if shape.group == "head" || shape.group == "halo" {
                                    if shape.group == "halo" {
                                        point[1] += offset > 0 ? 3.072 : -3.072
                                        point = rotate(point, around: art.pivots["halo"]!, degrees: offset > 0 ? 0.35 : -0.35)
                                    }
                                    point[1] += offset > 0 ? 2 : -2
                                    point = rotate(point, around: art.pivots["head"]!, degrees: headAngle)
                                }
                                point[1] += offset
                                point = rotate(point, around: art.pivots["body"]!, degrees: bodyAngle)
                                allContained = allContained && point.allSatisfy {
                                    $0.isFinite && (margin...art.canvas - margin).contains($0)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    check(allContained, "Angel's authored control-point hulls and strokes stay inside the canvas at motion extrema")
    let neck = art.pivots["head"]!
    let mouth = art.features.mouth
    check(abs(neck[0] - mouth.cx) < 40 && mouth.cy < neck[1],
          "Angel's mouth shares the centered head above its neck joint")
    check(art.features.eyes[0].cx < art.features.eyes[1].cx,
          "Angel's two eyes retain their authored left-to-right registration")
}
