import SwiftUI
import UIKit
import AVFoundation

enum StillPhotoCameraAccess: Equatable {
    case ready
    case unavailable
    case denied
    case restricted

    var errorMessage: String? {
        switch self {
        case .ready:
            return nil
        case .unavailable:
            return "This device doesn't have an available camera. Choose a photo or file instead."
        case .denied:
            return "Camera access is turned off for Kade-AI. Allow Camera in Settings, or choose a photo or file instead."
        case .restricted:
            return "Camera access is restricted on this device. Choose a photo or file instead."
        }
    }
}

/// Apple's still-camera UI includes Retake and Use Photo before returning
/// an image. The caller owns dismissal and the next step; this picker
/// only returns JPEG bytes and never uploads or sends a message.
struct StillPhotoPicker: UIViewControllerRepresentable {
    var onImage: (Data) -> Void
    var onCancel: () -> Void
    var onError: (String) -> Void

    /// Call before presenting so denial and unavailable hardware stay on
    /// the caller's screen, where its visible and VoiceOver errors live.
    @MainActor
    static func requestCameraAccess() async -> StillPhotoCameraAccess {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            return .unavailable
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .ready
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted { return .ready }
            return AVCaptureDevice.authorizationStatus(for: .video) == .restricted ? .restricted : .denied
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func makeUIViewController(context: Context) -> UIViewController {
        // Recheck at presentation: hardware or permission may have changed
        // while the parent was waiting. Never open the library as a fallback.
        let error: String?
        if !UIImagePickerController.isSourceTypeAvailable(.camera) {
            error = StillPhotoCameraAccess.unavailable.errorMessage
        } else {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                error = nil
            case .restricted:
                error = StillPhotoCameraAccess.restricted.errorMessage
            case .notDetermined:
                error = "Camera permission hasn't been requested. Close this screen and choose Take a photo again."
            case .denied:
                error = StillPhotoCameraAccess.denied.errorMessage
            @unknown default:
                error = StillPhotoCameraAccess.denied.errorMessage
            }
        }
        if let error {
            let coordinator = context.coordinator
            // Wait until the cover has appeared. Reporting from make can
            // dismiss it before presentation finishes, skipping onDismiss
            // and the parent's accessible error UI.
            return CameraErrorViewController { coordinator.fail(error) }
        }

        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        (uiViewController as? UIImagePickerController)?.delegate = nil
        coordinator.completed = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: StillPhotoPicker
        var completed = false

        init(_ parent: StillPhotoPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard !completed else { return }
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.9) else {
                fail("Couldn't prepare that photo. Try taking it again.")
                return
            }
            completed = true
            parent.onImage(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            guard !completed else { return }
            completed = true
            parent.onCancel()
        }

        func fail(_ message: String) {
            guard !completed else { return }
            completed = true
            parent.onError(message)
        }
    }
}

private final class CameraErrorViewController: UIViewController {
    private var reportError: (() -> Void)?

    init(reportError: @escaping () -> Void) {
        self.reportError = reportError
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let report = reportError
        reportError = nil
        report?()
    }
}
