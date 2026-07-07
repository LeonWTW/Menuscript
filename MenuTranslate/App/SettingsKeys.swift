import Foundation

enum SettingsKeys {
    static let targetLanguage = "settings.targetLanguage"     // String, default "繁體中文"
    static let homeCurrency = "settings.homeCurrency"         // String, default "USD"
    static let geminiModel = "settings.geminiModel"           // String, default "gemini-2.5-flash"
    static let useMockProvider = "settings.useMockProvider"   // Bool, default false
    static let appLanguage = "settings.appLanguage"           // String: "system" | "zh-Hant" | "en", default "system"
}
