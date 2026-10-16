import MetalKit
import SwiftUI

/// Oct 16 2026: a living painting's head, drawn by the GPU over whatever body
/// the portrait already composes. Decorative like every portrait: hidden from
/// VoiceOver and never hit-tested; the character is described in words
/// elsewhere. Its frame is the head's 414-pixel panel frame (side x side).
struct LivingPaintingCanvas: UIViewRepresentable {
    let resources: LivingPaintingResources
    let state: LivingPaintingState

    func makeCoordinator() -> LivingPaintingDrawer { LivingPaintingDrawer(resources: resources) }

    /// Draws again whenever it is laid out, so the first frame appears as
    /// soon as the view has a size.
    final class Surface: MTKView {
        override func layoutSubviews() {
            super.layoutSubviews()
            setNeedsDisplay()
        }
    }

    func makeUIView(context: Context) -> MTKView {
        let view = Surface(frame: .zero, device: resources.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isOpaque = false
        view.layer.isOpaque = false
        view.backgroundColor = .clear
        view.framebufferOnly = true
        // Drawn only when SwiftUI hands over a new frame: the portrait's own
        // budgeted clock (Low Power, thermal, Reduce Motion) stays in charge.
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.delegate = context.coordinator
        context.coordinator.state = state
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.state = state
        view.setNeedsDisplay()
    }
}

/// Loads a character's living-painting resources off the main thread and
/// draws them; until they are ready (or if this phone cannot), `fallback`
/// (the sliced portrait) stays on screen.
struct LivingPaintingHead<Fallback: View>: View {
    let rigName: String
    /// Which head cut the matte copies ("bust", "conversationLilly"); one
    /// set of pictures is loaded per rig and cut.
    var cutKey = "bust"
    /// The head cut in panel pixels, asked for once, at the first load.
    var outline: () -> CGPath? = { nil }
    /// The painted panel's square inside this view (the sliced head's frame).
    var placement: CGRect? = nil
    let state: LivingPaintingState
    @ViewBuilder var fallback: () -> Fallback
    @State private var resources: LivingPaintingResources?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let resources {
                if let placement {
                    LivingPaintingCanvas(resources: resources, state: state)
                        .frame(width: placement.width, height: placement.height)
                        .offset(x: placement.minX, y: placement.minY)
                } else {
                    LivingPaintingCanvas(resources: resources, state: state)
                }
            } else {
                fallback()
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .task(id: rigName + "|" + cutKey) {
            let name = rigName, key = cutKey
            let cut = LivingPaintingResources.isLoaded(rigName: name, cutKey: key) ? nil : outline()
            resources = await Task.detached(priority: .userInitiated) {
                try? LivingPaintingResources.shared(rigName: name, cutKey: key, outline: cut)
            }.value
        }
    }
}

/// Which painted characters have a living-painting rig in this build: the
/// whole painted main cast (Oct 16 2026, Kade: "Kiana, Harley, Della and
/// Lilly, all the main agents"), plus Mrs. Witherspoon. Skylee's Lilly
/// wears Lilly's paintings. Angel is drawn by code and has no rig.
enum LivingPaintingCast {
    private static var bundled: [String: Bool] = [:]

    static func rigName(agentID: String?) -> String? {
        guard let rig = CharacterMotion.rigID(agentID) else { return nil }
        let name: String
        switch rig {
        case CharacterMotion.dellaID: name = "LivingPaintingDella"
        case CharacterMotion.kianaID: name = "LivingPaintingKiana"
        case CharacterMotion.harleyID: name = "LivingPaintingHarley"
        case CharacterMotion.lillyID: name = "LivingPaintingLilly"
        case CharacterMotion.witherspoonID: name = "LivingPaintingWitherspoon"
        default: return nil
        }
        return available(name) ? name : nil
    }

    static func available(_ name: String) -> Bool {
        if let known = bundled[name] { return known }
        let found = Bundle.main.url(forResource: name, withExtension: "json") != nil
        bundled[name] = found
        return found
    }
}

/// The living painting's own motion: PuppetMotion with a painted face, so the
/// painted panels carry each expression while the engine supplies breathing,
/// glances, blinks, the speaking mouth and the head's turns.
final class LivingPaintingClock {
    private var motion: PuppetMotion?
    private var identity: String?
    private var expression = ""
    private var lastTime: Double?
    private var last = [Double](repeating: 0, count: PuppetChannel.count)

    static let options: PuppetMotion.Options = {
        var options = PuppetMotion.Options()
        options.energy = "steady"
        options.expressiveness = 0.7
        options.baseSmile = 0
        options.artFace = true
        return options
    }()

    func reset() {
        motion = nil
        lastTime = nil
    }

    func pause() { lastTime = nil }

    func channels(identity current: String, time: Double, input: PuppetMotion.Input, expression: String) -> [Double] {
        if motion == nil || identity != current {
            motion = PuppetMotion(seed: PuppetMotion.hashSeed(current), options: Self.options)
            identity = current
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
