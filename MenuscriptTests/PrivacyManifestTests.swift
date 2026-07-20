import Foundation
import Testing

@Suite("Privacy manifest")
struct PrivacyManifestTests {
    private var manifestURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Menuscript/Resources/PrivacyInfo.xcprivacy")
    }

    private func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: manifestURL)
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
    }

    @Test("Declares no tracking or tracking domains")
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
