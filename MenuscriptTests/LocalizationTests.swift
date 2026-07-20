import Foundation
import Testing
@testable import Menuscript

// MARK: - Catalog completeness

/// Guards the app's localization strategy: zh-Hant literals are the keys,
/// and every key must carry explicit en AND zh-Hant entries. The explicit
/// zh-Hant entry is what makes Xcode emit zh-Hant.lproj at all — without it,
/// L10n's bundle lookup breaks for "English system + in-app 繁中".
@Suite("String catalog completeness")
struct StringCatalogTests {
    private struct FormatArgument: Equatable {
        let position: Int
        let type: String
    }

    private static let catalogPaths = [
        "Menuscript/Resources/Localizable.xcstrings",
        "Menuscript/Resources/InfoPlist.xcstrings",
    ]

    private static func repoRoot() -> URL {
        // #filePath = <repo>/MenuscriptTests/LocalizationTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadCatalog(_ relativePath: String) throws -> [String: Any] {
        let url = Self.repoRoot().appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)
        return try #require(json as? [String: Any], "\(relativePath) is not a JSON object")
    }

    /// A localization entry is complete when its stringUnit — or, for
    /// variation entries, every leaf stringUnit — is state "translated".
    private func assertTranslated(_ localization: [String: Any], key: String, lang: String) {
        if let unit = localization["stringUnit"] as? [String: Any] {
            #expect(
                unit["state"] as? String == "translated",
                "\(key) [\(lang)]: stringUnit state is not translated"
            )
            return
        }
        guard let variations = localization["variations"] as? [String: Any], !variations.isEmpty else {
            Issue.record("\(key) [\(lang)]: has neither stringUnit nor variations")
            return
        }
        for (variationType, cases) in variations {
            guard let cases = cases as? [String: Any], !cases.isEmpty else {
                Issue.record("\(key) [\(lang)] \(variationType): empty variation group")
                continue
            }
            for (caseName, caseValue) in cases {
                let unit = (caseValue as? [String: Any])?["stringUnit"] as? [String: Any]
                #expect(
                    unit?["state"] as? String == "translated",
                    "\(key) [\(lang)] \(variationType)/\(caseName): not translated"
                )
            }
        }
    }

    private func localizedLeafValues(in value: Any) -> [String] {
        guard let dictionary = value as? [String: Any] else {
            if let array = value as? [Any] {
                return array.flatMap { localizedLeafValues(in: $0) }
            }
            return []
        }
        if let unit = dictionary["stringUnit"] as? [String: Any],
           let value = unit["value"] as? String {
            return [value]
        }
        return dictionary.values.flatMap { localizedLeafValues(in: $0) }
    }

    /// Returns the semantic argument position and type for the printf-style
    /// placeholders supported by this catalog. `%%` is a literal percent.
    private func formatArguments(in value: String) throws -> [FormatArgument] {
        let regex = try NSRegularExpression(
            pattern: #"%(?:%|(?:(\d+)\$)?((?:\.\d+)?(?:ll)?[@df]))"#
        )
        let range = NSRange(value.startIndex..., in: value)
        var nextSequentialPosition = 1
        var arguments: [FormatArgument] = []

        for match in regex.matches(in: value, range: range) {
            guard let typeRange = Range(match.range(at: 2), in: value) else {
                continue
            }
            let type = String(value[typeRange])
            let position: Int
            if let explicitRange = Range(match.range(at: 1), in: value),
               let explicit = Int(value[explicitRange]) {
                position = explicit
            } else {
                position = nextSequentialPosition
                nextSequentialPosition += 1
            }
            arguments.append(FormatArgument(position: position, type: type))
        }

        return arguments.sorted {
            if $0.position == $1.position {
                return $0.type < $1.type
            }
            return $0.position < $1.position
        }
    }

    @Test("Every key has translated en and zh-Hant entries", arguments: catalogPaths)
    func everyKeyFullyLocalized(relativePath: String) throws {
        let catalog = try loadCatalog(relativePath)
        #expect(catalog["sourceLanguage"] as? String == "zh-Hant")

        let strings = try #require(catalog["strings"] as? [String: Any], "no strings dict")
        #expect(!strings.isEmpty, "\(relativePath) has no keys")

        for (key, entry) in strings {
            guard let entry = entry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else {
                Issue.record("\(key): no localizations")
                continue
            }
            for lang in ["en", "zh-Hant"] {
                guard let localization = localizations[lang] as? [String: Any] else {
                    Issue.record("\(key): missing \(lang) localization")
                    continue
                }
                assertTranslated(localization, key: key, lang: lang)
            }
        }
    }

    @Test("Localized format placeholders preserve argument positions and types", arguments: catalogPaths)
    func localizedFormatArgumentsMatchSource(relativePath: String) throws {
        let catalog = try loadCatalog(relativePath)
        let strings = try #require(catalog["strings"] as? [String: Any], "no strings dict")

        for (key, rawEntry) in strings {
            let entry = try #require(rawEntry as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let expected = try formatArguments(in: key)

            for language in ["en", "zh-Hant"] {
                let localization = try #require(localizations[language] as? [String: Any])
                for value in localizedLeafValues(in: localization) {
                    let actual = try formatArguments(in: value)
                    #expect(
                        actual == expected,
                        "\(key) [\(language)] changes its format arguments: \(value)"
                    )
                }
            }
        }
    }
}

// MARK: - AppLanguage

@Suite("AppLanguage")
struct AppLanguageTests {
    // Isolated per test instance; never touches UserDefaults.standard
    // (Swift Testing runs in parallel — .standard would race).
    private let suiteName = "test.applanguage.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Unset defaults resolve to .system")
    func unsetResolvesToSystem() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(AppLanguage.resolve(from: defaults) == .system)
    }

    @Test("Stored raw values resolve to their cases", arguments: [
        ("zh-Hant", AppLanguage.zhHant),
        ("en", AppLanguage.english),
        ("system", AppLanguage.system),
    ])
    func storedValueResolves(raw: String, expected: AppLanguage) {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(raw, forKey: SettingsKeys.appLanguage)
        #expect(AppLanguage.resolve(from: defaults) == expected)
    }

    @Test("Garbage stored value falls back to .system")
    func garbageResolvesToSystem() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("klingon-XX", forKey: SettingsKeys.appLanguage)
        #expect(AppLanguage.resolve(from: defaults) == .system)
    }

    @Test("locale mapping: system is nil, explicit languages map to identifiers")
    func localeMapping() {
        #expect(AppLanguage.system.locale == nil)
        #expect(AppLanguage.zhHant.locale?.identifier == "zh-Hant")
        #expect(AppLanguage.english.locale?.identifier == "en")
    }
}
