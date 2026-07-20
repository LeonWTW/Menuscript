import XCTest
@testable import Menuscript

final class KeychainStoreTests: XCTestCase {
    private var store: KeychainStore!
    private let key = "test.key"

    override func setUp() {
        super.setUp()
        // Unique service namespace per test run so tests never collide with
        // each other or with any real stored data.
        let service = "com.leonwong.menuscript.tests.\(UUID().uuidString)"
        store = KeychainStore(service: service)
    }

    override func tearDown() {
        try? store.delete(key)
        store = nil
        super.tearDown()
    }

    func testSetGetRoundTrip() throws {
        try setOrSkip("hello-world", forKey: key)
        let value = try readOrSkip(key)
        XCTAssertEqual(value, "hello-world")
    }

    func testOverwriteUpdatesValue() throws {
        try setOrSkip("first-value", forKey: key)
        try setOrSkip("second-value", forKey: key)
        let value = try readOrSkip(key)
        XCTAssertEqual(value, "second-value")
    }

    func testDeleteThenGetIsNil() throws {
        try setOrSkip("to-be-deleted", forKey: key)
        try deleteOrSkip(key)
        // Evaluate before XCTAssertNil's autoclosure so XCTSkip propagates.
        let value = try readOrSkip(key)
        XCTAssertNil(value)
    }

    func testDeleteOfMissingKeyDoesNotThrow() throws {
        try deleteOrSkip("missing.key")
    }

    func testReadOfMissingItemIsNil() throws {
        // Evaluate before XCTAssertNil's autoclosure so XCTSkip propagates.
        let value = try readOrSkip("missing.read.key")
        XCTAssertNil(value)
    }

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

    private func deleteOrSkip(_ key: String) throws {
        do {
            try store.delete(key)
        } catch KeychainError.unhandledStatus(let status) where status == errSecMissingEntitlement {
            throw XCTSkip("Keychain unavailable in test host (errSecMissingEntitlement)")
        }
    }

    private func readOrSkip(_ key: String) throws -> String? {
        do {
            return try store.read(key)
        } catch KeychainError.unhandledStatus(let status)
            where status == errSecMissingEntitlement {
            throw XCTSkip("Keychain unavailable in test host (errSecMissingEntitlement)")
        }
    }
}
