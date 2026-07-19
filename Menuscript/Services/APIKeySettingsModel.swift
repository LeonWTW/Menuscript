import Foundation
import Observation

enum APIKeyPresence: Equatable, Sendable {
    case unknown
    case missing
    case stored
    case unavailable(lastKnownStored: Bool)

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

    var hasStoredKey: Bool { presence.hasStoredKey }

    private let secretStore: any SecretStore

    init(secretStore: any SecretStore = KeychainStore()) {
        self.secretStore = secretStore
    }

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

    private static func safeMessage(for error: Error) -> String {
        if let keychainError = error as? KeychainError {
            return keychainError.errorDescription
                ?? L10n.string("Keychain 暫時無法使用，請稍後再試。")
        }
        return L10n.string("Keychain 暫時無法使用，請稍後再試。")
    }
}
