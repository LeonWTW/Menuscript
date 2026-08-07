// Starts Menuscript, supplies shared persistence, and applies the user's
// interface-language choice at the top of the SwiftUI view hierarchy.

import SwiftData
import SwiftUI

/// The application's single entry point and owner of app-wide dependencies.
@main
struct MenuscriptApp: App {
    @AppStorage(SettingsKeys.appLanguage) private var appLanguageRaw: String = "system"
    @State private var captureViewModel: CaptureViewModel?

    /// Builds the main window, refreshes it when the language changes, and gives
    /// every screen access to the same SwiftData menu-session store.
    var body: some Scene {
        WindowGroup {
            RootView(captureViewModel: $captureViewModel)
                .environment(\.locale, AppLanguage(rawValue: appLanguageRaw)?.locale ?? Locale.current)
                .id(appLanguageRaw)
        }
        .modelContainer(for: MenuSession.self)
    }
}
