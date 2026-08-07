// Stores API keys in Apple's device-only Keychain and translates low-level status codes into app errors.
// The wrapper gives the rest of the app a small testable interface instead of exposing Security-framework details.

import Foundation
import Security

/// Thin, synchronous wrapper around Keychain Services for storing small
/// secrets (e.g. API keys) as generic password items.
struct KeychainStore: Sendable, SecretStore {
    /// Key name used to store the user's Gemini API key.
    static let geminiAPIKey = "gemini.apiKey"

    private let service: String

    /// Creates a store in one Keychain service namespace so app secrets cannot collide with unrelated entries.
    init(service: String = "com.leonwong.menuscript") {
        self.service = service
    }

    /// Upserts `value` under `key`: updates the existing item if present,
    /// otherwise adds a new one. Both paths pin the item to
    /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — a BYOK secret only
    /// ever needed in the foreground on this device has no business
    /// migrating onto another device via an encrypted backup restore, which
    /// is what the previous default accessibility class allowed.
    func set(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        let matchQuery = query(forKey: key)

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(
            matchQuery as CFDictionary,
            updateAttributes as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = matchQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandledStatus(addStatus)
            }
        default:
            throw KeychainError.unhandledStatus(updateStatus)
        }
    }

    /// Returns nil only when the item is genuinely absent. Keychain access
    /// failures and corrupt data remain actionable typed errors.
    func read(_ key: String) throws -> String? {
        var searchQuery = query(forKey: key)
        searchQuery[kSecReturnData as String] = true
        searchQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(searchQuery as CFDictionary, &result)
        return try Self.decodeReadResult(status: status, data: result as? Data)
    }

    /// Deletes the item stored under `key`. A missing item is not an error.
    func delete(_ key: String) throws {
        let status = SecItemDelete(query(forKey: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    /// Builds the common Keychain lookup identity used consistently by reads, writes, and deletes.
    private func query(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service
        ]
    }

    /// Separate decoding helper used by tests to cover statuses and data that are hard
    /// to manufacture through the signed simulator Keychain.
    static func decodeReadResult(status: OSStatus, data: Data?) throws -> String? {
        switch status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let data else {
                throw KeychainError.invalidResult
            }
            guard let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidUTF8
            }
            return value
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }
}

/// Represents either a failed Keychain status or stored data that cannot be decoded safely.
enum KeychainError: Error, LocalizedError, Equatable {
    case unhandledStatus(OSStatus)
    case invalidResult
    case invalidUTF8

    /// Converts technical Keychain failures into localized messages suitable for the Settings UI.
    var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status):
            let statusText = String(status)
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return L10n.string("Keychain 操作失敗（%@）：%@", statusText, message)
            }
            return L10n.string("Keychain 操作失敗（錯誤代碼 %@）", statusText)
        case .invalidResult:
            return L10n.string("Keychain 回傳咗無效資料。")
        case .invalidUTF8:
            return L10n.string("Keychain 內嘅 API Key 資料已損壞。")
        }
    }
}
