import Foundation

enum GeminiDisclosureError: Error, Equatable, Sendable {
    case consentRequired
}

/// Shared persisted-consent boundary for features that can send user data to
/// Google Gemini. The effective mode is decided without resolving secrets or
/// constructing live services, so an unaccepted live action stops before any
/// provider boundary while mock mode remains fully offline.
@MainActor
enum GeminiDisclosureGate {
    static let acceptedKey = "privacy.googleGeminiDisclosureAccepted.v1"

    static func effectiveMode(
        explicitMode: RuntimeMode?,
        defaults: UserDefaults
    ) -> RuntimeMode {
        RuntimeServiceResolver.effectiveMode(
            persistedMode: explicitMode,
            defaults: defaults
        )
    }

    static func requiresConsent(
        explicitMode: RuntimeMode?,
        defaults: UserDefaults
    ) -> Bool {
        effectiveMode(explicitMode: explicitMode, defaults: defaults) == .live
            && !defaults.bool(forKey: acceptedKey)
    }

    static func accept(defaults: UserDefaults) {
        defaults.set(true, forKey: acceptedKey)
    }
}
