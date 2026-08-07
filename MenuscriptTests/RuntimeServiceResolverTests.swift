// Verifies one resolver selects a matching vision and currency service for live or Demo Mode.
// Injected stores and factories prove offline mode never accesses secrets or networking dependencies.

import Foundation
import Testing
@testable import Menuscript

/// A predictable error used when a test needs secure storage to be unavailable.
private enum StubSecretError: Error, Equatable {
    case unavailable
}

/// An in-memory SecretStore that records reads and can return a value or injected failure.
private final class StubSecretStore: @unchecked Sendable, SecretStore {
    var value: String?
    var readError: Error?
    private(set) var readCount = 0

    /// Configures the stored value and optional read failure for one resolution scenario.
    init(value: String? = nil, readError: Error? = nil) {
        self.value = value
        self.readError = readError
    }

    /// Counts each read, then returns the value or throws the injected error.
    func read(_ key: String) throws -> String? {
        readCount += 1
        if let readError { throw readError }
        return value
    }

    /// Stores a replacement value for completeness of the SecretStore contract.
    func set(_ value: String, forKey key: String) throws {
        self.value = value
    }

    /// Removes the stored value for completeness of the SecretStore contract.
    func delete(_ key: String) throws {
        value = nil
    }
}

/// A recognizable FX provider returned by the live-service factory in tests.
private struct StubFXProvider: FXRateProviding {
    /// Returns no quote because resolver tests inspect wiring rather than exchange data.
    func rate(from: String, to: String) async -> FXRate? { nil }
}

/// A lock-protected counter used to prove a dependency factory was or was not invoked.
private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Records one invocation safely across concurrent code.
    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    /// Reads the invocation count while holding the same lock used for writes.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("Runtime service resolution", .serialized)
/// Protects service selection, API-key handling, and Demo Mode's fully offline guarantee.
struct RuntimeServiceResolverTests {
    @Test("Mock mode resolves vision and FX together without touching secure or live dependencies")
    /// Confirms Demo Mode returns both mock services without reading Keychain or building live FX.
    func mockModeIsFullyOffline() async throws {
        let secrets = StubSecretStore(readError: StubSecretError.unavailable)
        let liveFactoryCalls = InvocationCounter()

        let candidate = try RuntimeServiceResolver.resolve(
            configuration: RuntimeServiceConfiguration(mode: .mock),
            secretStore: secrets,
            liveFXFactory: {
                liveFactoryCalls.increment()
                return StubFXProvider()
            }
        )
        let resolved = try #require(candidate)

        #expect(resolved.mode == .mock)
        #expect(resolved.visionProvider is MockVisionProvider)
        #expect(resolved.fxRateProvider is MockFXService)
        #expect(secrets.readCount == 0)
        #expect(liveFactoryCalls.count == 0)

        let quote = try #require(
            await resolved.fxRateProvider.rate(from: "JPY", to: "TWD")
        )
        #expect(quote.source == .mock)
    }

    @Test("Live mode propagates SecretStore failures")
    /// Confirms live startup reports a Keychain failure instead of silently changing runtime mode.
    func liveModePropagatesSecretFailure() {
        let secrets = StubSecretStore(readError: StubSecretError.unavailable)
        #expect(throws: StubSecretError.unavailable) {
            _ = try RuntimeServiceResolver.resolve(
                configuration: RuntimeServiceConfiguration(mode: .live),
                secretStore: secrets
            )
        }
        #expect(secrets.readCount == 1)
    }

    @Test("Missing or whitespace-only live key resolves nil")
    /// Confirms live services remain unavailable until a meaningful API key exists.
    func missingLiveKey() throws {
        for value in [nil, "   \n"] as [String?] {
            let secrets = StubSecretStore(value: value)
            #expect(try RuntimeServiceResolver.resolve(
                configuration: RuntimeServiceConfiguration(mode: .live),
                secretStore: secrets
            ) == nil)
        }
    }

    @Test("Live mode trims the key and lazily creates live FX")
    /// Confirms live wiring trims configuration text, creates FX once, and keeps the key out of the URL.
    func liveModeTrimsKey() throws {
        let secrets = StubSecretStore(value: "  secret-key\n")
        let factoryCalls = InvocationCounter()
        let candidate = try RuntimeServiceResolver.resolve(
            configuration: RuntimeServiceConfiguration(
                mode: .live,
                geminiModel: "  gemini-2.5-pro  "
            ),
            secretStore: secrets,
            liveFXFactory: {
                factoryCalls.increment()
                return StubFXProvider()
            }
        )
        let resolved = try #require(candidate)

        #expect(resolved.mode == .live)
        #expect(resolved.fxRateProvider is StubFXProvider)
        #expect(factoryCalls.count == 1)

        let provider = try #require(resolved.visionProvider as? GeminiProvider)
        let request = try provider.buildExtractRequest(
            images: [Data([0xFF])],
            targetLanguage: "English"
        )
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "secret-key")
        #expect(request.url?.absoluteString.contains("gemini-2.5-pro") == true)
        #expect(request.url?.absoluteString.contains("secret-key") == false)
    }

    @Test("Preferences adapter chooses mock before reading model or Keychain")
    /// Confirms the Demo Mode preference short-circuits all live preference and secret work.
    func preferencesMockPrecedence() throws {
        let suite = "test.runtime.preferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SettingsKeys.useMockProvider)

        let secrets = StubSecretStore(readError: StubSecretError.unavailable)
        let candidate = try RuntimeServiceResolver.resolveFromPreferences(
            secretStore: secrets,
            defaults: defaults
        )
        let resolved = try #require(candidate)
        #expect(resolved.mode == .mock)
        #expect(secrets.readCount == 0)
    }
}
