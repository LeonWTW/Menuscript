import Foundation
import Testing
@testable import MenuTranslate

/// Covers `SettingsKeys.defaultTargetLanguage`: the fallback used only when
/// the user has never explicitly chosen a target language. Every case here
/// passes `appLanguage`/`systemLocale` explicitly so the result never
/// depends on the host machine's actual locale.
@Suite("SettingsKeys.defaultTargetLanguage")
struct SettingsKeysDefaultTargetLanguageTests {
    @Test("Explicit English app language defaults to English, regardless of system locale")
    func explicitEnglishDefaultsToEnglish() {
        #expect(SettingsKeys.defaultTargetLanguage(appLanguage: .english, systemLocale: Locale(identifier: "zh-Hant")) == "English")
        #expect(SettingsKeys.defaultTargetLanguage(appLanguage: .english, systemLocale: Locale(identifier: "ja_JP")) == "English")
    }

    @Test("Explicit zh-Hant app language defaults to 繁體中文, regardless of system locale")
    func explicitZhHantDefaultsToZhHant() {
        #expect(SettingsKeys.defaultTargetLanguage(appLanguage: .zhHant, systemLocale: Locale(identifier: "en_US")) == "繁體中文")
        #expect(SettingsKeys.defaultTargetLanguage(appLanguage: .zhHant, systemLocale: Locale(identifier: "ja_JP")) == "繁體中文")
    }

    @Test("System app language follows an English system locale")
    func systemAppLanguageWithEnglishSystemLocaleDefaultsToEnglish() {
        #expect(SettingsKeys.defaultTargetLanguage(appLanguage: .system, systemLocale: Locale(identifier: "en")) == "English")
        #expect(SettingsKeys.defaultTargetLanguage(appLanguage: .system, systemLocale: Locale(identifier: "en_US")) == "English")
        #expect(SettingsKeys.defaultTargetLanguage(appLanguage: .system, systemLocale: Locale(identifier: "en_GB")) == "English")
    }

    @Test("System app language falls back to 繁體中文 for a non-English system locale", arguments: [
        "zh-Hant", "zh_TW", "ja_JP", "fr_FR", "ko_KR",
    ])
    func systemAppLanguageWithNonEnglishSystemLocaleDefaultsToZhHant(identifier: String) {
        #expect(SettingsKeys.defaultTargetLanguage(appLanguage: .system, systemLocale: Locale(identifier: identifier)) == "繁體中文")
    }
}
