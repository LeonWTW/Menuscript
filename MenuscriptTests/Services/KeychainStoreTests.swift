// Verifies API keys can be stored, replaced, read, and deleted through Apple's Keychain safely.
// Each test receives a unique service name and skips only when the test host lacks Keychain entitlement.

import XCTest
@testable import Menuscript

/// Covers real Keychain round trips plus the pure decoder that interprets Security framework results.
final class KeychainStoreTests: XCTestCase {
    private var store: KeychainStore!
    private let key = "test.key"

    /// Creates an isolated Keychain namespace before each test to prevent collisions with real app data.
    override func setUp() {
        super.setUp()
        // Unique service namespace per test run so tests never collide with
        // each other or with any real stored data.
        let service = "com.leonwong.menuscript.tests.\(UUID().uuidString)"
        store = KeychainStore(service: service)
    }

    /// Removes any test secret and releases the store after each test.
    override func tearDown() {
        try? store.delete(key)
        store = nil
        super.tearDown()
    }

    /// Confirms a saved UTF-8 value can be read back unchanged.
    func testSetGetRoundTrip() throws {
        try setOrSkip("hello-world", forKey: key)
        let value = try readOrSkip(key)
        XCTAssertEqual(value, "hello-world")
    }

    /// Confirms saving the same key again replaces its previous value.
    func testOverwriteUpdatesValue() throws {
        try setOrSkip("first-value", forKey: key)
        try setOrSkip("second-value", forKey: key)
        let value = try readOrSkip(key)
        XCTAssertEqual(value, "second-value")
    }

    /// Confirms deleting a saved key makes the next read report no value.
    func testDeleteThenGetIsNil() throws {
        try setOrSkip("to-be-deleted", forKey: key)
        try deleteOrSkip(key)
        // Evaluate before XCTAssertNil's autoclosure so XCTSkip propagates.
        let value = try readOrSkip(key)
        XCTAssertNil(value)
    }

    /// Confirms deleting a key that does not exist is safely treated as success.
    func testDeleteOfMissingKeyDoesNotThrow() throws {
        try deleteOrSkip("missing.key")
    }

    /// Confirms reading a never-saved key returns nil instead of an error.
    func testReadOfMissingItemIsNil() throws {
        // Evaluate before XCTAssertNil's autoclosure so XCTSkip propagates.
        let value = try readOrSkip("missing.read.key")
        XCTAssertNil(value)
    }

    /// Confirms only Apple's item-not-found status maps to nil; other failures remain visible.
    func testReadDecoderReturnsNilOnlyForItemNotFound() throws {
        XCTAssertNil(try KeychainStore.decodeReadResult(
            status: errSecItemNotFound,
            data: nil
        ))

        XCTAssertThrowsError(try KeychainStore.decodeReadResult(
            status: errSecInteractionNotAllowed,
            data: nil
        )) { error in
            XCTAssertEqual(
                error as? KeychainError,
                .unhandledStatus(errSecInteractionNotAllowed)
            )
        }
    }

    /// Confirms a successful status still rejects absent or non-text Keychain data.
    func testReadDecoderRejectsMissingAndInvalidUTF8Data() {
        XCTAssertThrowsError(try KeychainStore.decodeReadResult(
            status: errSecSuccess,
            data: nil
        )) { error in
            XCTAssertEqual(error as? KeychainError, .invalidResult)
        }

        XCTAssertThrowsError(try KeychainStore.decodeReadResult(
            status: errSecSuccess,
            data: Data([0xFF, 0xFE])
        )) { error in
            XCTAssertEqual(error as? KeychainError, .invalidUTF8)
        }
    }

    /// Confirms valid UTF-8 Keychain bytes decode to the original secret text.
    func testReadDecoderAcceptsUTF8() throws {
        XCTAssertEqual(
            try KeychainStore.decodeReadResult(
                status: errSecSuccess,
                data: Data("secret".utf8)
            ),
            "secret"
        )
    }

    // MARK: - Helpers

    /// Calls `store.set`, converting an `errSecMissingEntitlement` failure
    /// (seen when the test host isn't granted Keychain access) into a test
    /// skip instead of a hard failure.
    private func setOrSkip(_ value: String, forKey key: String) throws {
        do {
            try store.set(value, forKey: key)
        } catch KeychainError.unhandledStatus(let status) where status == errSecMissingEntitlement {
            throw XCTSkip("Keychain unavailable in test host (errSecMissingEntitlement)")
        }
    }

    /// Deletes a test key, skipping only when the host cannot access Keychain at all.
    private func deleteOrSkip(_ key: String) throws {
        do {
            try store.delete(key)
        } catch KeychainError.unhandledStatus(let status) where status == errSecMissingEntitlement {
            throw XCTSkip("Keychain unavailable in test host (errSecMissingEntitlement)")
        }
    }

    /// Reads a test key, skipping only when the host cannot access Keychain at all.
    private func readOrSkip(_ key: String) throws -> String? {
        do {
            return try store.read(key)
        } catch KeychainError.unhandledStatus(let status)
            where status == errSecMissingEntitlement {
            throw XCTSkip("Keychain unavailable in test host (errSecMissingEntitlement)")
        }
    }
}
