import Foundation

enum SettingsKeys {
    static let targetLanguage = "settings.targetLanguage"     // String, default resolved by `defaultTargetLanguage(...)` (follows app UI language)
    static let homeCurrency = "settings.homeCurrency"         // String, default "USD"
    static let geminiModel = "settings.geminiModel"           // String, default "gemini-2.5-flash"
    static let useMockProvider = "settings.useMockProvider"   // Bool, default false
    static let appLanguage = "settings.appLanguage"           // String: "system" | "zh-Hant" | "en", default "system"
    static let allergenPresets = "settings.allergenPresets"   // String, comma-joined Allergen slugs, default ""
    static let allergenCustom = "settings.allergenCustom"     // String, free-text custom allergens, default ""

    /// Default `targetLanguage` for a user who has never chosen one.
    /// Follows the effective app UI language instead of always defaulting to
    /// Traditional Chinese: an English UI — `appLanguage == .english`, or
    /// `.system` where the system locale itself is English — defaults to
    /// "English"; everything else defaults to "繁體中文".
    ///
    /// Only ever consulted as a fallback for an *unset* `targetLanguage`
    /// default; once the user has explicitly picked a target language, that
    /// stored value always wins and this function is never called for them.
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

    /// Reads a free-text setting, treating an empty or whitespace-only stored
    /// value the same as an unset one. `TextField`s bound directly to
    /// `@AppStorage` persist `""` when the user clears them, and plain
    /// `defaults.string(forKey:) ?? fallbackValue` never catches that since
    /// `??` only fires on `nil` — every such read site must go through here
    /// instead so a cleared field falls back like a never-set one.
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
