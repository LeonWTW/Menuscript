import Foundation

enum RuntimeMode: String, Equatable, Sendable {
    case mock
    case live
}

struct RuntimeServiceConfiguration: Equatable, Sendable {
    var mode: RuntimeMode
    var geminiModel: String = "gemini-2.5-flash"
}

/// Production resolution keeps vision and FX providers as one unit, so mock
/// vision can never accidentally retain the live FX provider. Test and
/// preview injection defaults custom vision to mock FX when no FX provider is
/// supplied, keeping the seam network-hermetic while preserving separate
/// vision and FX provenance.
struct RuntimeServices: Sendable {
    let mode: RuntimeMode
    let visionProvider: any MenuVisionProvider
    let fxRateProvider: any FXRateProviding
}

enum RuntimeServiceResolver {
    typealias LiveFXFactory = @Sendable () -> any FXRateProviding

    /// Returns the mode to use without changing persisted provider provenance.
    /// The Demo Mode toggle always wins so an older live session can never
    /// override the user's current offline guarantee. With Demo Mode off,
    /// persisted provenance still wins and legacy sessions use live mode.
    static func effectiveMode(
        persistedMode: RuntimeMode?,
        defaults: UserDefaults
    ) -> RuntimeMode {
        defaults.bool(forKey: SettingsKeys.useMockProvider)
            ? .mock
            : (persistedMode ?? .live)
    }

    /// Core resolver. The mock branch does not touch SecretStore, URLSession or
    /// UserDefaults and does not evaluate the live FX factory.
    static func resolve(
        configuration: RuntimeServiceConfiguration,
        secretStore: any SecretStore,
        liveFXFactory: LiveFXFactory = { FXService() }
    ) throws -> RuntimeServices? {
        switch configuration.mode {
        case .mock:
            return RuntimeServices(
                mode: .mock,
                visionProvider: MockVisionProvider(),
                fxRateProvider: MockFXService()
            )
        case .live:
            guard let storedKey = try secretStore.read(KeychainStore.geminiAPIKey) else {
                return nil
            }
            let key = storedKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }

            let model = configuration.geminiModel
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return RuntimeServices(
                mode: .live,
                visionProvider: GeminiProvider(
                    apiKey: { key },
                    model: model.isEmpty ? "gemini-2.5-flash" : model
                ),
                fxRateProvider: liveFXFactory()
            )
        }
    }

    /// Preferences adapter retained until Wave 2 moves UI ownership of mode
    /// and dependencies into a composition root.
    static func resolveFromPreferences(
        secretStore: any SecretStore = KeychainStore(),
        defaults: UserDefaults = .standard,
        liveFXFactory: LiveFXFactory = { FXService() }
    ) throws -> RuntimeServices? {
        let mode = effectiveMode(persistedMode: nil, defaults: defaults)
        let model = mode == .mock
            ? "gemini-2.5-flash"
            : SettingsKeys.nonEmptyString(
                SettingsKeys.geminiModel,
                from: defaults,
                default: "gemini-2.5-flash"
            )
        return try resolve(
            configuration: RuntimeServiceConfiguration(
                mode: mode,
                geminiModel: model
            ),
            secretStore: secretStore,
            liveFXFactory: liveFXFactory
        )
    }
}
