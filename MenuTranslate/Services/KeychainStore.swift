import Foundation
import Security

/// Thin, synchronous wrapper around Keychain Services for storing small
/// secrets (e.g. API keys) as generic password items.
struct KeychainStore: Sendable {
    /// Key name used to store the user's Gemini API key.
    static let geminiAPIKey = "gemini.apiKey"

    private let service: String

    init(service: String = "com.leonwong.menutranslate") {
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

    /// Returns the stored string for `key`, or `nil` if it's absent or the
    /// lookup fails for any reason.
    func get(_ key: String) -> String? {
        var searchQuery = query(forKey: key)
        searchQuery[kSecReturnData as String] = true
        searchQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(searchQuery as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the item stored under `key`. A missing item is not an error.
    func delete(_ key: String) throws {
        let status = SecItemDelete(query(forKey: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    private func query(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service
        ]
    }
}

/// Wraps a non-success `OSStatus` returned by a Keychain Services call.
enum KeychainError: Error, LocalizedError, Equatable {
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status):
            let statusText = String(status)
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return L10n.string("Keychain 操作失敗（%@）：%@", statusText, message)
            }
            return L10n.string("Keychain 操作失敗（錯誤代碼 %@）", statusText)
        }
    }
}
