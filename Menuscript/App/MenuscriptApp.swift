import SwiftData
import SwiftUI

@main
struct MenuscriptApp: App {
    @AppStorage(SettingsKeys.appLanguage) private var appLanguageRaw: String = "system"
    @State private var captureViewModel: CaptureViewModel?

    var body: some Scene {
        WindowGroup {
            RootView(captureViewModel: $captureViewModel)
                .environment(\.locale, AppLanguage(rawValue: appLanguageRaw)?.locale ?? Locale.current)
                .id(appLanguageRaw)
        }
        .modelContainer(for: MenuSession.self)
    }
}
