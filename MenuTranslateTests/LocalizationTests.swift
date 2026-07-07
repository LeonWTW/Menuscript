import Foundation
import Testing
@testable import MenuTranslate

// MARK: - Catalog completeness

/// Guards the app's localization strategy: zh-Hant literals are the keys,
/// and every key must carry explicit en AND zh-Hant entries. The explicit
/// zh-Hant entry is what makes Xcode emit zh-Hant.lproj at all — without it,
/// L10n's bundle lookup breaks for "English system + in-app 繁中".
@Suite("String catalog completeness")
struct StringCatalogTests {
    private static let catalogPaths = [
        "MenuTranslate/Resources/Localizable.xcstrings",
        "MenuTranslate/Resources/InfoPlist.xcstrings",
    ]

    private static func repoRoot() -> URL {
        // #filePath = <repo>/MenuTranslateTests/LocalizationTests.swift
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
