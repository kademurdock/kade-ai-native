import SwiftUI

/// One drawn frame of a puppet. Decorative like every portrait: hidden from
/// VoiceOver and never hit-tested. The frame's size comes from its host only.
struct PuppetCanvas: View {
    let renderer: PuppetRenderer
    let channels: [Double]
    var crop: PuppetPreparedScene.Rect? = nil

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                renderer.draw(in: cg, rect: CGRect(origin: .zero, size: size), channels: channels, view: crop)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// The live motion engine behind one stage. Created per puppet and per
/// character so two faces never share a breath, and stepped only by the
/// stage's own timeline (the engine itself has no clock).
final class PuppetMotionClock {
    private var motion: PuppetMotion?
    private weak var renderer: PuppetRenderer?
    private var identity: String?
    private var expression = ""
    private var lastTime: Double?
    private var last = [Double](repeating: 0, count: PuppetChannel.count)

    func reset() {
        motion = nil
        lastTime = nil
    }

    /// The timeline is paused; the next frame starts from rest instead of
    /// catching up on the gap (update() also caps a step at 0.1 s).
    func pause() { lastTime = nil }

    func channels(renderer: PuppetRenderer, agentID: String?, time: Double,
                  input: PuppetMotion.Input, expression: String) -> [Double] {
        if motion == nil || self.renderer !== renderer || identity != agentID {
            motion = PuppetMotion(seed: PuppetMotion.hashSeed(agentID ?? "puppet"), options: renderer.prepared.motion)
            self.renderer = renderer
            identity = agentID
            self.expression = ""
            lastTime = nil
        }
        guard let motion else { return last }
        if expression != self.expression {
            motion.setExpression(expression, strength: 1, holdSeconds: PuppetMotion.holdSeconds(for: expression))
            self.expression = expression
        }
        guard time.isFinite else { return last }
        let dt = lastTime.map { time - $0 } ?? 0
        if lastTime == nil || dt > 0 {
            last = motion.update(dt: dt, input: input)
            lastTime = time
        }
        return last
    }
}

/// Oct 16 2026: a server-made vector puppet on the face stage, for any
/// character without a hand-made rig. Same gates as the painted portrait (the
/// voice-portraits setting, scene phase, on screen, Low Power, thermal, and it
/// keeps moving under VoiceOver), its own smoother clock, and Reduce Motion
/// holds a still pose that still shows the expression.
struct PuppetStageView: View {
    let renderer: PuppetRenderer
    let agentID: String?
    var playing = false
    var level: () -> Double = { 0 }
    var listening = false
    var presentation: () -> CharacterPresentation = { .idle }
    /// The host's own gates: visible, on screen, not paused locally, and a
    /// stage or a voice. System motion policy is read here.
    var hostActive = true

    @Environment(\.scenePhase) private var scenePhase
    @KadeMotionPolicy(permitsVoiceOver: true) private var motionAllowed: Bool
    @State private var clock = PuppetMotionClock()

    var body: some View {
        let running = hostActive && motionAllowed && scenePhase == .active
        let budget = PuppetFrameBudget(active: running,
            activity: PuppetFrameBudget.activity(presentation(), playing: playing), thermal: $motionAllowed)
        TimelineView(.animation(minimumInterval: budget.minimumInterval, paused: budget.paused)) { timeline in
            PuppetCanvas(renderer: renderer,
                channels: channels(time: timeline.date.timeIntervalSinceReferenceDate, running: running))
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .onDisappear { clock.reset() }
    }

    private func channels(time: Double, running: Bool) -> [Double] {
        let offered = presentation()
        let ownsOutput = offered.outputPhase == .unspecified || offered.outputPhase == .stopped
            || offered.outputSpeakerID == agentID
        let performance = ownsOutput ? offered : .idle
        let expression = PuppetMotion.expressionName(for: performance)
        guard running else {
            clock.pause()
            return PuppetMotion.stillChannels(expression: expression, options: renderer.prepared.motion)
        }
        let speaking = performance.activity == .speaking && performance.outputPhase != .queuedGap
            && performance.outputPhase != .paused && performance.outputPhase != .stopped
        let input = PuppetMotion.Input(speaking: speaking,
            level: speaking ? PuppetMotion.voiceLevel(level()) : 0,
            listening: !speaking && (listening || performance.activity == .listening),
            reduceMotion: false)
        return clock.channels(renderer: renderer, agentID: agentID, time: time, input: input, expression: expression)
    }
}
