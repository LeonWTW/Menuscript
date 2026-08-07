// Defines the app's supported interface languages and converts saved choices
// into locales, keeping language-selection rules in one place.

import Foundation

/// A stable, storable choice for the language used by the app's interface.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case zhHant = "zh-Hant"
    case english = "en"

    /// Uses the stored language code as the stable identity shown in pickers.
    var id: String { rawValue }

    /// Returns a fixed locale for an explicit choice, or `nil` to follow the device.
    var locale: Locale? {
        self == .system ? nil : Locale(identifier: rawValue)
    }

    /// Reads the saved preference and safely falls back to the device language
    /// when the value is missing or comes from an unknown app version.
    static func resolve(from defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: SettingsKeys.appLanguage) ?? "") ?? .system
    }
}
