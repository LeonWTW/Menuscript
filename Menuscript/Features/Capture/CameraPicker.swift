// Adapts UIKit's camera controller and delegate callbacks into simple SwiftUI
// closures, keeping UIKit-specific behavior at one boundary.

import SwiftUI
import UIKit

/// Wraps `UIImagePickerController` configured for live camera capture so
/// `CaptureView` can present it as a full-screen cover.
struct CameraPicker: UIViewControllerRepresentable {
    var onImagePicked: (UIImage) -> Void
    var onCancel: () -> Void = {}

    /// Creates and configures the UIKit camera controller, delegating callbacks
    /// to the coordinator because SwiftUI views cannot be UIKit delegates.
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    /// No update is required because all picker configuration is fixed at creation.
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    /// Creates the delegate object that translates UIKit events into closures.
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// Receives UIKit picker events and forwards only app-ready images or cancel.
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        /// Retains the lightweight parent value so delegate events can call its closures.
        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        /// Dismisses the camera and forwards a size-limited original image;
        /// missing image data is treated as cancellation rather than success.
        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            picker.dismiss(animated: true)
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(ImagePrep.resized(image, maxLongEdge: ImagePrep.captureMaxPixelSize))
            } else {
                parent.onCancel()
            }
        }

        /// Dismisses the UIKit controller and informs SwiftUI of cancellation.
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            parent.onCancel()
        }
    }
}
