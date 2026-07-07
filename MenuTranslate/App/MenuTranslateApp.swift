import SwiftData
import SwiftUI

@main
struct MenuTranslateApp: App {
    @AppStorage(SettingsKeys.appLanguage) private var appLanguageRaw: String = "system"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.locale, AppLanguage(rawValue: appLanguageRaw)?.locale ?? Locale.current)
                .id(appLanguageRaw)
        }
        .modelContainer(for: MenuSession.self)
    }
}
