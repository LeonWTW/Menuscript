import Foundation

/// Resolves which `MenuVisionProvider` to use from the same Settings
/// precedence as `CaptureViewModel`'s internal resolution: the mock toggle
/// wins outright, otherwise a stored Gemini API key is required.
///
/// Note: this duplicates `CaptureViewModel.recognize()`'s inline provider
/// resolution for now. Not refactored to share a single implementation in
/// this phase — left for a later review pass.
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

        let model = defaults.string(forKey: SettingsKeys.geminiModel) ?? "gemini-2.5-flash"
        return GeminiProvider(apiKey: { apiKey }, model: model)
    }
}
