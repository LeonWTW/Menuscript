// Verifies preference fallbacks remain predictable when language or text settings are missing or blank.
// Inputs are supplied explicitly so results never depend on the developer's device settings.

import Foundation
import Testing
@testable import Menuscript

/// Covers `SettingsKeys.defaultTargetLanguage`: the fallback used only when
/// the user has never explicitly chosen a target language. Every case here
/// passes `appLanguage`/`systemLocale` explicitly so the result never
/// depends on the host machine's actual locale.
@Suite("SettingsKeys.defaultTargetLanguage")
struct SettingsKeysDefaultTargetLanguageTests {
    @Test("Explicit English app language defaults to English, regardless of system locale")
    /// Confirms choosing English in the app takes priority over the device language.
    func explicitEnglishDefaultsToEnglish() {
        #expect(SettingsKeys.defaultTargetLanguage(appLanguage: .english, systemLocale: Locale(identifier: "zh-Hant")) == "English")
        #expect(SettingsKeys.defaultTargetLanguage(appLanguage: .english, systemLocale: Locale(identifier: "ja_JP")) == "English")
    }

    @Test("Explicit zh-Hant app language defaults to 繁體中文, regardless of system locale")
    /// Confirms choosing Traditional Chinese takes priority over the device language.
    func explicitZhHantDefaultsToZhHant() {
        #expect(SettingsKeys.defaultTargetLanguage(appLanguage: .zhHant, systemLocale: Locale(identifier: "en_US")) == "繁體中文")
        #expect(SettingsKeys.defaultTargetLanguage(appLanguage: .zhHant, systemLocale: Locale(identifier: "ja_JP")) == "繁體中文")
    }

    @Test("System app language follows an English system locale")
    /// Confirms system-language mode selects English when iOS is using an English locale.
    func systemAppLanguageWithEnglishSystemLocaleDefaultsToEnglish() {
        #expect(SettingsKeys.defaultTargetLanguage(appLanguage: .system, systemLocale: Locale(identifier: "en")) == "English")
        #expect(SettingsKeys.defaultTargetLanguage(appLanguage: .system, systemLocale: Locale(identifier: "en_US")) == "English")
        #expect(SettingsKeys.defaultTargetLanguage(appLanguage: .system, systemLocale: Locale(identifier: "en_GB")) == "English")
    }

    @Test("System app language falls back to 繁體中文 for a non-English system locale", arguments: [
        "zh-Hant", "zh_TW", "ja_JP", "fr_FR", "ko_KR",
    ])
    /// Confirms every non-English system locale falls back to the app's Traditional Chinese default.
    func systemAppLanguageWithNonEnglishSystemLocaleDefaultsToZhHant(identifier: String) {
        #expect(SettingsKeys.defaultTargetLanguage(appLanguage: .system, systemLocale: Locale(identifier: identifier)) == "繁體中文")
    }
}

/// Covers `SettingsKeys.nonEmptyString`: a cleared free-text `@AppStorage`
/// field persists `""` (never `nil`), which plain `defaults.string(forKey:)
/// ?? fallback` never catches since `??` only fires on `nil`. Every case here
/// uses an isolated `UserDefaults` suite so tests never race on shared state.
@Suite("SettingsKeys.nonEmptyString")
struct SettingsKeysNonEmptyStringTests {
    private let suiteName = "test.settingskeys.\(UUID().uuidString)"
    private let key = "test.nonEmptyString.key"
    private let defaults: UserDefaults

    /// Creates a fresh private preference domain so each test starts without stored values.
    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Missing key falls back to the default")
    /// Confirms a setting never written by the user returns its supplied default.
    func missingKeyFallsBackToDefault() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(SettingsKeys.nonEmptyString(key, from: defaults, default: "fallback") == "fallback")
    }

    @Test("Empty string falls back to the default")
    /// Confirms clearing a text preference does not produce an unusable empty setting.
    func emptyStringFallsBackToDefault() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("", forKey: key)
        #expect(SettingsKeys.nonEmptyString(key, from: defaults, default: "fallback") == "fallback")
    }

    @Test("Whitespace-only string falls back to the default")
    /// Confirms spaces and line breaks alone count as no meaningful value.
    func whitespaceOnlyStringFallsBackToDefault() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("   \n", forKey: key)
        #expect(SettingsKeys.nonEmptyString(key, from: defaults, default: "fallback") == "fallback")
    }

    @Test("Value with surrounding whitespace is trimmed")
    /// Confirms accidental surrounding whitespace is removed before a stored value is used.
    func valueWithSurroundingWhitespaceIsTrimmed() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(" gemini-x ", forKey: key)
        #expect(SettingsKeys.nonEmptyString(key, from: defaults, default: "fallback") == "gemini-x")
    }

    @Test("Normal value passes through unchanged")
    /// Confirms a valid stored value is returned without modification.
    func normalValuePassesThrough() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("gemini-2.5-pro", forKey: key)
        #expect(SettingsKeys.nonEmptyString(key, from: defaults, default: "fallback") == "gemini-2.5-pro")
    }
}
