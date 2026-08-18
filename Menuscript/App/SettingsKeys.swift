// Centralizes the keys and fallback rules used for small user preferences so
// every screen reads and writes the same values consistently.

import Foundation

/// Names persisted settings and provides shared rules for resolving their defaults.
enum SettingsKeys {
    static let targetLanguage = "settings.targetLanguage"     // String, default resolved by `defaultTargetLanguage(...)` (follows app UI language)
    static let homeCurrency = "settings.homeCurrency"         // String, default "USD"
    static let geminiModel = "settings.geminiModel"           // String, default "gemini-2.5-flash"
    static let useMockProvider = "settings.useMockProvider"   // Bool, default false
    static let appLanguage = "settings.appLanguage"           // String: "system" | "zh-Hant" | "en", default "system"
    static let allergenPresets = "settings.allergenPresets"   // String, comma-joined Allergen slugs, default ""
    static let allergenCustom = "settings.allergenCustom"     // String, free-text custom allergens, default ""
    static let photoRetention = "settings.photoRetention"     // String: "30d" | "90d" | "forever", default "30d", resolved by PhotoRetentionPolicy.resolve(from:)

    /// Provides the initial translation language only when the user has not saved
    /// a choice. An English app (or English device in system mode) starts with
    /// English; every other case starts with Traditional Chinese.
    static func defaultTargetLanguage(
        appLanguage: AppLanguage = AppLanguage.resolve(),
        systemLocale: Locale = .current
    ) -> String {
        let isEnglish: Bool
        switch appLanguage {
        case .english:
            isEnglish = true
        case .zhHant:
            isEnglish = false
        case .system:
            isEnglish = systemLocale.language.languageCode?.identifier == "en"
        }
        return isEnglish ? "English" : "繁體中文"
    }

    /// Returns trimmed saved text, or the fallback when it is missing or blank.
    /// This makes a cleared setting behave like one that was never set.
    static func nonEmptyString(
        _ key: String,
        from defaults: UserDefaults = .standard,
        default fallbackValue: String
    ) -> String {
        guard let stored = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stored.isEmpty else {
            return fallbackValue
        }
        return stored
    }
}
