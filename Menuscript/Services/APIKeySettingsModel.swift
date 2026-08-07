// Manages the Settings screen's API-key state without exposing the stored secret.
// The model keeps secure-storage errors distinct from a genuinely missing key.

import Foundation
import Observation

/// Describes what the app currently knows about the saved Gemini API key.
enum APIKeyPresence: Equatable, Sendable {
    case unknown
    case missing
    case stored
    case unavailable(lastKnownStored: Bool)

    /// Reports whether the last reliable state says a key exists, including during a temporary Keychain failure.
    var hasStoredKey: Bool {
        switch self {
        case .stored:
            return true
        case .unavailable(let lastKnownStored):
            return lastKnownStored
        case .unknown, .missing:
            return false
        }
    }
}

/// Testable state boundary for Settings. Secure-store failures never masquerade
/// as a missing key, and failed writes/deletes do not erase the user's state.
@Observable
@MainActor
final class APIKeySettingsModel {
    var input = ""
    private(set) var presence: APIKeyPresence = .unknown
    private(set) var errorMessage: String?

    /// Gives the UI a simple yes/no value without exposing the full storage state.
    var hasStoredKey: Bool { presence.hasStoredKey }

    private let secretStore: any SecretStore

    /// Creates the Settings model with an injectable secure store so tests never need the real Keychain.
    init(secretStore: any SecretStore = KeychainStore()) {
        self.secretStore = secretStore
    }

    /// Rechecks secure storage and updates the UI state without treating read failures as a deleted key.
    func refresh() {
        let lastKnownStored = presence.hasStoredKey
        do {
            let stored = try secretStore.read(KeychainStore.geminiAPIKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            presence = (stored?.isEmpty == false) ? .stored : .missing
            errorMessage = nil
        } catch {
            presence = .unavailable(lastKnownStored: lastKnownStored)
            errorMessage = Self.safeMessage(for: error)
        }
    }

    /// Saves a trimmed, non-empty key and clears the text field only after storage succeeds.
    func save() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try secretStore.set(trimmed, forKey: KeychainStore.geminiAPIKey)
            input = ""
            presence = .stored
            errorMessage = nil
        } catch {
            errorMessage = Self.safeMessage(for: error)
        }
    }

    /// Removes the stored key and updates the UI only after the secure-store deletion succeeds.
    func delete() {
        do {
            try secretStore.delete(KeychainStore.geminiAPIKey)
            input = ""
            presence = .missing
            errorMessage = nil
        } catch {
            errorMessage = Self.safeMessage(for: error)
        }
    }

    /// Converts storage errors into a safe localized message that never reveals secret values or system details.
    private static func safeMessage(for error: Error) -> String {
        if let keychainError = error as? KeychainError {
            return keychainError.errorDescription
                ?? L10n.string("Keychain 暫時無法使用，請稍後再試。")
        }
        return L10n.string("Keychain 暫時無法使用，請稍後再試。")
    }
}
