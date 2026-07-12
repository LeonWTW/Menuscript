import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case zhHant = "zh-Hant"
    case english = "en"

    var id: String { rawValue }

    /// nil = 跟隨系統
    var locale: Locale? {
        self == .system ? nil : Locale(identifier: rawValue)
    }

    static func resolve(from defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: SettingsKeys.appLanguage) ?? "") ?? .system
    }
}
