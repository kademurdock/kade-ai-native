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

    /// Called with an already-JPEG-encoded frame, off the main actor's
    /// critical path (only the call itself is hopped to MainActor -- see
    /// `FrameSampler` below for why).
    var onFrame: ((Data) -> Void)?

    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.kademurdock.kadeai.camera")
    private let sampler = FrameSampler()
    private var currentDevice: AVCaptureDevice?
    private var currentPosition: AVCaptureDevice.Position = .front

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
        sampler.onEncodedFrame = { [weak self] jpeg in
            Task { @MainActor in self?.onFrame?(jpeg) }
        }
        sampler.onBrightness = { [weak self] level in
            Task { @MainActor in self?.considerAutoTorch(brightness: level) }
        }
    }

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
            UIAccessibility.post(
                notification: .announcement,
                argument: "It's dark. Flashlight on."
            )
        } else if torchOn, brightness > 0.22 {
            applyTorch(false)
        }
    }

    func start(facing: AVCaptureDevice.Position = .front) async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart(facing: facing)
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                configureAndStart(facing: facing)
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
        // Video orientation matters for a portrait-held phone; without this
        // frames sent to the agent would be sideways relative to what the
        // camera preview shows on screen.
        if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
            connection.isVideoMirrored = (facing == .front)
        }
        session.commitConfiguration()
        torchAvailable = device.hasTorch
        torchManuallySet = false
        applyTorch(false)
        let s = session
        queue.async { [weak self] in
            s.startRunning()
            Task { @MainActor in self?.isRunning = true }
        }
    }

    func stop() {
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
/// concurrently with itself) -- so a plain, non-actor-isolated stored
/// `lastSentAt` is safe here without extra locking. Keeping the throttle
/// check AND the (comparatively expensive) JPEG encode entirely off the
/// main actor, and only crossing over with the final small `Data`, mirrors
/// the same isolation-boundary fix applied to the mic tap in
/// `StreamingCallService.pcm16Data` -- see that file's comment for the full
/// reasoning.
private final class FrameSampler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onEncodedFrame: ((Data) -> Void)?
    /// Mean luminance of the frame that was just encoded, 0...1. Reported
    /// on the SAME 2-second cadence as the frames themselves rather than
    /// per raw camera frame: this is a "is the room dark" question, not a
    /// light meter, and running a reduction filter 30 times a second to
    /// answer it would burn battery on a call that is already expensive.
    var onBrightness: ((Double) -> Void)?
    private var lastSentAt: Date = .distantPast
    private let minInterval: TimeInterval = 2.0 // matches ConversationMode.tsx's setInterval(...,2000)
    private let targetWidth: CGFloat = 768 // matches the web client's canvas width
    private let ciContext = CIContext()

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastSentAt) >= minInterval else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard ciImage.extent.width > 0 else { return }
        let scale = targetWidth / ciImage.extent.width
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return }
        guard let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.65) else { return }
        lastSentAt = now
        onEncodedFrame?(jpeg)
        if let brightness = meanLuminance(of: ciImage) {
            onBrightness?(brightness)
        }
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
