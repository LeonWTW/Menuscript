import Foundation
import Testing
@testable import Menuscript

@Suite("ProviderFactory")
struct ProviderFactoryTests {
    // Unique per test instance (Swift Testing creates a fresh struct per
    // @Test): an isolated UserDefaults suite plus a throwaway keychain
    // service, so parallel tests never race on shared state.
    private let suiteName = "test.providerfactory.\(UUID().uuidString)"
    private let service = "com.leonwong.menuscript.tests.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Mock toggle on resolves to MockVisionProvider, even with an empty keychain")
    func mockToggleOnResolvesToMockProvider() throws {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: SettingsKeys.useMockProvider)

        let keychain = KeychainStore(service: service)
        let provider = try #require(ProviderFactory.resolve(keychain: keychain, defaults: defaults))
        #expect(provider is MockVisionProvider)
    }

    @Test("Mock toggle off with no stored key resolves to nil")
    func mockToggleOffWithEmptyKeychainResolvesToNil() {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: SettingsKeys.useMockProvider)

        let keychain = KeychainStore(service: service)
        #expect(ProviderFactory.resolve(keychain: keychain, defaults: defaults) == nil)
    }

    @Test("Mock toggle off with a stored key resolves to GeminiProvider")
    func mockToggleOffWithStoredKeyResolvesToGeminiProvider() throws {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: SettingsKeys.useMockProvider)

        let keychain = KeychainStore(service: service)
        try keychain.set("fake-test-api-key", forKey: KeychainStore.geminiAPIKey)
        defer { try? keychain.delete(KeychainStore.geminiAPIKey) }

        let provider = try #require(ProviderFactory.resolve(keychain: keychain, defaults: defaults))
        #expect(provider is GeminiProvider)
    }
}
