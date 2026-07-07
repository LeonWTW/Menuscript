import Foundation
import Observation
import SwiftData
import UIKit

/// Drives the "capture → recognize → persist" flow for a menu: holds the
/// photos the user has gathered, resolves a `MenuVisionProvider` (mock or
/// Gemini, per Settings) when none is injected, extracts and translates the
/// menu, fetches an FX rate, and persists the result as a `MenuSession`.
@Observable
@MainActor
final class CaptureViewModel {
    var photos: [UIImage] = []
    var isRecognizing: Bool = false
    var errorMessage: String? = nil
    var needsAPIKey: Bool = false
    var completedSession: MenuSession? = nil

    var canRecognize: Bool { !photos.isEmpty && !isRecognizing }

    private let modelContext: ModelContext
    private let injectedProvider: MenuVisionProvider?
    private let keychainStore: KeychainStore

    init(
        modelContext: ModelContext,
        provider: MenuVisionProvider? = nil,
        keychainStore: KeychainStore = KeychainStore()
    ) {
        self.modelContext = modelContext
        self.injectedProvider = provider
        self.keychainStore = keychainStore
    }

    func addPhotos(_ images: [UIImage]) {
        photos.append(contentsOf: images)
    }

    func removePhoto(at index: Int) {
        guard photos.indices.contains(index) else { return }
        photos.remove(at: index)
    }

    func recognize() async {
        guard canRecognize else { return }

        errorMessage = nil
        needsAPIKey = false
        isRecognizing = true
        defer { isRecognizing = false }

        let defaults = UserDefaults.standard
        let targetLanguage = defaults.string(forKey: SettingsKeys.targetLanguage) ?? "繁體中文"
        let homeCurrency = defaults.string(forKey: SettingsKeys.homeCurrency) ?? "HKD"

        let provider: MenuVisionProvider
        if let injectedProvider {
            provider = injectedProvider
        } else if defaults.bool(forKey: SettingsKeys.useMockProvider) {
            provider = MockVisionProvider()
        } else if let apiKey = keychainStore.get(KeychainStore.geminiAPIKey), !apiKey.isEmpty {
            let model = defaults.string(forKey: SettingsKeys.geminiModel) ?? "gemini-2.5-flash"
            provider = GeminiProvider(apiKey: { apiKey }, model: model)
        } else {
            needsAPIKey = true
            return
        }

        do {
            let imageData = photos.compactMap { ImagePrep.jpegData(from: $0) }
            let extracted = try await provider.extractMenu(images: imageData, targetLanguage: targetLanguage)
            let fxRate = await FXService().rate(from: extracted.menuCurrency, to: homeCurrency)

            let items = extracted.items.enumerated().map { index, item in
                MenuItem(
                    originalName: item.original,
                    translatedName: item.translated,
                    priceValue: item.price,
                    priceNote: item.priceNote,
                    category: item.category,
                    lowConfidence: item.lowConfidence,
                    quantity: 0,
                    sortOrder: index
                )
            }

            let session = MenuSession(
                title: extracted.restaurantName,
                detectedLanguage: extracted.detectedLanguage,
                targetLanguage: targetLanguage,
                menuCurrency: extracted.menuCurrency,
                homeCurrency: homeCurrency,
                fxRate: fxRate?.rate,
                fxRateDate: fxRate?.date,
                photos: imageData,
                items: items
            )

            modelContext.insert(session)
            try modelContext.save()
            completedSession = session
        } catch {
            errorMessage = (error as? VisionProviderError)?.errorDescription ?? error.localizedDescription
        }
    }
}
