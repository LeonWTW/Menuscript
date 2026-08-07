// Verifies how the saved provider mode and Demo Mode preference choose the services used at runtime.
// The cases also prove that an offline choice never reads secrets or constructs live dependencies.

import Foundation
import Testing
@testable import Menuscript

/// A controlled secure-storage failure used to detect any forbidden Keychain access in Demo Mode.
private enum EffectiveModeSecretError: Error {
    case unavailable
}

/// Counts and rejects secret reads so offline resolution can prove it never touches the Keychain.
private final class EffectiveModeSecretStore: @unchecked Sendable, SecretStore {
    private(set) var readCount = 0

    /// Records an attempted read and fails immediately because no live secret should be needed.
    func read(_ key: String) throws -> String? {
        readCount += 1
        throw EffectiveModeSecretError.unavailable
    }

    /// Satisfies the SecretStore contract; effective-mode tests never write secrets.
    func set(_ value: String, forKey key: String) throws {}
    /// Satisfies the SecretStore contract; effective-mode tests never delete secrets.
    func delete(_ key: String) throws {}
}

/// A recognizable live FX replacement used only to detect whether its factory was called.
private struct EffectiveModeLiveFXProvider: FXRateProviding {
    /// Returns no quote because these tests care only about service selection.
    func rate(from: String, to: String) async -> FXRate? { nil }
}

/// A lock-protected counter that can safely observe factory calls across concurrency boundaries.
private final class EffectiveModeInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    /// Returns the current call count while holding the lock.
    var count: Int {
        lock.withLock { storedCount }
    }

    /// Adds one factory invocation while holding the lock.
    func increment() {
        lock.withLock { storedCount += 1 }
    }
}

@MainActor
@Suite("Effective runtime mode", .serialized)
/// Protects the precedence matrix that determines the app's effective live or mock mode.
struct EffectiveRuntimeModeTests {
    @Test("Demo toggle wins; otherwise persisted mode preserves provenance without mutation")
    /// Confirms Demo Mode overrides a saved live mode while ordinary resolution never changes stored state.
    func sixCaseMatrix() throws {
        let cases: [(
            persistedMode: RuntimeMode?,
            useMockPreference: Bool,
            expected: RuntimeMode
        )] = [
            (.mock, true, .mock),
            (.mock, false, .mock),
            (.live, true, .mock),
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
    /// Confirms an older session with no saved provider mode remains fully offline when Demo Mode is on.
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
