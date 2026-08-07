// Localizes text created in Swift code, where SwiftUI cannot automatically
// look up the app's own language preference.

import Foundation

/// Looks up programmatically created text, such as errors and summaries, using
/// the language chosen inside the app rather than blindly using the device language.
enum L10n {
    /// Finds a key in the selected language bundle. If an explicitly selected
    /// bundle is unavailable, the Traditional Chinese source key is the safest
    /// fallback; `Bundle.main` could silently switch back to the device language.
    private static func lookup(_ key: String, defaults: UserDefaults) -> String {
        let lang = AppLanguage.resolve(from: defaults)
        guard let identifier = lang.locale?.identifier else {
            return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        }
        guard let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    /// Returns a localized string that contains no formatting placeholders.
    static func string(_ key: String, defaults: UserDefaults = .standard) -> String {
        lookup(key, defaults: defaults)
    }

    /// Returns a localized string after inserting values into its format placeholders.
    static func string(_ key: String, _ args: CVarArg..., defaults: UserDefaults = .standard) -> String {
        String(format: lookup(key, defaults: defaults), arguments: args)
    }
}
