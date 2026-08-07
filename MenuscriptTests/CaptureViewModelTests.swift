// Verifies the complete capture contract: photo preparation and ordering,
// recognition safety, cancellation, provider selection, and all-or-nothing saving.

import Foundation
import Testing
import SwiftData
import UIKit
@testable import Menuscript

/// A `MenuVisionProvider` that always fails, used to exercise the error path
/// without any network dependency.
private struct FailingVisionProvider: MenuVisionProvider {
    /// Simulates a rate-limit failure during recognition without using a network.
    func extractMenu(images: [Data], targetLanguage: String, allergens: [String]) async throws -> ExtractedMenu {
        throw VisionProviderError.rateLimited
    }

    /// Keeps the test double protocol-complete with the same predictable failure.
    func explainDish(original: String, language: String, targetLanguage: String) async throws -> String {
        throw VisionProviderError.rateLimited
    }
}

/// A `MenuVisionProvider` whose `extractMenu` sleeps long enough for a test
/// to cancel it mid-flight, used to exercise cooperative cancellation.
private struct SlowVisionProvider: MenuVisionProvider {
    /// Delays a valid result so a test can cancel recognition while it is running.
    func extractMenu(images: [Data], targetLanguage: String, allergens: [String]) async throws -> ExtractedMenu {
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return ExtractedMenu(
            detectedLanguage: "日文",
            menuCurrency: "JPY",
            restaurantName: nil,
            items: [ExtractedMenu.Item(original: "test", translated: "test", price: Decimal(100), priceNote: nil, category: "測試", lowConfidence: false)]
        )
    }

    /// Supplies the unrelated protocol requirement with a fixed offline result.
    func explainDish(original: String, language: String, targetLanguage: String) async throws -> String {
        "explanation"
    }
}

/// A `MenuVisionProvider` returning a fixed two-item menu whose items carry
/// `summary` and `possibleAllergens`, used to verify those per-dish fields
/// persist onto `MenuItem` and that the session snapshots the allergen profile.
private struct AllergenVisionProvider: MenuVisionProvider {
    /// Returns known allergen and summary fields so their persistence can be checked exactly.
    func extractMenu(images: [Data], targetLanguage: String, allergens: [String]) async throws -> ExtractedMenu {
        ExtractedMenu(
            detectedLanguage: "日文",
            menuCurrency: "JPY",
            restaurantName: "測試",
            items: [
                ExtractedMenu.Item(original: "唐揚げ", translated: "日式炸雞", price: Decimal(650), priceNote: nil, category: "燒烤", lowConfidence: false, summary: "外脆內嫩嘅炸雞", possibleAllergens: ["wheat", "soy"]),
                ExtractedMenu.Item(original: "焼きなす", translated: "烤茄子", price: Decimal(500), priceNote: nil, category: "燒烤", lowConfidence: false, summary: "炭烤茄子", possibleAllergens: [])
            ]
        )
    }

    /// Supplies the unrelated protocol requirement with a fixed offline result.
    func explainDish(original: String, language: String, targetLanguage: String) async throws -> String {
        "explanation"
    }
}

/// Actor-backed spy used to prove that capture validation stops a bad batch
/// before the provider is called.
private actor CountingVisionProvider: MenuVisionProvider {
    private(set) var extractCallCount = 0
    private(set) var extractedImageBatches: [[Data]] = []

    /// Records every submitted image batch before returning one known dish.
    /// Actor isolation makes these observations safe across asynchronous tasks.
    func extractMenu(images: [Data], targetLanguage: String, allergens: [String]) async throws -> ExtractedMenu {
        extractCallCount += 1
        extractedImageBatches.append(images)
        return ExtractedMenu(
            detectedLanguage: "日文",
            menuCurrency: "JPY",
            restaurantName: "測試",
            items: [
                ExtractedMenu.Item(
                    original: "唐揚げ",
                    translated: "日式炸雞",
                    price: 650,
                    priceNote: nil,
                    category: "燒烤",
                    lowConfidence: false
                )
            ]
        )
    }

    /// Supplies the unrelated protocol requirement with a fixed offline result.
    func explainDish(original: String, language: String, targetLanguage: String) async throws -> String {
        "explanation"
    }
}

/// Deliberately ignores task cancellation until the test releases its
/// continuation. This exercises the guard after the provider await instead of
/// relying on a provider that throws `CancellationError` cooperatively.
private actor NonCooperativeVisionProvider: MenuVisionProvider {
    private var continuation: CheckedContinuation<ExtractedMenu, Never>?

    /// Reports when recognition has reached the deliberately suspended provider call.
    var isWaiting: Bool {
        continuation != nil
    }

    /// Suspends until the test releases a result and intentionally ignores cancellation.
    func extractMenu(images: [Data], targetLanguage: String, allergens: [String]) async throws -> ExtractedMenu {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// Supplies the unrelated protocol requirement with a fixed offline result.
    func explainDish(original: String, language: String, targetLanguage: String) async throws -> String {
        "explanation"
    }

    /// Releases the suspended request with a valid late result, allowing the test
    /// to prove cancelled data is still rejected before persistence.
    func completeRequest() {
        continuation?.resume(returning: ExtractedMenu(
            detectedLanguage: "日文",
            menuCurrency: "JPY",
            restaurantName: "取消後結果",
            items: [
                ExtractedMenu.Item(
                    original: "唐揚げ",
                    translated: "日式炸雞",
                    price: 650,
                    priceNote: nil,
                    category: "燒烤",
                    lowConfidence: false
                )
            ]
        ))
        continuation = nil
    }
}

/// Error injected on the first save attempt to exercise cleanup and retry behavior.
private enum InjectedSaveError: Error {
    case firstAttempt
}

/// Secret store that behaves like a device with no configured API key.
private struct MissingSecretStore: SecretStore {
    /// Always reports that no secret is stored.
    func read(_ key: String) throws -> String? { nil }
    /// Accepts the protocol call without storing data because tests never need it.
    func set(_ value: String, forKey key: String) throws {}
    /// Accepts the protocol call because the store is already empty.
    func delete(_ key: String) throws {}
}

/// Thread-safe spy for the direct camera/DEBUG preparation path. The
/// preprocessor itself stays synchronous, so the test can observe whether it
/// ran in the background without adding another asynchronous layer.
private final class ThreadRecordingPhotoPreparer: @unchecked Sendable {
    private let lock = NSLock()
    private var mainThreadValues: [Bool] = []

    /// Records the executing thread and returns a tiny valid prepared photo.
    func prepare(_ image: UIImage) -> ImagePrep.PreparedPhoto? {
        lock.withLock {
            mainThreadValues.append(Thread.isMainThread)
        }
        return ImagePrep.PreparedPhoto(preview: image, jpegData: Data([0xA1]))
    }

    /// Confirms that preparation ran at least once and never blocked the main thread.
    var ranOnlyOffMain: Bool {
        lock.withLock {
            !mainThreadValues.isEmpty && mainThreadValues.allSatisfy { !$0 }
        }
    }
}

/// Lock-protected counter used by concurrently running closures to verify service
/// calls without introducing a data race into the test itself.
private final class CaptureInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    /// Returns the current value while holding the lock.
    var count: Int { lock.withLock { storedCount } }

    /// Adds one call in a thread-safe way.
    func increment() {
        lock.withLock { storedCount += 1 }
    }

    /// Adds one and returns the new value, which lets a test fail one exact invocation.
    func nextCount() -> Int {
        lock.withLock {
            storedCount += 1
            return storedCount
        }
    }
}

/// Blocks two direct preparations independently so a test can complete them
/// in the opposite order from their camera/DEBUG add calls.
private final class ControlledDirectPhotoPreparer: @unchecked Sendable {
    private let lock = NSLock()
    private let firstImage: UIImage
    private var startedIndices: Set<Int> = []
    private let releaseGates = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]

    /// Remembers the first image so each input can use an independent release gate.
    init(firstImage: UIImage) {
        self.firstImage = firstImage
    }

    /// Blocks the chosen image until the test releases it, then returns unique bytes.
    func prepare(_ image: UIImage) -> ImagePrep.PreparedPhoto? {
        let index = image === firstImage ? 0 : 1
        _ = lock.withLock {
            startedIndices.insert(index)
        }
        releaseGates[index].wait()
        return ImagePrep.PreparedPhoto(
            preview: image,
            jpegData: Data([index == 0 ? 0xA1 : 0xB2])
        )
    }

    /// Confirms both background preparations reached their gates before release.
    func hasStartedBothPreparations() -> Bool {
        lock.withLock { startedIndices == [0, 1] }
    }

    /// Allows one selected preparation to finish, enabling reverse-order completion tests.
    func release(_ index: Int) {
        releaseGates[index].signal()
    }
}

/// Actor-backed FX spy that returns one known live quote and safely counts calls.
private actor ExplicitFXProvider: FXRateProviding {
    private var callCount = 0

    /// Records the request and returns a fixed quote whose source can be asserted.
    func rate(from: String, to: String) async -> FXRate? {
        callCount += 1
        return FXRate(
            rate: 0.25,
            quoteDate: "2026-07-15",
            fetchedAt: Date(timeIntervalSince1970: 1_752_537_600),
            source: .live
        )
    }

    /// Safely exposes the provider's call count to tests.
    func calls() -> Int { callCount }
}

/// Exercises capture behavior on the main actor, matching the production view model.
@MainActor
@Suite("CaptureViewModel")
struct CaptureViewModelTests {
    /// Creates isolated in-memory persistence so no test touches user data.
    private func makeContext() throws -> ModelContext {
        let schema = Schema([MenuSession.self, MenuItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    /// Creates a tiny valid image that keeps preparation tests fast and deterministic.
    private func makeDemoImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 4, height: 4)))
        }
    }

    /// Cooperatively waits for asynchronous state without relying on fixed timing.
    private func waitUntil(
        maxIterations: Int = 10_000,
        _ condition: () async -> Bool
    ) async -> Bool {
        for _ in 0..<maxIterations {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return false
    }

    /// Every test gets private Settings. Injected vision providers use offline
    /// FX by default, so USD tests conversion without contacting a live service.
    private func makeDefaults(homeCurrency: String = "USD") throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "CaptureViewModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(AppLanguage.zhHant.rawValue, forKey: SettingsKeys.appLanguage)
        defaults.set(homeCurrency, forKey: SettingsKeys.homeCurrency)
        return (defaults, suiteName)
    }

    /// Protects the rule that adding a camera photo immediately reserves its place
    /// while expensive JPEG work happens away from the user-interface thread.
    @Test("Direct additions reserve a pending slot immediately and prepare off the main thread")
    func directAdditionsPrepareOffMain() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preparer = ThreadRecordingPhotoPreparer()
        let viewModel = CaptureViewModel(
            modelContext: try makeContext(),
            provider: MockVisionProvider(),
            defaults: defaults,
            photoPreparer: preparer.prepare
        )

        let result = viewModel.addPhotos([makeDemoImage()])

        #expect(result == PhotoAddResult(accepted: 1, rejected: 0))
        #expect(viewModel.pendingPhotoCount == 1)
        #expect(viewModel.canRecognize == false)
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })
        #expect(viewModel.canRecognize)
        #expect(preparer.ranOnlyOffMain)
    }

    /// Protects the user's selected order when two preparations finish in reverse.
    @Test("Direct additions retain call order when JPEG preparation completes in reverse")
    func directAdditionsKeepStableOrderAcrossOverlappingPreparations() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstImage = makeDemoImage()
        let secondImage = makeDemoImage()
        let preparer = ControlledDirectPhotoPreparer(firstImage: firstImage)
        let viewModel = CaptureViewModel(
            modelContext: try makeContext(),
            provider: MockVisionProvider(),
            defaults: defaults,
            photoPreparer: preparer.prepare
        )

        _ = viewModel.addPhotos([firstImage])
        _ = viewModel.addPhotos([secondImage])
        let reservedIDs = viewModel.photos.map(\.id)
        #expect(viewModel.pendingPhotoCount == 2)
        #expect(await waitUntil { preparer.hasStartedBothPreparations() })

        preparer.release(1)
        #expect(await waitUntil { viewModel.pendingPhotoCount == 1 })
        #expect(viewModel.photos.map(\.id) == reservedIDs)
        #expect(viewModel.photos[0].isPending)
        #expect(viewModel.photos[1].jpegData == Data([0xB2]))

        preparer.release(0)
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })
        #expect(viewModel.photos.map(\.id) == reservedIDs)
        #expect(viewModel.photos[0].jpegData == Data([0xA1]))
        #expect(viewModel.photos[1].jpegData == Data([0xB2]))
    }

    /// Protects test isolation: an injected vision provider must not silently
    /// construct live FX services, while its recognition mode remains accurate.
    @Test("Injected non-mock providers use mock FX unless the test explicitly injects one")
    func injectedProviderDefaultsToMockFXWithoutChangingLiveProvenance() async throws {
        let (defaults, suiteName) = try makeDefaults(homeCurrency: "USD")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = CountingVisionProvider()
        let liveFactoryProvider = ExplicitFXProvider()
        let liveFactoryCalls = CaptureInvocationCounter()
        let viewModel = CaptureViewModel(
            modelContext: try makeContext(),
            provider: provider,
            liveFXFactory: {
                liveFactoryCalls.increment()
                return liveFactoryProvider
            },
            defaults: defaults
        )
        viewModel.addPhotos([makeDemoImage()])
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })

        await viewModel.recognize()

        let session = try #require(viewModel.completedSession)
        #expect(liveFactoryCalls.count == 0)
        #expect(session.providerMode == .live)
        #expect(session.fxSource == "mock")
        #expect(session.fxRate == 0.00625)
        #expect(session.fxQuoteDate == "2026-01-15")
    }

    /// Confirms an explicitly supplied FX provider takes priority over the safe test fallback.
    @Test("An explicitly injected FX provider overrides the hermetic default")
    func explicitFXProviderOverridesHermeticFallback() async throws {
        let (defaults, suiteName) = try makeDefaults(homeCurrency: "USD")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = CountingVisionProvider()
        let fxProvider = ExplicitFXProvider()
        let liveFactoryCalls = CaptureInvocationCounter()
        let viewModel = CaptureViewModel(
            modelContext: try makeContext(),
            provider: provider,
            fxProvider: fxProvider,
            liveFXFactory: {
                liveFactoryCalls.increment()
                return MockFXService()
            },
            defaults: defaults
        )
        viewModel.addPhotos([makeDemoImage()])
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })

        await viewModel.recognize()

        let session = try #require(viewModel.completedSession)
        #expect(await fxProvider.calls() == 1)
        #expect(liveFactoryCalls.count == 0)
        #expect(session.providerMode == .live)
        #expect(session.fxSource == "live")
        #expect(session.fxRate == 0.25)
    }

    /// Protects the normal success path from prepared photo through one saved,
    /// correctly ordered session, followed by release of staged image memory.
    @Test("Successful recognition persists a session with 10 ordered items")
    func successfulRecognitionPersistsSession() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = try makeContext()
        let viewModel = CaptureViewModel(
            modelContext: context,
            provider: MockVisionProvider(),
            defaults: defaults
        )
        viewModel.addPhotos([makeDemoImage()])
        #expect(viewModel.photos.count == 1)
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })

        await viewModel.recognize()

        #expect(viewModel.isRecognizing == false)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.needsAPIKey == false)
        // Photos are cleared once the session is safely persisted, so the
        // full-resolution UIImages don't linger in memory while the user
        // browses MenuView/BillView afterwards.
        #expect(viewModel.photos.isEmpty)

        let session = try #require(viewModel.completedSession)
        #expect(session.items.count == 10)
        #expect(session.title == "鷹の目")
        #expect(session.targetLanguage == "繁體中文")
        #expect(session.homeCurrency == "USD")
        #expect(session.items.allSatisfy { $0.quantity == 0 })

        let sortOrders = session.items.map(\.sortOrder).sorted()
        #expect(sortOrders == Array(0..<10))

        let fetchedSessions = try context.fetch(FetchDescriptor<MenuSession>())
        #expect(fetchedSessions.count == 1)
    }

    /// Protects retry behavior by showing a useful provider error without losing photos.
    @Test("Failing provider surfaces the localized error and preserves photos")
    func failingProviderSurfacesError() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = try makeContext()
        let viewModel = CaptureViewModel(
            modelContext: context,
            provider: FailingVisionProvider(),
            defaults: defaults
        )
        viewModel.addPhotos([makeDemoImage()])
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })

        await viewModel.recognize()

        #expect(viewModel.errorMessage == VisionProviderError.rateLimited.errorDescription)
        #expect(viewModel.photos.count == 1)
        #expect(viewModel.completedSession == nil)
        #expect(viewModel.isRecognizing == false)
    }

    /// Protects all-or-nothing saving: a failed first attempt leaves no partial records,
    /// and retry reuses the same photo to create exactly one session and item.
    @Test("A failed save removes the inserted graph; retry sends the same photo and persists exactly once")
    func persistenceFailureCleansGraphAndRetryPersistsExactlyOnce() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = try makeContext()
        let provider = CountingVisionProvider()
        let stagedJPEG = Data([0xCA, 0xFE, 0x01])
        var saveAttemptCount = 0
        var sessionCountsAtSave: [Int] = []
        var itemCountsAtSave: [Int] = []
        let viewModel = CaptureViewModel(
            modelContext: context,
            provider: provider,
            defaults: defaults,
            photoPreparer: { image in
                ImagePrep.PreparedPhoto(preview: image, jpegData: stagedJPEG)
            },
            saveContext: { context in
                saveAttemptCount += 1
                sessionCountsAtSave.append(try context.fetch(FetchDescriptor<MenuSession>()).count)
                itemCountsAtSave.append(try context.fetch(FetchDescriptor<MenuItem>()).count)
                if saveAttemptCount == 1 {
                    throw InjectedSaveError.firstAttempt
                }
                try context.save()
            }
        )
        viewModel.addPhotos([makeDemoImage()])
        let stagedPhotoID = try #require(viewModel.photos.first?.id)
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })

        await viewModel.recognize()

        #expect(saveAttemptCount == 1)
        #expect(sessionCountsAtSave == [1])
        #expect(itemCountsAtSave == [1])
        #expect(viewModel.completedSession == nil)
        #expect(viewModel.errorMessage == L10n.string("未能儲存菜單，請再試一次。", defaults: defaults))
        #expect(viewModel.recoveryAction == .retry)
        #expect(viewModel.photos.count == 1)
        #expect(viewModel.photos.first?.id == stagedPhotoID)
        #expect(viewModel.photos.first?.jpegData == stagedJPEG)
        #expect(try context.fetch(FetchDescriptor<MenuSession>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<MenuItem>()).isEmpty)
        #expect(context.insertedModelsArray.compactMap { $0 as? MenuSession }.isEmpty)
        #expect(context.insertedModelsArray.compactMap { $0 as? MenuItem }.isEmpty)
        #expect(context.changedModelsArray.compactMap { $0 as? MenuSession }.isEmpty)
        #expect(context.changedModelsArray.compactMap { $0 as? MenuItem }.isEmpty)
        #expect(context.deletedModelsArray.compactMap { $0 as? MenuSession }.isEmpty)
        #expect(context.deletedModelsArray.compactMap { $0 as? MenuItem }.isEmpty)
        #expect(await provider.extractCallCount == 1)
        #expect(await provider.extractedImageBatches == [[stagedJPEG]])

        await viewModel.recognize()

        #expect(saveAttemptCount == 2)
        #expect(sessionCountsAtSave == [1, 1])
        #expect(itemCountsAtSave == [1, 1])
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.recoveryAction == nil)
        #expect(viewModel.photos.isEmpty)
        let completedSession = try #require(viewModel.completedSession)
        #expect(completedSession.title == "測試")
        #expect(completedSession.items.count == 1)
        let persistedSessions = try context.fetch(FetchDescriptor<MenuSession>())
        let persistedItems = try context.fetch(FetchDescriptor<MenuItem>())
        #expect(persistedSessions.count == 1)
        #expect(persistedItems.count == 1)
        #expect(persistedSessions.first?.id == completedSession.id)
        #expect(await provider.extractCallCount == 2)
        #expect(await provider.extractedImageBatches == [[stagedJPEG], [stagedJPEG]])
    }

    /// Protects unrelated unsaved user edits when capture cleans up only the
    /// session and items created by its own failed save.
    @Test("Failed recognition persistence does not roll back unrelated pending edits")
    func persistenceFailurePreservesUnrelatedPendingEdits() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = try makeContext()
        let existingItem = MenuItem(
            originalName: "既有菜式",
            translatedName: "Existing dish",
            priceValue: 100,
            category: "測試",
            quantity: 0,
            sortOrder: 0
        )
        let existingSession = MenuSession(
            title: "已儲存",
            detectedLanguage: "中文",
            targetLanguage: "English",
            menuCurrency: "JPY",
            homeCurrency: "JPY",
            items: [existingItem]
        )
        context.insert(existingSession)
        try context.save()
        existingSession.title = "未儲存嘅標題修改"
        existingItem.quantity = 3

        let viewModel = CaptureViewModel(
            modelContext: context,
            provider: CountingVisionProvider(),
            defaults: defaults,
            photoPreparer: { image in
                ImagePrep.PreparedPhoto(preview: image, jpegData: Data([0x01]))
            },
            saveContext: { _ in throw InjectedSaveError.firstAttempt }
        )
        viewModel.addPhotos([makeDemoImage()])
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })

        await viewModel.recognize()

        #expect(existingSession.title == "未儲存嘅標題修改")
        #expect(existingItem.quantity == 3)
        let sessions = try context.fetch(FetchDescriptor<MenuSession>())
        let items = try context.fetch(FetchDescriptor<MenuItem>())
        #expect(sessions.count == 1)
        #expect(items.count == 1)
        #expect(sessions.first?.id == existingSession.id)
        #expect(items.first?.originalName == "既有菜式")
        #expect(context.insertedModelsArray.compactMap { $0 as? MenuSession }.isEmpty)
        #expect(context.insertedModelsArray.compactMap { $0 as? MenuItem }.isEmpty)
        #expect(context.changedModelsArray.compactMap { $0 as? MenuSession }.allSatisfy { $0.id == existingSession.id })
        #expect(context.changedModelsArray.compactMap { $0 as? MenuItem }.allSatisfy { $0.originalName == "既有菜式" })
    }

    /// Protects cooperative cancellation from saving a result or showing an error,
    /// while retaining the photo because recognition never completed.
    @Test("Cancelling recognize before it finishes discards the result: no session is persisted, no error is shown")
    func cancellingRecognizeDiscardsInFlightResult() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = try makeContext()
        let viewModel = CaptureViewModel(
            modelContext: context,
            provider: SlowVisionProvider(),
            defaults: defaults
        )
        viewModel.addPhotos([makeDemoImage()])
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })

        let task = Task { await viewModel.recognize() }
        try await Task.sleep(nanoseconds: 50_000_000) // let it enter the provider's sleep
        task.cancel()
        await task.value

        #expect(viewModel.isRecognizing == false)
        #expect(viewModel.completedSession == nil)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.photos.count == 1) // preserved: nothing was persisted to clear them for

        let fetchedSessions = try context.fetch(FetchDescriptor<MenuSession>())
        #expect(fetchedSessions.isEmpty)
    }

    /// Protects the post-await cancellation guard even when a provider ignores cancellation.
    @Test("A cancelled non-cooperative provider result never reaches persistence")
    func cancelledNonCooperativeResultIsDiscarded() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = try makeContext()
        let provider = NonCooperativeVisionProvider()
        let stagedJPEG = Data([0xAA, 0xBB])
        var saveAttemptCount = 0
        let viewModel = CaptureViewModel(
            modelContext: context,
            provider: provider,
            defaults: defaults,
            photoPreparer: { image in
                ImagePrep.PreparedPhoto(preview: image, jpegData: stagedJPEG)
            },
            saveContext: { context in
                saveAttemptCount += 1
                try context.save()
            }
        )
        viewModel.addPhotos([makeDemoImage()])
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })

        viewModel.startRecognize()
        let requestStarted = await waitUntil { await provider.isWaiting }
        guard requestStarted else {
            viewModel.cancelRecognize()
            Issue.record("Provider request did not start")
            return
        }
        viewModel.cancelRecognize()
        await provider.completeRequest()
        let recognitionFinished = await waitUntil { !viewModel.isRecognizing }

        #expect(recognitionFinished)
        #expect(saveAttemptCount == 0)
        #expect(viewModel.completedSession == nil)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.photos.count == 1)
        #expect(viewModel.photos.first?.jpegData == stagedJPEG)
        #expect(try context.fetch(FetchDescriptor<MenuSession>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<MenuItem>()).isEmpty)
        #expect(context.insertedModelsArray.isEmpty)
    }

    /// Protects photos added after recognition begins: only the captured input
    /// snapshot is cleared when its session saves successfully.
    @Test("Photo appended after recognition starts survives; the recognized snapshot is removed")
    func photoAppendedDuringRecognitionSurvives() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = try makeContext()
        let viewModel = CaptureViewModel(
            modelContext: context,
            provider: SlowVisionProvider(),
            defaults: defaults
        )
        let recognizedPhoto = makeDemoImage()
        viewModel.addPhotos([recognizedPhoto])
        let recognizedID = try #require(viewModel.photos.first?.id)
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })

        let task = Task { await viewModel.recognize() }
        try await Task.sleep(nanoseconds: 50_000_000) // let it enter the provider's sleep, past the snapshot point
        let latePhoto = makeDemoImage()
        viewModel.addPhotos([latePhoto])
        let lateID = try #require(viewModel.photos.last?.id)
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })
        await task.value

        #expect(viewModel.isRecognizing == false)
        #expect(viewModel.completedSession != nil)
        #expect(viewModel.photos.count == 1)
        #expect(viewModel.photos.first?.id == lateID)
        #expect(viewModel.photos.first?.id != recognizedID)
    }

    /// Confirms live recognition with no stored key asks the user to update Settings.
    @Test("Missing API key with mock disabled sets needsAPIKey")
    func missingAPIKeySetsNeedsAPIKey() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: SettingsKeys.useMockProvider)
        let context = try makeContext()
        let viewModel = CaptureViewModel(
            modelContext: context,
            secretStore: MissingSecretStore(),
            defaults: defaults
        )
        viewModel.addPhotos([makeDemoImage()])
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })

        await viewModel.recognize()

        #expect(viewModel.needsAPIKey == true)
        #expect(viewModel.completedSession == nil)
        #expect(viewModel.isRecognizing == false)
    }

    /// Protects recognized dish summaries/allergens and the exact allergen profile
    /// used for that session so later Settings changes cannot rewrite history.
    @Test("Recognition persists per-dish summary and possibleAllergens, and snapshots the session allergen profile")
    func recognitionPersistsAllergenFieldsAndProfile() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("wheat,soy", forKey: SettingsKeys.allergenPresets)
        defaults.set("香菜", forKey: SettingsKeys.allergenCustom)

        let context = try makeContext()
        let viewModel = CaptureViewModel(
            modelContext: context,
            provider: AllergenVisionProvider(),
            defaults: defaults
        )
        viewModel.addPhotos([makeDemoImage()])
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })

        await viewModel.recognize()

        let session = try #require(viewModel.completedSession)
        #expect(session.allergenProfile == ["wheat", "soy", "香菜"])

        let orderedItems = session.items.sorted { $0.sortOrder < $1.sortOrder }
        #expect(orderedItems.count == 2)
        #expect(orderedItems[0].summary == "外脆內嫩嘅炸雞")
        #expect(orderedItems[0].possibleAllergens == ["wheat", "soy"])
        #expect(orderedItems[1].summary == "炭烤茄子")
        #expect(orderedItems[1].possibleAllergens == [])
    }

    /// Protects the shared six-photo limit and reports every image that could not be added.
    @Test("Global six-photo cap includes direct additions and reports every rejection")
    func globalPhotoCapRejectsOverflow() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = try makeContext()
        let viewModel = CaptureViewModel(modelContext: context, provider: MockVisionProvider(), defaults: defaults)

        let result = viewModel.addPhotos(Array(repeating: makeDemoImage(), count: 8))

        #expect(result == PhotoAddResult(accepted: 6, rejected: 2))
        #expect(viewModel.photos.count == CaptureLimits.maxPhotoCount)
        #expect(viewModel.remainingPhotoCapacity == 0)
        #expect(viewModel.captureIssue == .photoLimitExceeded(maximum: 6, rejected: 2))
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })
    }

    /// Confirms still-loading reservations consume capacity immediately, preventing overflow.
    @Test("Pending reservations count toward the global cap")
    func pendingReservationsCountTowardCap() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = try makeContext()
        let viewModel = CaptureViewModel(modelContext: context, provider: MockVisionProvider(), defaults: defaults)

        let reservation = viewModel.reservePhotoSlots(count: 4)
        let addition = viewModel.addPhotos(Array(repeating: makeDemoImage(), count: 4))

        #expect(reservation.ids.count == 4)
        #expect(addition == PhotoAddResult(accepted: 2, rejected: 2))
        #expect(viewModel.photos.count == 6)
        #expect(viewModel.pendingPhotoCount == 6)
        #expect(viewModel.canRecognize == false)
        #expect(await waitUntil { viewModel.pendingPhotoCount == 4 })
    }

    /// Protects the add-photo gate across loading, recognition, and full-capacity states.
    @Test("Adding controls pause for pending work, recognition, and full capacity")
    func addMorePhotosGateTracksCaptureState() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = try makeContext()
        let viewModel = CaptureViewModel(modelContext: context, provider: MockVisionProvider(), defaults: defaults)

        #expect(viewModel.canAddMorePhotos)

        let reservation = viewModel.reservePhotoSlots(count: 1)
        let id = try #require(reservation.ids.first)
        #expect(!viewModel.canAddMorePhotos)

        let prepared = try #require(ImagePrep.preparedPhoto(from: makeDemoImage()))
        viewModel.resolvePhotoSlot(id: id, with: .success(prepared))
        #expect(viewModel.canAddMorePhotos)

        viewModel.isRecognizing = true
        #expect(!viewModel.canAddMorePhotos)
        viewModel.isRecognizing = false

        viewModel.addPhotos(Array(repeating: makeDemoImage(), count: 5))
        #expect(viewModel.remainingPhotoCapacity == 0)
        #expect(!viewModel.canAddMorePhotos)
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })
    }

    /// Protects all-or-nothing submission: one failed JPEG blocks the complete
    /// batch before any photos reach the vision provider.
    @Test("One JPEG preparation failure blocks the whole batch and retains every staged photo")
    func partialJPEGFailureIsAtomic() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = try makeContext()
        let provider = CountingVisionProvider()
        let preparationCounter = CaptureInvocationCounter()
        let viewModel = CaptureViewModel(
            modelContext: context,
            provider: provider,
            defaults: defaults,
            photoPreparer: { image in
                preparationCounter.nextCount() == 2
                    ? nil
                    : ImagePrep.preparedPhoto(from: image)
            }
        )
        viewModel.addPhotos([makeDemoImage(), makeDemoImage()])
        #expect(await waitUntil { viewModel.pendingPhotoCount == 0 })

        await viewModel.recognize()

        let extractCallCount = await provider.extractCallCount
        #expect(extractCallCount == 0)
        #expect(viewModel.photos.count == 2)
        #expect(viewModel.failedPhotoCount == 1)
        #expect(viewModel.completedSession == nil)
        #expect(viewModel.captureIssue == .photoPreparationFailed(count: 1))
    }

    /// Protects the provider from oversized requests and retains photos so the
    /// user can remove some and retry.
    @Test("Oversized encoded payload is stopped before the provider and photos are retained")
    func oversizedPayloadStopsBeforeProvider() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = try makeContext()
        let provider = CountingVisionProvider()
        let viewModel = CaptureViewModel(modelContext: context, provider: provider, defaults: defaults)
        let reservation = viewModel.reservePhotoSlots(count: 1)
        let id = try #require(reservation.ids.first)
        let oversizedData = Data(repeating: 0xAB, count: 13_500_000)
        viewModel.resolvePhotoSlot(
            id: id,
            with: .success(ImagePrep.PreparedPhoto(preview: makeDemoImage(), jpegData: oversizedData))
        )

        await viewModel.recognize()

        let extractCallCount = await provider.extractCallCount
        #expect(extractCallCount == 0)
        #expect(viewModel.photos.count == 1)
        #expect(viewModel.completedSession == nil)
        guard case .requestTooLarge(let estimated, let limit) = viewModel.captureIssue else {
            Issue.record("Expected requestTooLarge capture issue")
            return
        }
        #expect(estimated > limit)
        #expect(limit == 18_000_000)
    }
}

/// Verifies the exact request-size boundary independently of image preparation.
@Suite("Capture request budget")
struct CaptureRequestBudgetTests {
    /// Protects the inclusive 18 MB contract and rejects the first byte beyond it.
    @Test("18,000,000-byte boundary is inclusive and one byte over is rejected")
    func exactByteBoundary() {
        #expect(CaptureLimits.isWithinRequestBudget(estimatedBytes: 18_000_000))
        #expect(!CaptureLimits.isWithinRequestBudget(estimatedBytes: 18_000_001))
    }
}
