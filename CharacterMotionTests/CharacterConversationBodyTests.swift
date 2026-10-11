import Foundation

func runCharacterConversationBodyChecks(_ check: (Bool, String) -> Void) {
    let identities: [(String, String, CharacterConversationBodyArtwork.Kind)] = [
        (CharacterMotion.kianaID, CharacterMotion.kianaFile, .kiana),
        (CharacterMotion.harleyID, CharacterMotion.harleyFile, .harley),
        (CharacterMotion.lillyID, CharacterMotion.lillyFile, .lilly),
        (CharacterMotion.skyleeLillyID, CharacterMotion.skyleeLillyFile, .lilly),
        (CharacterMotion.witherspoonID, CharacterMotion.witherspoonFile, .witherspoon)]
    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000000001 }
    for (id, file, kind) in identities {
        guard let artwork = CharacterConversationBodyArtwork.approved(stage: true,
            side: 208, agentID: id, avatarPath: "/images/" + file) else {
            check(false, "Conversation body must register its exact existing identity"); continue
        }
        check(artwork.kind == kind && artwork.agentID == id,
              "Conversation body preserves exact owner separately from shared drawn identity")
        check(close(artwork.stageHeight(side: 208), CharacterDellaArticulatedGeometry.stageHeight(side: 208)),
              "Conversation body and existing Della reserve identical tall stage height")
        check(CharacterConversationBodyArtwork.approved(stage: false, side: 208,
            agentID: id, avatarPath: file) == nil, "Picker portraits cannot adopt the tall body")
        for size in [Double.nan, .infinity, -1, 84, 104, 132, 159.999] {
            check(CharacterConversationBodyArtwork.approved(stage: true, side: size,
                agentID: id, avatarPath: file) == nil, "Invalid and compact stages retain the original portrait")
        }
        check(CharacterConversationBodyArtwork.approved(stage: true, side: 208,
            agentID: id, avatarPath: CharacterMotion.dellaFile) == nil,
            "A different avatar cannot borrow another character's body")
        if kind == .kiana {
            check(artwork.bodyAsset == nil && !artwork.requiredAssets.contains("CharacterKianaBustBody"),
                  "Kiana never loads or draws the rejected torso plate")
        }
        let registration = CharacterConversationBodyGeometry.registration(kind)
        let r = registration
        let still = CharacterConversationBodyGeometry.pose(artwork: artwork, active: false,
            presentation: .idle, figurePose: .still, elapsed: 0, outputLevel: 1)
        check(still.auditValues.count == 26 && Set(still.auditValues.keys) == Set(CharacterConversationBodyPose.auditKeys),
              "Body evidence uses the complete fixed joint and transform inventory")
        for activity in [CharacterActivity.idle, .listening, .thinking, .speaking] {
            for expression in CharacterExpression.allCases {
                for elapsed in [0.0, 0.45, 0.7, 1.2, 3.2, 6.7, 15, 30, 120, 1e100] {
                    for variant in 0...1 {
                        var presentation = CharacterPresentation(activity: activity, expression: expression,
                            elapsed: elapsed, outputEpisodeKey: "test-episode", outputPhase: .playing,
                            outputSpeakerID: id)
                        if activity != .speaking { presentation.outputPhase = .unspecified }
                        let performance = CharacterBodyPerformanceSample(elapsed: elapsed,
                            activityElapsed: elapsed, energy: 1, accentElapsed: elapsed,
                            accentScale: 1, gestureVariant: variant, attentionVariant: variant)
                        let figure = CharacterFigurePose(headAngle: 7, headNod: 0.018,
                            torsoAngle: 3, torsoLift: 0.008, farArmAngle: 14, nearArmAngle: 16)
                        let pose = CharacterConversationBodyGeometry.pose(artwork: artwork, active: true,
                            presentation: presentation, figurePose: figure, elapsed: elapsed,
                            outputLevel: 1, performance: performance)
                        check(pose.auditValues.values.allSatisfy(\.isFinite), "Every joint and transform remains finite")
                        for (arm, shoulder, elbow, wrist) in [
                            (pose.viewerLeft, r.leftShoulder, r.leftElbow, r.leftWrist),
                            (pose.viewerRight, r.rightShoulder, r.rightElbow, r.rightWrist)] {
                            check(arm.shoulder == shoulder && close((arm.elbow - arm.shoulder).length, (elbow - shoulder).length)
                                && close((arm.wrist - arm.elbow).length, (wrist - elbow).length),
                                "Shoulder attachment and both anatomical bone lengths survive all gestures")
                            check(abs(arm.shoulderDegrees) <= 4 && abs(arm.elbowDegrees) <= 28
                                && abs(arm.wristDegrees) <= 10 && (0...1).contains(arm.openness),
                                "Joint angles and palm openness remain within authored limits")
                            // Conservative corners enclose the entire local hand including
                            // Bezier controls, not just its wrist or a synthetic hit point.
                            for x in [-0.71, 0.71] {
                                for y in [-0.12, 1.38] {
                                    let point = arm.wrist + CharacterConversationPoint(x: x * r.handScale,
                                        y: y * r.handScale).rotated(degrees: arm.handDegrees)
                                    check(point.x > 0 && point.x < 1 && point.y > 1.02
                                        && point.y < CharacterDellaArticulatedGeometry.cropHeight
                                            / CharacterDellaArticulatedGeometry.cropWidth,
                                        "Complete articulated hands stay inside the tall stage and below the original face square")
                                }
                            }
                        }
                        check(CharacterConversationBodyGeometry.pose(artwork: artwork, active: false,
                            presentation: presentation, figurePose: figure, elapsed: elapsed,
                            outputLevel: 1, performance: performance) == still,
                            "Every motion-policy stop parks joints and all common transforms immediately")
                    }
                }
            }
        }
        var speech = CharacterPresentation(activity: .speaking, expression: .excited, elapsed: 0.7,
            outputEpisodeKey: "test-episode", outputPhase: .playing, outputSpeakerID: id)
        let hot = CharacterBodyPerformanceSample(elapsed: 0.7, energy: 1,
            accentElapsed: 0.7, accentScale: 1)
        let playing = CharacterConversationBodyGeometry.pose(artwork: artwork, active: true,
            presentation: speech, figurePose: .still, elapsed: 0.7, outputLevel: 1, performance: hot)
        check(playing != still, "A real owned speech accent produces an articulated gesture")
        for phase in [CharacterOutputPhase.queuedGap, .paused] {
            speech.outputPhase = phase
            check(CharacterConversationBodyGeometry.pose(artwork: artwork, active: true,
                presentation: speech, figurePose: .still, elapsed: 0.7, outputLevel: 0,
                performance: hot) == playing,
                "Pause and queued gap use only the supplied held/releasing gesture, independent of raw output")
            check(CharacterConversationBodyGeometry.pose(artwork: artwork, active: true,
                presentation: speech, figurePose: .still, elapsed: 0.7, outputLevel: 1) == still,
                "Without the shared held sample, pause and gap cannot initiate speech gestures")
        }
        speech.outputPhase = .stopped
        check(CharacterConversationBodyGeometry.pose(artwork: artwork, active: true,
            presentation: speech, figurePose: .still, elapsed: 0.7, outputLevel: 1,
            performance: hot) == still, "Explicit stopped output parks even with stale positive energy")
        speech.outputPhase = .playing; speech.outputSpeakerID = CharacterMotion.dellaID
        check(CharacterConversationBodyGeometry.pose(artwork: artwork, active: true,
            presentation: speech, figurePose: .still, elapsed: 0.7, outputLevel: 1,
            performance: hot) == still, "Another speaker's output cannot animate these hands")
        speech.outputSpeakerID = id
        var transition = hot
        transition.previousExpression = .warm; transition.expressionBlend = 0
        var warm = speech; warm.expression = .warm
        let warmPose = CharacterConversationBodyGeometry.pose(artwork: artwork, active: true,
            presentation: warm, figurePose: .still, elapsed: 0.7, outputLevel: 1, performance: hot)
        let transitionStart = CharacterConversationBodyGeometry.pose(artwork: artwork, active: true,
            presentation: speech, figurePose: .still, elapsed: 0.7, outputLevel: 1, performance: transition)
        check(transitionStart == warmPose, "An authored cue transition starts at the existing connected arm pose")
        transition.expressionBlend = 1
        check(CharacterConversationBodyGeometry.pose(artwork: artwork, active: true,
            presentation: speech, figurePose: .still, elapsed: 0.7, outputLevel: 1, performance: transition)
            == playing, "A completed authored cue transition reaches the next exact arm recipe")
        var quiet = hot; quiet.energy = 0
        check(CharacterConversationBodyGeometry.pose(artwork: artwork, active: true,
            presentation: speech, figurePose: .still, elapsed: 0.7, outputLevel: 1,
            performance: quiet) == still, "Zero slow energy produces no speech gesture even inside an active accent")
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            check(CharacterConversationBodyGeometry.pose(artwork: artwork, active: true,
                presentation: speech, figurePose: .still, elapsed: invalid, outputLevel: 1,
                performance: hot) == still, "Invalid body clocks fail closed to the rest pose")
        }
    }
}
