// Adapts the system's secure in-app browser for SwiftUI photo-search sheets.

import SafariServices
import SwiftUI

/// Presents a URL inside an in-app `SFSafariViewController` so a photo search opens
/// without leaving Menuscript.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    /// Creates a Safari controller for the already-validated destination URL.
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    /// No update work is needed because the browser URL is fixed for the sheet's lifetime.
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
