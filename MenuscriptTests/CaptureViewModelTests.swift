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

@MainActor
@Suite("CaptureViewModel")
struct CaptureViewModelTests {
    private let settingsKeysToReset = [
        SettingsKeys.targetLanguage,
        SettingsKeys.homeCurrency,
        SettingsKeys.geminiModel,
        SettingsKeys.useMockProvider,
        SettingsKeys.appLanguage,
        SettingsKeys.allergenPresets,
        SettingsKeys.allergenCustom
    ]

    init() {
        for key in settingsKeysToReset {
            UserDefaults.standard.removeObject(forKey: key)
        }
        // Pin appLanguage explicitly: with targetLanguage unset,
        // `recognize()` falls back to `SettingsKeys.defaultTargetLanguage()`,
        // which follows the system locale when appLanguage is unset/.system.
        // Pinning to zh-Hant keeps this suite's expectations deterministic
        // across host/CI locales instead of depending on the test runner's
        // system language.
        UserDefaults.standard.set(AppLanguage.zhHant.rawValue, forKey: SettingsKeys.appLanguage)
    }

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

    @Test("Successful recognition persists a session with 10 ordered items")
    func successfulRecognitionPersistsSession() async throws {
        let context = try makeContext()
        let viewModel = CaptureViewModel(modelContext: context, provider: MockVisionProvider())
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
        #expect(session.homeCurrency == "USD")
        #expect(session.items.allSatisfy { $0.quantity == 0 })

        let sortOrders = session.items.map(\.sortOrder).sorted()
        #expect(sortOrders == Array(0..<10))

        let fetchedSessions = try context.fetch(FetchDescriptor<MenuSession>())
        #expect(fetchedSessions.count == 1)
    }

    @Test("Failing provider surfaces the localized error and preserves photos")
    func failingProviderSurfacesError() async throws {
        let context = try makeContext()
        let viewModel = CaptureViewModel(modelContext: context, provider: FailingVisionProvider())
        viewModel.addPhotos([makeDemoImage()])

        await viewModel.recognize()

        #expect(viewModel.errorMessage == VisionProviderError.rateLimited.errorDescription)
        #expect(viewModel.photos.count == 1)
        #expect(viewModel.completedSession == nil)
        #expect(viewModel.isRecognizing == false)
    }

    @Test("Cancelling recognize before it finishes discards the result: no session is persisted, no error is shown")
    func cancellingRecognizeDiscardsInFlightResult() async throws {
        let context = try makeContext()
        let viewModel = CaptureViewModel(modelContext: context, provider: SlowVisionProvider())
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

    @Test("Photo appended after recognition starts survives; the recognized snapshot is removed")
    func photoAppendedDuringRecognitionSurvives() async throws {
        let context = try makeContext()
        let viewModel = CaptureViewModel(modelContext: context, provider: SlowVisionProvider())
        let recognizedPhoto = makeDemoImage()
        viewModel.addPhotos([recognizedPhoto])

        let task = Task { await viewModel.recognize() }
        try await Task.sleep(nanoseconds: 50_000_000) // let it enter the provider's sleep, past the snapshot point
        let latePhoto = makeDemoImage()
        viewModel.addPhotos([latePhoto])
        await task.value

        #expect(viewModel.isRecognizing == false)
        #expect(viewModel.completedSession != nil)
        #expect(viewModel.photos.count == 1)
        #expect(viewModel.photos.first === latePhoto)
    }

    @Test("Missing API key with mock disabled sets needsAPIKey")
    func missingAPIKeySetsNeedsAPIKey() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKeys.useMockProvider)
        let context = try makeContext()
        let emptyKeychain = KeychainStore(service: "com.leonwong.menuscript.tests.\(UUID().uuidString)")
        let viewModel = CaptureViewModel(modelContext: context, keychainStore: emptyKeychain)
        viewModel.addPhotos([makeDemoImage()])

        await viewModel.recognize()

        #expect(viewModel.needsAPIKey == true)
        #expect(viewModel.completedSession == nil)
        #expect(viewModel.isRecognizing == false)
    }

    @Test("Recognition persists per-dish summary and possibleAllergens, and snapshots the session allergen profile")
    func recognitionPersistsAllergenFieldsAndProfile() async throws {
        // Seed allergen settings via the same UserDefaults path init() resets;
        // home currency matches the mock menu currency so recognize() skips the
        // FX network lookup and the test stays hermetic.
        UserDefaults.standard.set("wheat,soy", forKey: SettingsKeys.allergenPresets)
        UserDefaults.standard.set("香菜", forKey: SettingsKeys.allergenCustom)
        UserDefaults.standard.set("JPY", forKey: SettingsKeys.homeCurrency)

        let context = try makeContext()
        let viewModel = CaptureViewModel(modelContext: context, provider: AllergenVisionProvider())
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
}
