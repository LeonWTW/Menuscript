// Defines the minimal secure-storage operations needed by settings and service composition.
// Keeping this as a protocol allows tests to substitute an in-memory store without accessing a real Keychain.

import Foundation

/// Storage boundary for small secrets. Reads distinguish a genuinely missing
/// value from an unavailable/corrupt secure store.
protocol SecretStore: Sendable {
    /// Returns a stored secret, nil when it is genuinely absent, or throws when storage cannot be read safely.
    func read(_ key: String) throws -> String?
    /// Creates or replaces a secret under the supplied logical key.
    func set(_ value: String, forKey key: String) throws
    /// Removes a secret while treating an already-missing value as a successful outcome.
    func delete(_ key: String) throws
}
