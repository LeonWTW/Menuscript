// Verifies the checked-in Apple privacy manifest declares only the app's approved data and API use.
// Treating the manifest as executable policy prevents accidental privacy changes during development.

import Foundation
import Testing

@Suite("Privacy manifest")
/// Protects the no-tracking promise, declared data categories, and UserDefaults justification.
struct PrivacyManifestTests {
    /// Locates the production privacy manifest relative to this test file, independent of the working directory.
    private var manifestURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Menuscript/Resources/PrivacyInfo.xcprivacy")
    }

    /// Parses the manifest into a dictionary so each declared privacy field can be checked exactly.
    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: manifestURL)
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
    }

    @Test("Declares no tracking or tracking domains")
    /// Confirms the app explicitly disables tracking and lists no tracker domains.
    func noTracking() throws {
        let manifest = try manifest()

        #expect(Set(manifest.keys) == [
            "NSPrivacyTracking",
            "NSPrivacyCollectedDataTypes",
            "NSPrivacyAccessedAPITypes"
        ])
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect(manifest.keys.contains("NSPrivacyTrackingDomains") == false)
    }

    @Test("Declares the approved linked app-functionality data types")
    /// Confirms only photos, user content, and allergen-related health data are declared as linked data.
    func collectedDataTypes() throws {
        let manifest = try manifest()
        let entries = try #require(
            manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]]
        )
        let expectedTypes = Set([
            "NSPrivacyCollectedDataTypePhotosorVideos",
            "NSPrivacyCollectedDataTypeOtherUserContent",
            "NSPrivacyCollectedDataTypeHealth"
        ])

        #expect(entries.count == expectedTypes.count)
        #expect(Set(entries.compactMap { $0["NSPrivacyCollectedDataType"] as? String }) == expectedTypes)
        for entry in entries {
            #expect(Set(entry.keys) == [
                "NSPrivacyCollectedDataType",
                "NSPrivacyCollectedDataTypeLinked",
                "NSPrivacyCollectedDataTypeTracking",
                "NSPrivacyCollectedDataTypePurposes"
            ])
            #expect(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool == true)
            #expect(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
            #expect(
                entry["NSPrivacyCollectedDataTypePurposes"] as? [String]
                    == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
            )
        }
    }

    @Test("Declares the UserDefaults required-reason API")
    /// Confirms Apple's approved reason code is present for local preference storage.
    func userDefaultsRequiredReason() throws {
        let manifest = try manifest()
        let entries = try #require(
            manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        )
        let entry = try #require(entries.first)

        #expect(entries.count == 1)
        #expect(Set(entry.keys) == [
            "NSPrivacyAccessedAPIType",
            "NSPrivacyAccessedAPITypeReasons"
        ])
        #expect(
            entry["NSPrivacyAccessedAPIType"] as? String
                == "NSPrivacyAccessedAPICategoryUserDefaults"
        )
        #expect(entry["NSPrivacyAccessedAPITypeReasons"] as? [String] == ["CA92.1"])
    }
}
