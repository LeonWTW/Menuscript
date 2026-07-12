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
        XCTAssertEqual(store.get(key), "hello-world")
    }

    func testOverwriteUpdatesValue() throws {
        try setOrSkip("first-value", forKey: key)
        try setOrSkip("second-value", forKey: key)
        XCTAssertEqual(store.get(key), "second-value")
    }

    func testDeleteThenGetIsNil() throws {
        try setOrSkip("to-be-deleted", forKey: key)
        try deleteOrSkip(key)
        XCTAssertNil(store.get(key))
    }

    func testDeleteOfMissingKeyDoesNotThrow() throws {
        try deleteOrSkip("missing.key")
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
}
