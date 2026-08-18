// Verifies how Settings and saved provider history choose mock or live services,
// including consent, secrets, FX metadata, caching, and recovery behavior.

import Foundation
import SwiftData
import Testing
import UIKit
@testable import Menuscript

/// Simulated secure-storage failure used to distinguish a broken store from a missing key.
private enum WiringSecretFailure: Error {
    case unavailable
}

/// Lock-protected in-memory secret store that can return a key or fail on read.
/// The lock makes observations reliable when runtime services access it concurrently.
private final class WiringSecretStore: @unchecked Sendable, SecretStore {
    private let lock = NSLock()
    private var storedValue: String?
    private var shouldFailRead: Bool
    private var storedReadCount = 0

    /// Creates the store with an optional key and an optional forced read failure.
    init(value: String? = nil, shouldFailRead: Bool = false) {
        storedValue = value
        self.shouldFailRead = shouldFailRead
    }

    /// Reports how often code attempted to access a secret, proving offline paths do not.
    var readCount: Int {
        lock.withLock { storedReadCount }
    }

    /// Records the access, then returns the test key or the configured storage failure.
    func read(_ key: String) throws -> String? {
        try lock.withLock {
            storedReadCount += 1
            if shouldFailRead {
                throw WiringSecretFailure.unavailable
            }
            return storedValue
        }
    }

    /// Replaces the in-memory key while holding the lock.
    func set(_ value: String, forKey key: String) throws {
        lock.withLock { storedValue = value }
    }

    /// Removes the in-memory key while holding the lock.
    func delete(_ key: String) throws {
        lock.withLock { storedValue = nil }
    }
}

/// Thread-safe counter for proving that lazy live-service factories were not called.
private final class WiringInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    /// Returns the current count under the lock.
    var count: Int { lock.withLock { storedCount } }

    /// Records one invocation without introducing a race into the test.
    func increment() {
        lock.withLock { storedCount += 1 }
    }
}

/// Actor-backed vision spy that returns fixed offline content and safely counts
/// extraction and explanation calls from asynchronous production code.
private actor WiringVisionProvider: MenuVisionProvider {
    private var extractCallCount = 0
    private var explainCallCount = 0

    /// Records one recognition request and returns a small known menu.
    func extractMenu(
        images: [Data],
        targetLanguage: String,
        allergens: [String]
    ) async throws -> ExtractedMenu {
        extractCallCount += 1
        return ExtractedMenu(
            detectedLanguage: "Japanese",
            menuCurrency: "JPY",
            restaurantName: "Wiring fixture",
            items: [
                ExtractedMenu.Item(
                    original: "唐揚げ",
                    translated: "Japanese fried chicken",
                    price: 650,
                    priceNote: nil,
                    category: "Mains",
                    lowConfidence: false
                )
            ]
        )
    }

    /// Records one explanation request and returns known text.
    func explainDish(
        original: String,
        language: String,
        targetLanguage: String
    ) async throws -> String {
        explainCallCount += 1
        return "Explanation"
    }

    /// Exposes the number of menu-recognition calls.
    func extractCalls() -> Int { extractCallCount }
    /// Exposes the number of dish-explanation calls.
    func explainCalls() -> Int { explainCallCount }
}

/// Actor-backed FX spy that returns a configurable quote and counts requests safely.
private actor WiringFXProvider: FXRateProviding {
    private var callCount = 0
    private let result: FXRate?

    /// Creates the provider with a realistic fixed live quote unless a test supplies another result.
    init(result: FXRate? = FXRate(
        rate: 0.0065,
        quoteDate: "2026-07-15",
        fetchedAt: Date(timeIntervalSince1970: 1_752_537_600),
        source: .live
    )) {
        self.result = result
    }

    /// Records one currency request and returns the configured quote.
    func rate(from: String, to: String) async -> FXRate? {
        callCount += 1
        return result
    }

    /// Exposes the number of FX requests to tests.
    func calls() -> Int { callCount }
}

/// Vision provider that always reports an invalid API key so recovery mapping is deterministic.
private struct InvalidKeyVisionProvider: MenuVisionProvider {
    /// Simulates invalid credentials during menu recognition.
    func extractMenu(
        images: [Data],
        targetLanguage: String,
        allergens: [String]
    ) async throws -> ExtractedMenu {
        throw VisionProviderError.invalidAPIKey
    }

    /// Simulates the same invalid credentials during dish explanation.
    func explainDish(
        original: String,
        language: String,
        targetLanguage: String
    ) async throws -> String {
        throw VisionProviderError.invalidAPIKey
    }
}

/// Serial main-actor suite for runtime choices that temporarily change shared
/// preferences or timezone state and therefore must not overlap.
@MainActor
@Suite("Runtime wiring", .serialized)
struct RuntimeWiringTests {
    /// Creates a model context backed only by memory, keeping tests away from user data.
    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(
            schema: AppSchema.current,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: AppSchema.current,
            configurations: [configuration]
        )
        return ModelContext(container)
    }

    /// Creates an isolated Settings domain with the runtime choices needed by one test.
    private func makeDefaults(
        useMock: Bool,
        targetLanguage: String = "English",
        homeCurrency: String = "USD"
    ) throws -> (UserDefaults, String) {
        let suiteName = "RuntimeWiringTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(useMock, forKey: SettingsKeys.useMockProvider)
        defaults.set(targetLanguage, forKey: SettingsKeys.targetLanguage)
        defaults.set(homeCurrency, forKey: SettingsKeys.homeCurrency)
        return (defaults, suiteName)
    }

    /// Creates a tiny valid photo so capture wiring can be tested without fixtures.
    private func makeDemoImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 4, height: 4)))
        }
    }

    /// Cooperatively waits for asynchronous state without assuming device speed.
    private func waitUntil(
        maxIterations: Int = 10_000,
        _ condition: () async -> Bool
    ) async -> Bool {
        for _ in 0..<maxIterations {
            if await condition() { return true }
            await Task.yield()
        }
        return false
    }

    /// Protects the promise that demo capture is fully offline and records mock
    /// the mock provider mode plus stable quote details in the saved session.
    @Test("Production mock capture is offline and persists mock provenance")
    func productionMockCaptureIsFullyOffline() async throws {
        let (defaults, suiteName) = try makeDefaults(useMock: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secrets = WiringSecretStore(shouldFailRead: true)
        let liveFactoryCalls = WiringInvocationCounter()
        let viewModel = CaptureViewModel(
            modelContext: try makeContext(),
            secretStore: secrets,
            liveFXFactory: {
                liveFactoryCalls.increment()
                return WiringFXProvider()
            },
            defaults: defaults
        )
        viewModel.addPhotos([makeDemoImage()])
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })

        await viewModel.recognize()

        let session = try #require(viewModel.completedSession)
        #expect(secrets.readCount == 0)
        #expect(liveFactoryCalls.count == 0)
        #expect(viewModel.needsLiveDisclosure == false)
        #expect(session.providerMode == .mock)
        #expect(session.fxSource == "mock")
        #expect(session.fxQuoteDate == MockFXService.fixedQuoteDate)
        #expect(session.fxFetchedAt == FXQuoteDate.date(from: MockFXService.fixedQuoteDate))
    }

    /// Protects privacy: live capture calls no provider before consent, remembers
    /// acceptance afterward, and does not ask again for later captures.
    @Test("Live capture sends nothing until disclosure is accepted, then remembers consent")
    func liveDisclosureGatesProviderCallsOnce() async throws {
        let (defaults, suiteName) = try makeDefaults(useMock: false)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let vision = WiringVisionProvider()
        let fx = WiringFXProvider()
        let viewModel = CaptureViewModel(
            modelContext: try makeContext(),
            runtimeResolver: {
                RuntimeServices(
                    mode: .live,
                    visionProvider: vision,
                    fxRateProvider: fx
                )
            },
            defaults: defaults
        )
        viewModel.addPhotos([makeDemoImage()])
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })

        await viewModel.recognize()
        #expect(viewModel.needsLiveDisclosure)
        #expect(await vision.extractCalls() == 0)
        #expect(await fx.calls() == 0)

        viewModel.cancelLiveDisclosure()
        #expect(await vision.extractCalls() == 0)
        #expect(await fx.calls() == 0)

        await viewModel.recognize()
        #expect(viewModel.needsLiveDisclosure)
        viewModel.acceptLiveDisclosure()
        await viewModel.recognize()
        #expect(await vision.extractCalls() == 1)
        #expect(await fx.calls() == 1)
        #expect(viewModel.completedSession?.providerMode == .live)

        viewModel.addPhotos([makeDemoImage()])
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })
        await viewModel.recognize()
        #expect(viewModel.needsLiveDisclosure == false)
        #expect(await vision.extractCalls() == 2)
        #expect(await fx.calls() == 2)
    }

    /// Protects distinct recovery guidance for an invalid key versus an unavailable
    /// secure store, so users are not incorrectly told to replace credentials.
    @Test("Capture maps invalid keys and secure-store failures to distinct recovery")
    func captureRecoveryActionsRemainTyped() async throws {
        let (injectedDefaults, injectedSuite) = try makeDefaults(
            useMock: false,
            homeCurrency: "JPY"
        )
        defer { injectedDefaults.removePersistentDomain(forName: injectedSuite) }
        let invalidKeyViewModel = CaptureViewModel(
            modelContext: try makeContext(),
            provider: InvalidKeyVisionProvider(),
            providerMode: .live,
            defaults: injectedDefaults
        )
        invalidKeyViewModel.addPhotos([makeDemoImage()])
        #expect(await waitUntil { invalidKeyViewModel.pendingPhotoCount == 0 })

        await invalidKeyViewModel.recognize()

        #expect(invalidKeyViewModel.needsAPIKey)
        #expect(invalidKeyViewModel.recoveryAction == .openSettings)

        let (liveDefaults, liveSuite) = try makeDefaults(useMock: false)
        defer { liveDefaults.removePersistentDomain(forName: liveSuite) }
        liveDefaults.set(AppLanguage.zhHant.rawValue, forKey: SettingsKeys.appLanguage)
        let unavailableStore = WiringSecretStore(shouldFailRead: true)
        let unavailableViewModel = CaptureViewModel(
            modelContext: try makeContext(),
            secretStore: unavailableStore,
            defaults: liveDefaults
        )
        unavailableViewModel.addPhotos([makeDemoImage()])
        #expect(await waitUntil { unavailableViewModel.pendingPhotoCount == 0 })

        await unavailableViewModel.recognize()

        #expect(unavailableViewModel.needsAPIKey == false)
        #expect(unavailableViewModel.recoveryAction == .retry)
        #expect(unavailableViewModel.errorMessage == "安全儲存空間暫時無法使用，請稍後再試。")
    }

    /// Protects the promise that mock dish explanations do not read secrets or
    /// create live FX services, including legacy sessions with no saved mode.
    @Test("Mock dish explanation never resolves a secret or live FX dependency")
    func mockExplanationIsFullyOffline() async throws {
        let (defaults, suiteName) = try makeDefaults(useMock: false)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secrets = WiringSecretStore(shouldFailRead: true)
        let liveFactoryCalls = WiringInvocationCounter()

        let result = try await DishExplanationService.fetch(
            original: "唐揚げ",
            detectedLanguage: "Japanese",
            targetLanguage: "English",
            providerMode: .mock,
            secretStore: secrets,
            defaults: defaults,
            liveFXFactory: {
                liveFactoryCalls.increment()
                return WiringFXProvider()
            }
        )

        #expect(result.contains("popular izakaya dish"))
        #expect(secrets.readCount == 0)
        #expect(liveFactoryCalls.count == 0)

        // A legacy session has no stored provider mode, so current mock
        // preferences must still choose the same fully offline path.
        defaults.set(true, forKey: SettingsKeys.useMockProvider)
        let legacyResult = try await DishExplanationService.fetch(
            original: "唐揚げ",
            detectedLanguage: "Japanese",
            targetLanguage: "English",
            providerMode: nil,
            secretStore: secrets,
            defaults: defaults,
            liveFXFactory: {
                liveFactoryCalls.increment()
                return WiringFXProvider()
            }
        )
        #expect(legacyResult.contains("popular izakaya dish"))
        #expect(secrets.readCount == 0)
        #expect(liveFactoryCalls.count == 0)
    }

    /// Confirms the explicit demo preference safely overrides saved live history
    /// for explanation and bill FX without constructing live dependencies.
    @Test("Demo mode overrides persisted live provenance for explanation and bill FX")
    func demoToggleOverridesPersistedLiveDependencies() async throws {
        let (defaults, suiteName) = try makeDefaults(useMock: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secrets = WiringSecretStore(shouldFailRead: true)
        let liveFactoryCalls = WiringInvocationCounter()

        #expect(!GeminiDisclosureGate.requiresConsent(
            explicitMode: .live,
            defaults: defaults
        ))
        let explanation = try await DishExplanationService.fetch(
            original: "唐揚げ",
            detectedLanguage: "Japanese",
            targetLanguage: "English",
            providerMode: .live,
            secretStore: secrets,
            defaults: defaults,
            liveFXFactory: {
                liveFactoryCalls.increment()
                return WiringFXProvider()
            }
        )

        #expect(explanation.contains("popular izakaya dish"))
        #expect(secrets.readCount == 0)
        #expect(liveFactoryCalls.count == 0)

        let session = MenuSession(
            detectedLanguage: "Japanese",
            targetLanguage: "English",
            menuCurrency: "JPY",
            homeCurrency: "USD",
            providerModeRaw: RuntimeMode.live.rawValue
        )
        let selection = MenuView.billFXSelection(
            for: session,
            defaults: defaults,
            liveFXFactory: {
                liveFactoryCalls.increment()
                return WiringFXProvider()
            }
        )

        #expect(selection.mode == .mock)
        #expect(selection.provider is MockFXService)
        #expect(liveFactoryCalls.count == 0)
    }

    /// Protects saved sessions from explanations generated under a different
    /// provider mode while allowing compatible and older results to be cached.
    @Test("Explanation cache persists only when runtime and session provenance are compatible")
    func explanationCachePolicyProtectsPersistedProvenance() {
        let cases: [(
            persistedMode: RuntimeMode?,
            effectiveMode: RuntimeMode,
            shouldPersist: Bool
        )] = [
            (.live, .live, true),
            (.live, .mock, false),
            (.mock, .mock, true),
            (.mock, .live, false),
            (nil, .mock, true),
            (nil, .live, true),
        ]

        for testCase in cases {
            #expect(DishExplanationCachePolicy.shouldPersist(
                persistedMode: testCase.persistedMode,
                effectiveMode: testCase.effectiveMode
            ) == testCase.shouldPersist)
        }
    }

    /// Protects live explanation consent for explicit and legacy modes and proves
    /// exactly one provider call occurs only after acceptance.
    @Test("Explicit and legacy live explanations require consent before one provider call")
    func liveExplanationDisclosureGatesProviderCalls() async throws {
        #expect(GeminiDisclosureGate.acceptedKey == CaptureViewModel.liveDisclosureAcceptedKey)

        let cases: [(providerMode: RuntimeMode?, useMockPreference: Bool)] = [
            (.live, false),
            (nil, false),
        ]
        for testCase in cases {
            let (defaults, suiteName) = try makeDefaults(
                useMock: testCase.useMockPreference
            )
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let secrets = WiringSecretStore(value: "unused-test-key")
            let liveFactoryCalls = WiringInvocationCounter()
            let resolverCalls = WiringInvocationCounter()
            let vision = WiringVisionProvider()
            let fx = WiringFXProvider()

            do {
                _ = try await DishExplanationService.fetch(
                    original: "唐揚げ",
                    detectedLanguage: "Japanese",
                    targetLanguage: "English",
                    providerMode: testCase.providerMode,
                    secretStore: secrets,
                    defaults: defaults,
                    liveFXFactory: {
                        liveFactoryCalls.increment()
                        return WiringFXProvider()
                    },
                    runtimeResolver: { mode in
                        resolverCalls.increment()
                        return RuntimeServices(
                            mode: mode,
                            visionProvider: vision,
                            fxRateProvider: fx
                        )
                    }
                )
                Issue.record("Expected live disclosure to be required")
            } catch let error as GeminiDisclosureError {
                #expect(error == .consentRequired)
            }

            // Cancelling means taking no acceptance action: no services have
            // been created and no provider has received a request.
            #expect(defaults.bool(forKey: GeminiDisclosureGate.acceptedKey) == false)
            #expect(resolverCalls.count == 0)
            #expect(await vision.explainCalls() == 0)
            #expect(secrets.readCount == 0)
            #expect(liveFactoryCalls.count == 0)

            GeminiDisclosureGate.accept(defaults: defaults)
            let result = try await DishExplanationService.fetch(
                original: "唐揚げ",
                detectedLanguage: "Japanese",
                targetLanguage: "English",
                providerMode: testCase.providerMode,
                secretStore: secrets,
                defaults: defaults,
                liveFXFactory: {
                    liveFactoryCalls.increment()
                    return WiringFXProvider()
                },
                runtimeResolver: { mode in
                    resolverCalls.increment()
                    return RuntimeServices(
                        mode: mode,
                        visionProvider: vision,
                        fxRateProvider: fx
                    )
                }
            )

            #expect(defaults.bool(forKey: GeminiDisclosureGate.acceptedKey))
            #expect(result == "Explanation")
            #expect(resolverCalls.count == 1)
            #expect(await vision.explainCalls() == 1)
            #expect(await fx.calls() == 0)
            #expect(secrets.readCount == 0)
            #expect(liveFactoryCalls.count == 0)
        }
    }

    /// Protects the cache fast path: existing text returns before consent checks,
    /// secret access, provider resolution, or network-capable services.
    @Test("Cached explanation bypasses disclosure and every runtime dependency")
    func cachedExplanationIsNoCall() async throws {
        let (defaults, suiteName) = try makeDefaults(useMock: false)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let secrets = WiringSecretStore(shouldFailRead: true)
        let liveFactoryCalls = WiringInvocationCounter()
        let resolverCalls = WiringInvocationCounter()
        let vision = WiringVisionProvider()

        let result = try await DishExplanationService.fetchIfNeeded(
            currentExplanation: "Cached explanation",
            forceRefresh: false,
            original: "唐揚げ",
            detectedLanguage: "Japanese",
            targetLanguage: "English",
            providerMode: .live,
            secretStore: secrets,
            defaults: defaults,
            liveFXFactory: {
                liveFactoryCalls.increment()
                return WiringFXProvider()
            },
            runtimeResolver: { mode in
                resolverCalls.increment()
                return RuntimeServices(
                    mode: mode,
                    visionProvider: vision,
                    fxRateProvider: WiringFXProvider()
                )
            }
        )

        #expect(result == "Cached explanation")
        #expect(defaults.bool(forKey: GeminiDisclosureGate.acceptedKey) == false)
        #expect(resolverCalls.count == 0)
        #expect(await vision.explainCalls() == 0)
        #expect(secrets.readCount == 0)
        #expect(liveFactoryCalls.count == 0)
    }

    /// Protects offline bill FX selection and standard quote-date storage for
    /// both mock sessions and legacy sessions without provider history.
    @Test("Menu and bill keep mock FX offline and persist canonical quote metadata")
    func menuBillMockSelectionIsOffline() async throws {
        let (defaults, suiteName) = try makeDefaults(useMock: false)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let liveFactoryCalls = WiringInvocationCounter()
        let context = try makeContext()
        let session = MenuSession(
            detectedLanguage: "Japanese",
            targetLanguage: "English",
            menuCurrency: "JPY",
            homeCurrency: "USD",
            providerModeRaw: RuntimeMode.mock.rawValue
        )
        context.insert(session)
        try context.save()

        let selection = MenuView.billFXSelection(
            for: session,
            defaults: defaults,
            liveFXFactory: {
                liveFactoryCalls.increment()
                return WiringFXProvider()
            }
        )
        let fresh = await BillFXRefresh.fetch(
            for: session,
            provider: selection.provider
        )

        #expect(liveFactoryCalls.count == 0)
        #expect(selection.mode == .mock)
        #expect(selection.provider is MockFXService)
        #expect(fresh != nil)
        #expect(session.fxRate == nil)
        try SessionStore(context: context).updateFXRate(try #require(fresh), for: session)
        #expect(session.fxSource == "mock")
        #expect(session.fxQuoteDate == MockFXService.fixedQuoteDate)
        #expect(session.providerMode == .mock)

        // Older sessions keep their unknown provider mode. The current demo
        // preference selects offline FX without creating a live service, and
        // refreshing FX must not invent recognition history.
        defaults.set(true, forKey: SettingsKeys.useMockProvider)
        let legacy = MenuSession(
            detectedLanguage: "Japanese",
            targetLanguage: "English",
            menuCurrency: "JPY",
            homeCurrency: "USD",
            providerModeRaw: nil
        )
        context.insert(legacy)
        try context.save()
        let legacySelection = MenuView.billFXSelection(
            for: legacy,
            defaults: defaults,
            liveFXFactory: {
                liveFactoryCalls.increment()
                return WiringFXProvider()
            }
        )
        #expect(legacySelection.mode == .mock)
        #expect(legacySelection.provider is MockFXService)
        #expect(liveFactoryCalls.count == 0)
        let legacyRate = try #require(
            await BillFXRefresh.fetch(for: legacy, provider: legacySelection.provider)
        )
        try SessionStore(context: context).updateFXRate(legacyRate, for: legacy)
        #expect(legacy.providerModeRaw == nil)
    }

    /// Protects completed bills from rate changes and keeps quote dates stable
    /// across timezones, legacy dates, and same-currency sessions.
    @Test("Completed bills never call FX and quote dates do not shift with timezone")
    func completedBillAndQuoteDatesAreStable() async throws {
        let provider = WiringFXProvider()
        let canonical = MenuSession(
            detectedLanguage: "Japanese",
            targetLanguage: "English",
            menuCurrency: "JPY",
            homeCurrency: "USD",
            fxRateDate: Date(timeIntervalSince1970: 0),
            fxQuoteDate: "2026-07-15",
            lifecycleStatusRaw: "completed"
        )

        let fresh = await BillFXRefresh.fetch(
            for: canonical,
            provider: provider
        )
        #expect(fresh == nil)
        #expect(await provider.calls() == 0)

        let originalTimeZone = NSTimeZone.default
        defer { NSTimeZone.default = originalTimeZone }
        for identifier in ["America/Los_Angeles", "Pacific/Honolulu", "Asia/Tokyo"] {
            NSTimeZone.default = try #require(TimeZone(identifier: identifier))
            #expect(BillFXPresentation.quoteDate(
                quoteDate: canonical.fxQuoteDate,
                legacyDate: canonical.fxRateDate
            ) == "2026-07-15")
        }

        canonical.fxQuoteDate = nil
        canonical.fxRateDate = FXQuoteDate.date(from: "2026-07-14")
        #expect(BillFXPresentation.quoteDate(
            quoteDate: nil,
            legacyDate: canonical.fxRateDate
        ) == "2026-07-14")

        let sameCurrency = MenuSession(
            detectedLanguage: "English",
            targetLanguage: "中文",
            menuCurrency: " usd ",
            homeCurrency: "USD"
        )
        #expect(await BillFXRefresh.fetch(for: sameCurrency, provider: provider) == nil)
        #expect(await provider.calls() == 0)
    }
}
