// Verifies the photo-retention preference keeps a stable stored contract and
// that an unreadable saved choice always falls back to the safe default window.

import Foundation
import Testing
@testable import Menuscript

/// Covers `PhotoRetentionPolicy`: the raw values written to preferences, the
/// window each choice means in seconds, and the fallback used when the stored
/// value is missing or was written by a version this build does not know.
/// Every case uses an isolated `UserDefaults` suite so tests never race on
/// shared state or read the developer's own settings.
@Suite("PhotoRetentionPolicy")
struct PhotoRetentionPolicyTests {
    private let suiteName = "test.photoretention.\(UUID().uuidString)"
    private let defaults: UserDefaults

    /// Creates a fresh private preference domain so each test starts without stored values.
    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Stored raw values and picker order are the persistence contract")
    /// Confirms renaming a raw value cannot silently reset every user's saved choice.
    func rawValuesAreTheStoredContract() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(PhotoRetentionPolicy.days30.rawValue == "30d")
        #expect(PhotoRetentionPolicy.days90.rawValue == "90d")
        #expect(PhotoRetentionPolicy.forever.rawValue == "forever")
        #expect(PhotoRetentionPolicy.allCases == [.days30, .days90, .forever])
    }

    @Test("Each choice maps to its exact retention window")
    /// Confirms the windows pruning compares against are fixed 86,400-second days.
    func retentionWindowsUseFixedDays() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(PhotoRetentionPolicy.days30.retentionWindow == 2_592_000)
        #expect(PhotoRetentionPolicy.days90.retentionWindow == 7_776_000)
        #expect(PhotoRetentionPolicy.forever.retentionWindow == nil)
    }

    @Test("A missing preference resolves to the 30-day default")
    /// Confirms a user who never opened Settings still gets the documented default.
    func missingPreferenceResolvesToDefault() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(PhotoRetentionPolicy.resolve(from: defaults) == .days30)
    }

    @Test("An unknown stored value resolves to the 30-day default")
    /// Confirms a value from another app version can never disable pruning by accident.
    func unknownStoredValueResolvesToDefault() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("2 weeks", forKey: SettingsKeys.photoRetention)
        #expect(PhotoRetentionPolicy.resolve(from: defaults) == .days30)
    }

    @Test("Every valid stored value round-trips", arguments: PhotoRetentionPolicy.allCases)
    /// Confirms each choice the picker can save is read back as the same choice.
    func storedValuesRoundTrip(policy: PhotoRetentionPolicy) {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(policy.rawValue, forKey: SettingsKeys.photoRetention)
        #expect(PhotoRetentionPolicy.resolve(from: defaults) == policy)
    }
}
