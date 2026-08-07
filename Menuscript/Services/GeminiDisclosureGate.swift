// Enforces the user's privacy consent before any live Gemini feature can send data off-device.
// Mode and consent checks stay separate from provider creation so blocked actions cannot touch secrets or networking.

import Foundation

/// Signals that a live Gemini action was stopped because the privacy disclosure has not been accepted.
enum GeminiDisclosureError: Error, Equatable, Sendable {
    case consentRequired
}

/// Shared persisted-consent boundary for features that can send user data to
/// Google Gemini. The effective mode is decided without resolving secrets or
/// constructing live services, so an unaccepted live action stops before any
/// provider boundary while mock mode remains fully offline.
@MainActor
enum GeminiDisclosureGate {
    /// The versioned preference key recording acceptance of the current disclosure wording.
    static let acceptedKey = "privacy.googleGeminiDisclosureAccepted.v1"

    /// Resolves whether an action is really live or offline, honoring the global Demo Mode setting.
    static func effectiveMode(
        explicitMode: RuntimeMode?,
        defaults: UserDefaults
    ) -> RuntimeMode {
        RuntimeServiceResolver.effectiveMode(
            persistedMode: explicitMode,
            defaults: defaults
        )
    }

    /// Returns true only when an action would use Gemini and the matching disclosure has not been accepted.
    static func requiresConsent(
        explicitMode: RuntimeMode?,
        defaults: UserDefaults
    ) -> Bool {
        effectiveMode(explicitMode: explicitMode, defaults: defaults) == .live
            && !defaults.bool(forKey: acceptedKey)
    }

    /// Records consent locally; callers present the disclosure before invoking this function.
    static func accept(defaults: UserDefaults) {
        defaults.set(true, forKey: acceptedKey)
    }
}
