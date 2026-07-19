import Foundation
import Testing
@testable import Menuscript

private enum StubSecretError: Error, Equatable {
    case unavailable
}

private final class StubSecretStore: @unchecked Sendable, SecretStore {
    var value: String?
    var readError: Error?
    private(set) var readCount = 0

    init(value: String? = nil, readError: Error? = nil) {
        self.value = value
        self.readError = readError
    }

    func read(_ key: String) throws -> String? {
        readCount += 1
        if let readError { throw readError }
        return value
    }

    func set(_ value: String, forKey key: String) throws {
        self.value = value
    }

    func delete(_ key: String) throws {
        value = nil
    }
}

private struct StubFXProvider: FXRateProviding {
    func rate(from: String, to: String) async -> FXRate? { nil }
}

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("Runtime service resolution", .serialized)
struct RuntimeServiceResolverTests {
    @Test("Mock mode resolves vision and FX together without touching secure or live dependencies")
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
