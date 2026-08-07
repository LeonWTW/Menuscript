// Verifies Settings represents Gemini API-key storage failures honestly without exposing the secret.
// A controllable in-memory store makes every secure-storage outcome reproducible and offline.

import Testing
@testable import Menuscript

/// A predictable error used to simulate temporary secure-storage unavailability.
private enum SettingsSecretStoreError: Error {
    case unavailable
}

/// An in-memory SecretStore whose reads, writes, and deletes can fail independently for testing.
private final class SettingsSecretStoreStub: @unchecked Sendable, SecretStore {
    var value: String?
    var readError: Error?
    var setError: Error?
    var deleteError: Error?

    /// Starts the stub with an optional saved value so tests can model missing or existing keys.
    init(value: String? = nil) {
        self.value = value
    }

    /// Returns the stored value unless the test has injected a read error.
    func read(_ key: String) throws -> String? {
        if let readError { throw readError }
        return value
    }

    /// Replaces the stored value unless the test has injected a write error.
    func set(_ value: String, forKey key: String) throws {
        if let setError { throw setError }
        self.value = value
    }

    /// Clears the stored value unless the test has injected a deletion error.
    func delete(_ key: String) throws {
        if let deleteError { throw deleteError }
        value = nil
    }
}

@MainActor
@Suite("API key settings state")
/// Protects how the Settings model distinguishes missing keys from Keychain failures.
struct APIKeySettingsModelTests {
    @Test("Read failure is unavailable, not missing")
    /// Confirms a failed Keychain read is shown as unavailable rather than falsely claiming no key exists.
    func readFailureIsUnavailable() {
        let store = SettingsSecretStoreStub()
        store.readError = SettingsSecretStoreError.unavailable
        let model = APIKeySettingsModel(secretStore: store)

        model.refresh()

        #expect(model.presence == .unavailable(lastKnownStored: false))
        #expect(model.presence != .missing)
        #expect(!model.hasStoredKey)
        #expect(model.errorMessage != nil)
    }

    @Test("Read failure preserves last-known stored state")
    /// Confirms a later read failure remembers that the most recent successful check found a key.
    func readFailurePreservesLastKnownStoredState() {
        let store = SettingsSecretStoreStub(value: "stored-key")
        let model = APIKeySettingsModel(secretStore: store)
        model.refresh()
        #expect(model.presence == .stored)

        store.readError = SettingsSecretStoreError.unavailable
        model.refresh()

        #expect(model.presence == .unavailable(lastKnownStored: true))
        #expect(model.hasStoredKey)
        #expect(model.errorMessage != nil)
    }

    @Test("Save failure preserves input and does not report a stored key")
    /// Confirms failed saving leaves the user's typed key available to retry and does not report success.
    func saveFailurePreservesInput() {
        let store = SettingsSecretStoreStub()
        store.setError = SettingsSecretStoreError.unavailable
        let model = APIKeySettingsModel(secretStore: store)
        model.input = "key-that-could-not-be-saved"

        model.save()

        #expect(model.input == "key-that-could-not-be-saved")
        #expect(model.presence == .unknown)
        #expect(!model.hasStoredKey)
        #expect(store.value == nil)
        #expect(model.errorMessage != nil)
    }

    @Test("Delete failure preserves stored presence")
    /// Confirms failed deletion keeps the known stored-key state instead of pretending the key vanished.
    func deleteFailurePreservesStoredPresence() {
        let store = SettingsSecretStoreStub(value: "stored-key")
        let model = APIKeySettingsModel(secretStore: store)
        model.refresh()
        #expect(model.presence == .stored)

        store.deleteError = SettingsSecretStoreError.unavailable
        model.delete()

        #expect(model.presence == .stored)
        #expect(model.hasStoredKey)
        #expect(store.value == "stored-key")
        #expect(model.errorMessage != nil)
    }
}
