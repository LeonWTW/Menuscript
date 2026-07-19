import Foundation

/// Resolves which `MenuVisionProvider` to use: the mock toggle wins outright,
/// otherwise a stored Gemini API key is required. Shared by both
/// `CaptureViewModel.recognize()` and `ExplainSheet` so the two features can
/// never silently diverge on provider precedence or default model.
enum ProviderFactory {
    static func resolve(
        keychain: KeychainStore = KeychainStore(),
        defaults: UserDefaults = .standard
    ) -> MenuVisionProvider? {
        if defaults.bool(forKey: SettingsKeys.useMockProvider) {
            return MockVisionProvider()
        }

        guard let apiKey = keychain.get(KeychainStore.geminiAPIKey), !apiKey.isEmpty else {
            return nil
        }

        let model = SettingsKeys.nonEmptyString(SettingsKeys.geminiModel, from: defaults, default: "gemini-2.5-flash")
        return GeminiProvider(apiKey: { apiKey }, model: model)
    }
}
