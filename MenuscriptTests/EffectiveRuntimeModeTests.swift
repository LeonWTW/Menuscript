import Foundation
import Testing
@testable import Menuscript

private enum EffectiveModeSecretError: Error {
    case unavailable
}

private final class EffectiveModeSecretStore: @unchecked Sendable, SecretStore {
    private(set) var readCount = 0

    func read(_ key: String) throws -> String? {
        readCount += 1
        throw EffectiveModeSecretError.unavailable
    }

    func set(_ value: String, forKey key: String) throws {}
    func delete(_ key: String) throws {}
}

private struct EffectiveModeLiveFXProvider: FXRateProviding {
    func rate(from: String, to: String) async -> FXRate? { nil }
}

private final class EffectiveModeInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.withLock { storedCount }
    }

    func increment() {
        lock.withLock { storedCount += 1 }
    }
}

@MainActor
@Suite("Effective runtime mode", .serialized)
struct EffectiveRuntimeModeTests {
    @Test("Persisted mode wins; legacy mode follows preferences without mutation")
    func sixCaseMatrix() throws {
        let cases: [(
            persistedMode: RuntimeMode?,
            useMockPreference: Bool,
            expected: RuntimeMode
        )] = [
            (.mock, true, .mock),
            (.mock, false, .mock),
            (.live, true, .live),
            (.live, false, .live),
            (nil, true, .mock),
            (nil, false, .live),
        ]

        for testCase in cases {
            let suite = "test.runtime.effective-mode.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(
                testCase.useMockPreference,
                forKey: SettingsKeys.useMockProvider
            )
            let before = defaults.dictionaryRepresentation() as NSDictionary
            let persistedMode = testCase.persistedMode

            let result = RuntimeServiceResolver.effectiveMode(
                persistedMode: persistedMode,
                defaults: defaults
            )
            let disclosureResult = GeminiDisclosureGate.effectiveMode(
                explicitMode: persistedMode,
                defaults: defaults
            )

            #expect(result == testCase.expected)
            #expect(disclosureResult == result)
            #expect(persistedMode == testCase.persistedMode)
            #expect(defaults.dictionaryRepresentation() as NSDictionary == before)
        }
    }

    @Test("Legacy mock fallback resolves fully offline")
    func legacyMockFallbackIsFullyOffline() throws {
        let suite = "test.runtime.legacy-mock.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SettingsKeys.useMockProvider)
        let secrets = EffectiveModeSecretStore()
        let liveFactoryCalls = EffectiveModeInvocationCounter()

        let mode = RuntimeServiceResolver.effectiveMode(
            persistedMode: nil,
            defaults: defaults
        )
        let candidate = try RuntimeServiceResolver.resolve(
            configuration: RuntimeServiceConfiguration(mode: mode),
            secretStore: secrets,
            liveFXFactory: {
                liveFactoryCalls.increment()
                return EffectiveModeLiveFXProvider()
            }
        )
        let resolved = try #require(candidate)

        #expect(resolved.mode == .mock)
        #expect(resolved.visionProvider is MockVisionProvider)
        #expect(resolved.fxRateProvider is MockFXService)
        #expect(secrets.readCount == 0)
        #expect(liveFactoryCalls.count == 0)
    }
}
