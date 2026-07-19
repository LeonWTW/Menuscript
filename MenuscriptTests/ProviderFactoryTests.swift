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

    @Test("Empty-string model key still yields a provider configured with the default model")
    func emptyStringModelKeyStillYieldsDefaultModel() throws {
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: SettingsKeys.useMockProvider)
        defaults.set("", forKey: SettingsKeys.geminiModel)

        let keychain = KeychainStore(service: service)
        try keychain.set("fake-test-api-key", forKey: KeychainStore.geminiAPIKey)
        defer { try? keychain.delete(KeychainStore.geminiAPIKey) }

        let resolved = try #require(ProviderFactory.resolve(keychain: keychain, defaults: defaults))
        let provider = try #require(resolved as? GeminiProvider)
        // No `model` property to introspect directly; the model id lands in
        // the request URL, same seam GeminiRequestTests uses.
        let request = try provider.buildExtractRequest(images: [Data([0xFF])], targetLanguage: "繁體中文")
        let url = try #require(request.url?.absoluteString)
        #expect(url.contains("gemini-2.5-flash"))
    }
}
