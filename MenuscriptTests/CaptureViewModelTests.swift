import Foundation
import Testing
import SwiftData
import UIKit
@testable import Menuscript

/// A `MenuVisionProvider` that always fails, used to exercise the error path
/// without any network dependency.
private struct FailingVisionProvider: MenuVisionProvider {
    func extractMenu(images: [Data], targetLanguage: String, allergens: [String]) async throws -> ExtractedMenu {
        throw VisionProviderError.rateLimited
    }

    func explainDish(original: String, language: String, targetLanguage: String) async throws -> String {
        throw VisionProviderError.rateLimited
    }
}

/// A `MenuVisionProvider` whose `extractMenu` sleeps long enough for a test
/// to cancel it mid-flight, used to exercise cooperative cancellation.
private struct SlowVisionProvider: MenuVisionProvider {
    func extractMenu(images: [Data], targetLanguage: String, allergens: [String]) async throws -> ExtractedMenu {
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return ExtractedMenu(
            detectedLanguage: "日文",
            menuCurrency: "JPY",
            restaurantName: nil,
            items: [ExtractedMenu.Item(original: "test", translated: "test", price: Decimal(100), priceNote: nil, category: "測試", lowConfidence: false)]
        )
    }

    func explainDish(original: String, language: String, targetLanguage: String) async throws -> String {
        "explanation"
    }
}

/// A `MenuVisionProvider` returning a fixed two-item menu whose items carry
/// `summary` and `possibleAllergens`, used to verify those per-dish fields
/// persist onto `MenuItem` and that the session snapshots the allergen profile.
private struct AllergenVisionProvider: MenuVisionProvider {
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

    func explainDish(original: String, language: String, targetLanguage: String) async throws -> String {
        "explanation"
    }
}

/// Actor-backed spy used to prove that capture-side validation stops a bad
/// batch before the provider boundary.
private actor CountingVisionProvider: MenuVisionProvider {
    private(set) var extractCallCount = 0
    private(set) var extractedImageBatches: [[Data]] = []

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

    func explainDish(original: String, language: String, targetLanguage: String) async throws -> String {
        "explanation"
    }
}

/// Deliberately ignores task cancellation until the test releases its
/// continuation. This exercises the guard after the provider await instead of
/// relying on a provider that throws `CancellationError` cooperatively.
private actor NonCooperativeVisionProvider: MenuVisionProvider {
    private var continuation: CheckedContinuation<ExtractedMenu, Never>?

    var isWaiting: Bool {
        continuation != nil
    }

    func extractMenu(images: [Data], targetLanguage: String, allergens: [String]) async throws -> ExtractedMenu {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func explainDish(original: String, language: String, targetLanguage: String) async throws -> String {
        "explanation"
    }

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

private enum InjectedSaveError: Error {
    case firstAttempt
}

private struct MissingSecretStore: SecretStore {
    func read(_ key: String) throws -> String? { nil }
    func set(_ value: String, forKey key: String) throws {}
    func delete(_ key: String) throws {}
}

@MainActor
@Suite("CaptureViewModel")
struct CaptureViewModelTests {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([MenuSession.self, MenuItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    private func makeDemoImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        return renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 4, height: 4)))
        }
    }

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

    /// Every test gets its own defaults domain. Home currency defaults to JPY
    /// so the capture path never reaches a live FX service.
    private func makeDefaults(homeCurrency: String = "JPY") throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "CaptureViewModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(AppLanguage.zhHant.rawValue, forKey: SettingsKeys.appLanguage)
        defaults.set(homeCurrency, forKey: SettingsKeys.homeCurrency)
        return (defaults, suiteName)
    }

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
        #expect(session.homeCurrency == "JPY")
        #expect(session.items.allSatisfy { $0.quantity == 0 })

        let sortOrders = session.items.map(\.sortOrder).sorted()
        #expect(sortOrders == Array(0..<10))

        let fetchedSessions = try context.fetch(FetchDescriptor<MenuSession>())
        #expect(fetchedSessions.count == 1)
    }

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

        await viewModel.recognize()

        #expect(viewModel.errorMessage == VisionProviderError.rateLimited.errorDescription)
        #expect(viewModel.photos.count == 1)
        #expect(viewModel.completedSession == nil)
        #expect(viewModel.isRecognizing == false)
    }

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

        await viewModel.recognize()

        #expect(saveAttemptCount == 1)
        #expect(sessionCountsAtSave == [1])
        #expect(itemCountsAtSave == [1])
        #expect(viewModel.completedSession == nil)
        #expect(viewModel.errorMessage == L10n.string("未能儲存菜單，請再試一次。"))
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

        let task = Task { await viewModel.recognize() }
        try await Task.sleep(nanoseconds: 50_000_000) // let it enter the provider's sleep, past the snapshot point
        let latePhoto = makeDemoImage()
        viewModel.addPhotos([latePhoto])
        let lateID = try #require(viewModel.photos.last?.id)
        await task.value

        #expect(viewModel.isRecognizing == false)
        #expect(viewModel.completedSession != nil)
        #expect(viewModel.photos.count == 1)
        #expect(viewModel.photos.first?.id == lateID)
        #expect(viewModel.photos.first?.id != recognizedID)
    }

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

        await viewModel.recognize()

        #expect(viewModel.needsAPIKey == true)
        #expect(viewModel.completedSession == nil)
        #expect(viewModel.isRecognizing == false)
    }

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

    @Test("Global six-photo cap includes direct additions and reports every rejection")
    func globalPhotoCapRejectsOverflow() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = try makeContext()
        let viewModel = CaptureViewModel(modelContext: context, provider: MockVisionProvider(), defaults: defaults)

        let result = viewModel.addPhotos(Array(repeating: makeDemoImage(), count: 8))

        #expect(result == PhotoAddResult(accepted: 6, rejected: 2))
        #expect(viewModel.photos.count == CaptureLimits.maxPhotoCount)
        #expect(viewModel.remainingPhotoCapacity == 0)
        #expect(viewModel.captureIssue == .photoLimitExceeded(maximum: 6, rejected: 2))
    }

    @Test("Pending reservations count toward the global cap")
    func pendingReservationsCountTowardCap() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = try makeContext()
        let viewModel = CaptureViewModel(modelContext: context, provider: MockVisionProvider(), defaults: defaults)

        let reservation = viewModel.reservePhotoSlots(count: 4)
        let addition = viewModel.addPhotos(Array(repeating: makeDemoImage(), count: 4))

        #expect(reservation.ids.count == 4)
        #expect(addition == PhotoAddResult(accepted: 2, rejected: 2))
        #expect(viewModel.photos.count == 6)
        #expect(viewModel.pendingPhotoCount == 4)
        #expect(viewModel.canRecognize == false)
    }

    @Test("Adding controls pause for pending work, recognition, and full capacity")
    func addMorePhotosGateTracksCaptureState() throws {
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
    }

    @Test("One JPEG preparation failure blocks the whole batch and retains every staged photo")
    func partialJPEGFailureIsAtomic() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let context = try makeContext()
        let provider = CountingVisionProvider()
        var preparationCount = 0
        let viewModel = CaptureViewModel(
            modelContext: context,
            provider: provider,
            defaults: defaults,
            photoPreparer: { image in
                preparationCount += 1
                return preparationCount == 2 ? nil : ImagePrep.preparedPhoto(from: image)
            }
        )
        viewModel.addPhotos([makeDemoImage(), makeDemoImage()])

        await viewModel.recognize()

        let extractCallCount = await provider.extractCallCount
        #expect(extractCallCount == 0)
        #expect(viewModel.photos.count == 2)
        #expect(viewModel.failedPhotoCount == 1)
        #expect(viewModel.completedSession == nil)
        #expect(viewModel.captureIssue == .photoPreparationFailed(count: 1))
    }

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

@Suite("Capture request budget")
struct CaptureRequestBudgetTests {
    @Test("18,000,000-byte boundary is inclusive and one byte over is rejected")
    func exactByteBoundary() {
        #expect(CaptureLimits.isWithinRequestBudget(estimatedBytes: 18_000_000))
        #expect(!CaptureLimits.isWithinRequestBudget(estimatedBytes: 18_000_001))
    }
}
