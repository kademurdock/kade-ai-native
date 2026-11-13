import AVFoundation
import UIKit

/// Camera capture for the Spotter/Live video layer -- the native
/// equivalent of `ConversationMode.tsx`'s `startCamera()` (canvas snapshot
/// loop) and `video-live.js`'s `forwardFrame`. Sends a JPEG frame roughly
/// every 2 seconds (matching the web client's own `setInterval(..., 2000)`
/// cadence exactly) via `onFrame`, which `CallView` wires to
/// `StreamingCallService.sendFrame(jpegData:)`. One capture loop serves
/// BOTH the plain video-sight (snapshot description) lane and the Spotter/
/// Live lane -- same as the web client, the SERVER decides which one a
/// frame is used for based on whether live mode is currently on
/// (`session.liveOn` in `voice-stream.js`), so this controller doesn't need
/// to know or care which mode is active.
@MainActor
final class CameraCaptureController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var torchAvailable = false
    @Published private(set) var torchOn = false
    @Published var permissionDenied = false

    /// Session 15 -- auto-flash in the dark, matching the web client's own
    /// brightness probe. The reason this matters more here than it looks:
    /// a sighted person points a camera at something dark, sees a black
    /// preview, and reaches for the torch. Someone using a Spotter has no
    /// black preview to see -- the only symptom of a dark room is a
    /// companion who keeps saying she can't make anything out, which is
    /// indistinguishable from the feature being broken. So the app has to
    /// notice instead.
    ///
    /// `true` once the caller has touched the torch button herself, after
    /// which the automatic behaviour stops entirely for the rest of the
    /// session. A control that keeps overriding a deliberate choice is
    /// worse than no automation at all.
    private var torchManuallySet = false

    /// Exposed so `CallView` can wrap it in a `UIViewRepresentable` preview
    /// layer -- this app has no prior camera UI to follow a precedent from,
    /// so this is a fresh, deliberately minimal surface.
    let session = AVCaptureSession()

    /// Aug 4 2026: flips the frame cadence between Spotter/Live speed and
    /// the plain lane's web-parity pace -- see FrameSampler.liveMode.
    func setLiveCadence(_ live: Bool) {
        sampler.liveMode = live
    }

    /// Called with an already-JPEG-encoded frame, off the main actor's
    /// critical path (only the call itself is hopped to MainActor -- see
    /// `FrameSampler` below for why).
    /// Returns whether the frame really went out (DESC-3's in-flight gate can
    /// drop it); a dropped frame is not remembered by the still check.
    var onFrame: ((Data) -> Bool)?
    /// DESC-1 (Nov 12 2026 audit): CallView sets this to "is the call's
    /// voice coming out right now". The auto-flash notice waits for a gap
    /// instead of talking over the Spotter (two voices at once). Unset, the
    /// notice is spoken at once, as before.
    var voiceIsAudible: (() -> Bool)?
    private var torchNoticeTask: Task<Void, Never>?
    /// DESC-4 (Nov 12 2026 audit): called with true when iOS takes the
    /// camera away (the phone locked, the app left the screen, another app
    /// took the camera) and false when it gives it back. `CallView` wires it
    /// to `StreamingCallService.sendCameraState(on:)` so the Spotter can say
    /// it lost the picture instead of describing the last one as now.
    var onPaused: ((Bool) -> Void)?
    private var interruptionWatches: [NSObjectProtocol] = []

    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.kademurdock.kadeai.camera")
    private let sampler = FrameSampler()
    private var currentDevice: AVCaptureDevice?
    private var currentPosition: AVCaptureDevice.Position = .front
    /// Oct 20 2026 (Kade: Spotters "having a lot of problems telling left and
    /// right"): frames used to be locked to portrait, so a phone held upside
    /// down -- easy when you can't see the screen -- sent an upside-down
    /// picture, which swaps left and right in every answer, and a sideways
    /// phone turned left/right into up/down. The rotation coordinator reads
    /// the phone's real position from its motion sensors (orientation lock
    /// or not) and gives the angle that keeps the horizon level; each frame
    /// is captured at that angle, so the Spotter always sees the room upright.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    init() {
        // ROOT-CAUSE FIX (session 21, Kade: Spotter calls "can still hear me
        // but I can't hear them," volume swinging with the last call's
        // setting). An AVCaptureSession defaults
        // `automaticallyConfiguresApplicationAudioSession = true`, so the
        // instant the camera starts for Spotter it RECONFIGURES the shared
        // AVAudioSession -- tearing down the `.playAndRecord`/`.voiceChat` +
        // forced-speaker + Voice-Processing graph `StreamingCallService`
        // carefully stood up, which drops the agent's OUTPUT (and lands the
        // route in a different, persisted call-volume domain) while the mic
        // INPUT survives. That is exactly "she hears me, I don't hear her,"
        // and it only happens on Spotter because Spotter is the only thing
        // that starts the camera. We own the audio session entirely, so tell
        // capture to keep its hands off it.
        session.automaticallyConfiguresApplicationAudioSession = false
        let center = NotificationCenter.default
        interruptionWatches = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onPaused?(true) }
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onPaused?(false) }
            },
        ]
        let sampler = self.sampler
        let queue = self.queue
        sampler.onEncodedFrame = { [weak self] jpeg, seq in
            Task { @MainActor in
                guard let self, let onFrame = self.onFrame else { return }
                // DESC-3 + DESC-11: the call dropped it (a frame still in
                // flight, or the hold-off). Forget it on the capture queue,
                // so the next frame is compared with what was really sent.
                if !onFrame(jpeg) {
                    queue.async { sampler.frameWasDropped(seq: seq) }
                }
            }
        }
        sampler.onBrightness = { [weak self] level in
            Task { @MainActor in self?.considerAutoTorch(brightness: level) }
        }
    }

    deinit { for watch in interruptionWatches { NotificationCenter.default.removeObserver(watch) } }

    /// Called once per sampled frame with that frame's mean luminance
    /// (0 = black, 1 = white). Two separate thresholds on purpose: turning
    /// the torch ON at 0.10 and only back OFF above 0.22 means a scene
    /// hovering right at the line can't strobe the light on and off every
    /// two seconds, which would be both useless and alarming. Only ever
    /// acts while a camera lane is genuinely running, and never after the
    /// caller has worked the torch button herself.
    private func considerAutoTorch(brightness: Double) {
        guard isRunning, torchAvailable, !torchManuallySet else { return }
        // The front camera has no torch on any iPhone; `torchAvailable` is
        // already false there, but this makes the intent explicit for
        // anyone reading later.
        guard currentPosition == .back else { return }
        if !torchOn, brightness < 0.10 {
            applyTorch(true)
            announceAutoTorch()
        } else if torchOn, brightness > 0.22 {
            torchNoticeTask?.cancel()
            torchNoticeTask = nil
            applyTorch(false)
        }
    }

    /// DESC-1: says "It's dark. Flashlight on." in the first gap in the
    /// call's voice (checked every quarter second, for at most 20 s).
    /// Dropped if the light went back off, the camera stopped, or no gap
    /// came: by then the Spotter has seen the light itself.
    private func announceAutoTorch() {
        torchNoticeTask?.cancel()
        torchNoticeTask = Task { [weak self] in
            for _ in 0..<80 {
                guard let self, !Task.isCancelled else { return }
                if !(self.voiceIsAudible?() ?? false) { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard let self, !Task.isCancelled, self.isRunning, self.torchOn,
                  !(self.voiceIsAudible?() ?? false) else { return }
            UIAccessibility.post(notification: .announcement, argument: "It's dark. Flashlight on.")
        }
    }

    /// Nov 13 2026 (sweep): true from `begin` until `stop`. A start runs on
    /// its own Task and, the first time, waits on the permission question; if
    /// the call ended or the Spotter handed back meanwhile, that late start
    /// used to turn the camera on and keep the screen awake with nobody left
    /// to undo it.
    private var wanted = false

    /// The camera is wanted from now. Says so at once (so a `stop()` that
    /// follows wins), then starts.
    func begin(facing: AVCaptureDevice.Position = .front) {
        wanted = true
        Task { await start(facing: facing) }
    }

    private func start(facing: AVCaptureDevice.Position) async {
        guard wanted else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart(facing: facing)
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                // Stopped while the question was up: leave the camera off.
                if wanted { configureAndStart(facing: facing) }
            } else {
                permissionDenied = true
            }
        case .denied, .restricted:
            permissionDenied = true
        @unknown default:
            permissionDenied = true
        }
    }

    /// Swap between front/back camera mid-call (mirrors the web client's
    /// `facing` param -- "standard" mode defaults front/selfie, "hq"
    /// defaults back/environment, and either can be flipped by hand).
    func switchCamera() {
        let next: AVCaptureDevice.Position = currentPosition == .front ? .back : .front
        configureAndStart(facing: next)
    }

    private func configureAndStart(facing: AVCaptureDevice.Position) {
        session.beginConfiguration()
        session.sessionPreset = .high
        for input in session.inputs { session.removeInput(input) }
        for out in session.outputs { session.removeOutput(out) }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: facing),
              let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            return
        }
        currentDevice = device
        currentPosition = facing
        if session.canAddInput(input) { session.addInput(input) }
        output.setSampleBufferDelegate(sampler, queue: queue)
        output.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(output) { session.addOutput(output) }
        // Frames follow the phone's real position (see rotationCoordinator):
        // upright whether it is held upright, upside down or sideways. Starts
        // at portrait (90) until the coordinator reports.
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        if let connection = output.connection(with: .video) {
            applyRotation(coordinator.videoRotationAngleForHorizonLevelCapture, to: connection)
            connection.isVideoMirrored = (facing == .front)
        }
        session.commitConfiguration()
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] coord, _ in
            let angle = coord.videoRotationAngleForHorizonLevelCapture
            let which = ObjectIdentifier(coord)
            Task { @MainActor in
                guard let self, let current = self.rotationCoordinator, ObjectIdentifier(current) == which,
                      let connection = self.output.connection(with: .video) else { return }
                self.applyRotation(angle, to: connection)
            }
        }
        torchAvailable = device.hasTorch
        torchManuallySet = false
        applyTorch(false)
        // DESC-4 (Nov 12 2026 audit, her choice: keep the screen awake for
        // the whole camera call): once it auto-locks, iOS stops the camera
        // while the call (background audio) carries on, and the Spotter
        // would describe its last picture as now. Set only here, after the
        // device guard, so a failed start never leaves the screen stuck on;
        // `stop()` hands the idle timer back.
        UIApplication.shared.isIdleTimerDisabled = true
        let s = session
        queue.async { [weak self] in
            s.startRunning()
            Task { @MainActor in self?.isRunning = true }
        }
    }

    private func applyRotation(_ angle: CGFloat, to connection: AVCaptureConnection) {
        let target = connection.isVideoRotationAngleSupported(angle) ? angle : 90
        guard connection.isVideoRotationAngleSupported(target), connection.videoRotationAngle != target else { return }
        connection.videoRotationAngle = target
    }

    func stop() {
        wanted = false
        rotationObservation = nil
        rotationCoordinator = nil
        torchNoticeTask?.cancel()
        torchNoticeTask = nil
        UIApplication.shared.isIdleTimerDisabled = false   // DESC-4
        let s = session
        queue.async { s.stopRunning() }
        isRunning = false
        torchManuallySet = false
        applyTorch(false)
    }

    /// The caller tapped the torch button. Turns the automatic behaviour
    /// off for the rest of this camera session -- see `torchManuallySet`.
    func setTorch(_ on: Bool) {
        torchManuallySet = true
        applyTorch(on)
    }

    private func applyTorch(_ on: Bool) {
        guard let device = currentDevice, device.hasTorch, device.isTorchModeSupported(on ? .on : .off) else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            torchOn = on
        } catch {
            // Torch is a nice-to-have (auto-flash-in-the-dark accessibility
            // touch) -- never worth surfacing an error for.
        }
    }
}

/// Deliberately NOT @MainActor: `AVCaptureVideoDataOutput` invokes this
/// delegate synchronously on the plain background `DispatchQueue` given to
/// `setSampleBufferDelegate`, always serially (one frame at a time, never
/// concurrently with itself) -- so the plain, non-actor-isolated stored
/// `lastSentAt`, `lastCheckedAt`, `lastThumb` and `wasLive` are safe here
/// without extra locking. Keeping the throttle
/// check AND the (comparatively expensive) JPEG encode entirely off the
/// main actor, and only crossing over with the final small `Data`, mirrors
/// the same isolation-boundary fix applied to the mic tap in
/// `StreamingCallService.pcm16Data` -- see that file's comment for the full
/// reasoning.
private final class FrameSampler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// The JPEG and its send number (see `frameWasDropped(seq:)`).
    var onEncodedFrame: ((Data, Int) -> Void)?
    /// Goes up every time a frame is handed on as sent; only touched on the
    /// capture queue.
    private var sentSeq = 0

    /// Called on the capture queue when the call's gate dropped frame `seq`.
    /// If no newer frame has been handed on since, the still check forgets
    /// it: the next checked frame is sent rather than compared with a
    /// picture the Spotter never received.
    func frameWasDropped(seq: Int) {
        guard seq == sentSeq else { return }
        lastThumb = []
        lastSentAt = .distantPast
    }
    /// Mean luminance of the frame that was just checked, 0...1. Reported
    /// on the same cadence as the frame checks (sent or skipped as still)
    /// rather than per raw camera frame: this is a "is the room dark"
    /// question, not a
    /// light meter, and running a reduction filter 30 times a second to
    /// answer it would burn battery on a call that is already expensive.
    var onBrightness: ((Double) -> Void)?
    private var lastSentAt: Date = .distantPast
    /// DESC-11 (Nov 12 2026 audit, her choice: skip same pictures): the
    /// cadence clock. `lastSentAt` is now the key-frame clock only.
    private var lastCheckedAt: Date = .distantPast
    /// The last frame SENT while live, as a 16x12 grey thumbnail. While live,
    /// a frame that barely differs from it is skipped unless 3 s have
    /// passed: Gemini Live keeps every frame in its context and bills the
    /// whole context each turn, so a still scene no longer pays for the same
    /// picture. Emptied whenever live turns on or off, so a new Spotter
    /// always gets a picture straight away. Only touched on the capture
    /// queue, like `lastSentAt`.
    private var lastThumb: [UInt8] = []
    private var wasLive = false
    private let stillKeyframe: TimeInterval = 3
    /// Mean absolute grey difference (0...255) under which the whole picture counts as unchanged.
    private let stillDifference = 6
    /// ...and no single cell may differ by this much: a finger on the page or a dropped pill
    /// changes a few cells a lot and the mean hardly at all.
    private let stillCellDifference = 32
    /// Kill switch, read once per call, no build needed on a test device:
    /// UserDefaults `kade.spotter.skipStillFrames` = false sends every frame.
    private let skipStillFrames = UserDefaults.standard.object(forKey: "kade.spotter.skipStillFrames") as? Bool ?? true
    /// Aug 4 2026 (her go: "fix frames"): while Spotter/Live is actually ON,
    /// frames flow at ~1.4 per second instead of one every two -- follow-the-
    /// action help (reading mail page by page, tracking a dropped thing)
    /// stops missing the moment between frames. The plain video-sight lane
    /// keeps the original 2s web-parity cadence. Cost truth: the Live lane
    /// bills per MINUTE, not per frame, so this buys quality, not a bill --
    /// bandwidth lands around ~100KB/s at 768px/0.65 JPEG. A Bool flag
    /// rather than a settable Double: written on the main actor, read on
    /// the capture queue, and a torn Bool is impossible.
    var liveMode = false
    private var minInterval: TimeInterval { liveMode ? 0.7 : 2.0 } // 2.0 matches ConversationMode.tsx's setInterval(...,2000)
    private let targetWidth: CGFloat = 768 // matches the web client's canvas width
    private let ciContext = CIContext()

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastCheckedAt) >= minInterval else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard ciImage.extent.width > 0 else { return }
        lastCheckedAt = now
        let live = liveMode
        if live != wasLive {
            // Live just turned on or off: whoever listens next has not seen this picture.
            wasLive = live
            lastThumb = []
        }
        // Brightness on every checked frame, sent or skipped, so the automatic flashlight
        // reacts as fast in a still room as it did before still frames were skipped.
        if let brightness = meanLuminance(of: ciImage) {
            onBrightness?(brightness)
        }
        var thumb: [UInt8] = []
        if live, skipStillFrames, let made = thumbnail(ciImage) {
            thumb = made
            if now.timeIntervalSince(lastSentAt) < stillKeyframe, isStill(made, comparedWith: lastThumb) {
                return
            }
        }
        let scale = targetWidth / ciImage.extent.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return }
        // Aug 9 2026 (her ask: best quality on the live lane): Spotter/Live
        // frames encode at 0.78 — noticeably cleaner text and edges for the
        // small-print reads Spotters do, ~40% more bytes ONLY while live is
        // on. The plain snapshot lane keeps 0.65 (web parity, cheap).
        guard let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: live ? 0.78 : 0.65) else { return }
        lastSentAt = now
        lastThumb = thumb // empty in the plain lane or when the thumbnail failed: the next live frame is sent
        sentSeq &+= 1
        onEncodedFrame?(jpeg, sentSeq)
    }

    /// DESC-11: a 16x12 grey thumbnail of the frame, for the still check.
    private func thumbnail(_ image: CIImage) -> [UInt8]? {
        let width = 16, height = 12
        guard image.extent.width > 0, image.extent.height > 0,
              let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        let scale = CGFloat(height) / image.extent.height
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue((CGFloat(width) / image.extent.width) / scale, forKey: kCIInputAspectRatioKey)
        guard let small = filter.outputImage else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        ciContext.render(
            small,
            toBitmap: &rgba,
            rowBytes: width * 4,
            bounds: CGRect(
                x: small.extent.origin.x, y: small.extent.origin.y,
                width: CGFloat(width), height: CGFloat(height)
            ),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        // Rec. 601 luma per cell, written out step by step: the one-line
        // map was too much for the type checker.
        var grey = [UInt8](repeating: 0, count: width * height)
        for cell in 0..<(width * height) {
            let p = cell * 4
            let red: Int = 299 * Int(rgba[p])
            let green: Int = 587 * Int(rgba[p + 1])
            let blue: Int = 114 * Int(rgba[p + 2])
            grey[cell] = UInt8((red + green + blue) / 1000)
        }
        return grey
    }

    /// DESC-11: still when the mean grey difference is under 6 AND no single
    /// cell differs by 32 or more (a finger on one line still counts as a change).
    private func isStill(_ thumb: [UInt8], comparedWith sent: [UInt8]) -> Bool {
        guard !sent.isEmpty, thumb.count == sent.count else { return false }
        var total = 0
        var worst = 0
        for index in 0..<thumb.count {
            let difference = abs(Int(thumb[index]) - Int(sent[index]))
            total += difference
            if difference > worst { worst = difference }
        }
        return total < stillDifference * thumb.count && worst < stillCellDifference
    }

    /// Mean luminance via `CIAreaAverage`, which reduces the whole image to
    /// a single pixel on the GPU -- far cheaper than walking the buffer in
    /// Swift, and the standard way to do this. Returns nil rather than a
    /// guessed value if anything about the reduction fails, so a failure
    /// reads as "no opinion" and never as "it's pitch dark, flash on."
    private func meanLuminance(of image: CIImage) -> Double? {
        let extent = CIVector(
            x: image.extent.origin.x, y: image.extent.origin.y,
            z: image.extent.size.width, w: image.extent.size.height
        )
        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: image, kCIInputExtentKey: extent]
        ), let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        // Rec. 601 luma -- the same weighting the web client's canvas probe
        // uses, so "dark" means the same thing on both platforms.
        let r = Double(pixel[0]) / 255.0
        let g = Double(pixel[1]) / 255.0
        let b = Double(pixel[2]) / 255.0
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}
