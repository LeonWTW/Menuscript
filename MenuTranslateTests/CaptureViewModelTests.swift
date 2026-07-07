import Foundation
import Testing
import SwiftData
import UIKit
@testable import MenuTranslate

/// A `MenuVisionProvider` that always fails, used to exercise the error path
/// without any network dependency.
private struct FailingVisionProvider: MenuVisionProvider {
    func extractMenu(images: [Data], targetLanguage: String) async throws -> ExtractedMenu {
        throw VisionProviderError.rateLimited
    }

    func explainDish(original: String, language: String, targetLanguage: String) async throws -> String {
        throw VisionProviderError.rateLimited
    }
}

@MainActor
@Suite("CaptureViewModel")
struct CaptureViewModelTests {
    private let settingsKeysToReset = [
        SettingsKeys.targetLanguage,
        SettingsKeys.homeCurrency,
        SettingsKeys.geminiModel,
        SettingsKeys.useMockProvider
    ]

    init() {
        for key in settingsKeysToReset {
            UserDefaults.standard.removeObject(forKey: key)
        }
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
        #expect(viewModel.photos.count == 1)

        let session = try #require(viewModel.completedSession)
        #expect(session.items.count == 10)
        #expect(session.title == "鷹の目")
        #expect(session.targetLanguage == "繁體中文")
        #expect(session.homeCurrency == "HKD")
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

    @Test("Missing API key with mock disabled sets needsAPIKey")
    func missingAPIKeySetsNeedsAPIKey() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKeys.useMockProvider)
        let context = try makeContext()
        let emptyKeychain = KeychainStore(service: "com.leonwong.menutranslate.tests.\(UUID().uuidString)")
        let viewModel = CaptureViewModel(modelContext: context, keychainStore: emptyKeychain)
        viewModel.addPhotos([makeDemoImage()])

        await viewModel.recognize()

        #expect(viewModel.needsAPIKey == true)
        #expect(viewModel.completedSession == nil)
        #expect(viewModel.isRecognizing == false)
    }
}
