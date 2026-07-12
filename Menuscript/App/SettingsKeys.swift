import Foundation

enum SettingsKeys {
    static let targetLanguage = "settings.targetLanguage"     // String, default resolved by `defaultTargetLanguage(...)` (follows app UI language)
    static let homeCurrency = "settings.homeCurrency"         // String, default "USD"
    static let geminiModel = "settings.geminiModel"           // String, default "gemini-2.5-flash"
    static let useMockProvider = "settings.useMockProvider"   // Bool, default false
    static let appLanguage = "settings.appLanguage"           // String: "system" | "zh-Hant" | "en", default "system"

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
}
