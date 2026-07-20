import Testing
@testable import Menuscript

private enum SettingsSecretStoreError: Error {
    case unavailable
}

private final class SettingsSecretStoreStub: @unchecked Sendable, SecretStore {
    var value: String?
    var readError: Error?
    var setError: Error?
    var deleteError: Error?

    init(value: String? = nil) {
        self.value = value
    }

    func read(_ key: String) throws -> String? {
        if let readError { throw readError }
        return value
    }

    func set(_ value: String, forKey key: String) throws {
        if let setError { throw setError }
        self.value = value
    }

    func delete(_ key: String) throws {
        if let deleteError { throw deleteError }
        value = nil
    }
}

@MainActor
@Suite("API key settings state")
struct APIKeySettingsModelTests {
    @Test("Read failure is unavailable, not missing")
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
