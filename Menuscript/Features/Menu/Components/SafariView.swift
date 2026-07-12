import SafariServices
import SwiftUI

/// Presents a URL inside an in-app `SFSafariViewController` so a photo search opens
/// without leaving Menuscript.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
