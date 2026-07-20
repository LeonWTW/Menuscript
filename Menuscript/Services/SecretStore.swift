import Foundation

/// Storage boundary for small secrets. Reads distinguish a genuinely missing
/// value from an unavailable/corrupt secure store.
protocol SecretStore: Sendable {
    func read(_ key: String) throws -> String?
    func set(_ value: String, forKey key: String) throws
    func delete(_ key: String) throws
}
