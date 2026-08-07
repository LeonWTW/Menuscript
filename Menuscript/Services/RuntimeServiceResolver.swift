// Chooses one coherent set of live or offline services from settings and stored credentials.
// Centralizing this decision prevents a demo workflow from accidentally retaining a network-backed dependency.

import Foundation

/// Identifies whether a workflow must stay offline or may use production services.
enum RuntimeMode: String, Equatable, Sendable {
    case mock
    case live
}

/// The user-controlled inputs needed to assemble recognition and currency services.
struct RuntimeServiceConfiguration: Equatable, Sendable {
    /// Selects the offline demo or live provider family.
    var mode: RuntimeMode
    /// Names the Gemini model used only in live mode.
    var geminiModel: String = "gemini-2.5-flash"
}

/// Carries recognition and currency providers together with their resolved
/// mode, helping each workflow use a matching set of offline or live services.
struct RuntimeServices: Sendable {
    /// The resolved mode recorded with resulting work so its service source remains known.
    let mode: RuntimeMode
    /// The matching live or offline menu-recognition provider.
    let visionProvider: any MenuVisionProvider
    /// The matching live or offline exchange-rate provider.
    let fxRateProvider: any FXRateProviding
}

/// Composition helper that validates configuration before constructing a matched provider set.
enum RuntimeServiceResolver {
    /// Injectable constructor that delays live FX creation until live mode is actually selected.
    typealias LiveFXFactory = @Sendable () -> any FXRateProviding

    /// Returns the mode to use without changing the saved provider mode.
    /// The Demo Mode toggle always wins so an older live session can never
    /// override the user's current offline guarantee. With Demo Mode off,
    /// the saved provider mode still wins and older sessions use live mode.
    static func effectiveMode(
        persistedMode: RuntimeMode?,
        defaults: UserDefaults
    ) -> RuntimeMode {
        defaults.bool(forKey: SettingsKeys.useMockProvider)
            ? .mock
            : (persistedMode ?? .live)
    }

    /// Builds a matched service set, returning nil when live mode has no usable API key.
    /// The mock branch does not touch SecretStore, URLSession or
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

    /// Reads current app preferences, applies safe model defaults, and delegates to the core resolver.
    /// Keeping preference reading here gives existing screens one consistent composition entry point.
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
