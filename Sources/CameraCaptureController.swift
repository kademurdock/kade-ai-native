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
        sampler.onEncodedFrame = { [weak self] jpeg in
            Task { @MainActor in self?.onFrame?(jpeg) }
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
        setTorch(false)
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
        setTorch(false)
    }

    func setTorch(_ on: Bool) {
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
    }
}
