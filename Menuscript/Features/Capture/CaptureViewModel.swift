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
final class CaptureViewModel: Identifiable {
    var photos: [UIImage] = []
    var isRecognizing: Bool = false
    var errorMessage: String? = nil
    var needsAPIKey: Bool = false
    var completedSession: MenuSession? = nil

    var canRecognize: Bool { !photos.isEmpty && !isRecognizing }

    private let modelContext: ModelContext
    private let injectedProvider: MenuVisionProvider?
    private let keychainStore: KeychainStore
    private let fxService: FXService
    private var recognizeTask: Task<Void, Never>?

    init(
        modelContext: ModelContext,
        provider: MenuVisionProvider? = nil,
        keychainStore: KeychainStore = KeychainStore(),
        fxService: FXService = FXService()
    ) {
        self.modelContext = modelContext
        self.injectedProvider = provider
        self.keychainStore = keychainStore
        self.fxService = fxService
    }

    func addPhotos(_ images: [UIImage]) {
        photos.append(contentsOf: images)
    }

    func removePhoto(at index: Int) {
        guard photos.indices.contains(index) else { return }
        photos.remove(at: index)
    }

    /// Starts `recognize()` as a task owned by this view model, so a later
    /// `cancelRecognize()` call (e.g. the user tapping 取消) can actually
    /// interrupt the in-flight request instead of merely dismissing the UI.
    func startRecognize() {
        guard canRecognize else { return }
        recognizeTask = Task { [weak self] in
            await self?.recognize()
        }
    }

    /// Cancels the in-flight `recognize()` task, if any. `recognize()` checks
    /// `Task.isCancelled` after each await and bails out before persisting
    /// anything, so a cancelled recognition never inserts a session.
    func cancelRecognize() {
        recognizeTask?.cancel()
        recognizeTask = nil
    }

    func recognize() async {
        guard canRecognize else { return }

        errorMessage = nil
        needsAPIKey = false
        isRecognizing = true
        defer { isRecognizing = false }

        let defaults = UserDefaults.standard
        let targetLanguage = SettingsKeys.nonEmptyString(
            SettingsKeys.targetLanguage, from: defaults, default: SettingsKeys.defaultTargetLanguage()
        )
        let homeCurrency = SettingsKeys.nonEmptyString(SettingsKeys.homeCurrency, from: defaults, default: "USD")

        let provider: MenuVisionProvider
        if let injectedProvider {
            provider = injectedProvider
        } else if let resolved = ProviderFactory.resolve(keychain: keychainStore) {
            provider = resolved
        } else {
            needsAPIKey = true
            return
        }

        do {
            // Downscale/encode off the main actor: at 6 full-res photos this is
            // ~1-3s of JPEG work that would otherwise stall the UI before the
            // recognising overlay even has a chance to render.
            let recognizedPhotos = photos
            let imageData = await Task.detached(priority: .userInitiated) { [recognizedPhotos] in
                recognizedPhotos.compactMap { ImagePrep.jpegData(from: $0) }
            }.value
            let extracted = try await provider.extractMenu(images: imageData, targetLanguage: targetLanguage)
            guard !Task.isCancelled else { return }

            let fxRate: FXRate?
            if extracted.menuCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                == homeCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
                fxRate = nil
            } else {
                fxRate = await fxService.rate(from: extracted.menuCurrency, to: homeCurrency)
            }
            guard !Task.isCancelled else { return }

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
                fxSource: fxRate?.source.persistedValue,
                photos: imageData,
                items: items
            )

            guard !Task.isCancelled else { return }
            modelContext.insert(session)
            try modelContext.save()
            completedSession = session
            // Remove by identity, not removeAll(): photos appended to the
            // staging grid after `recognizedPhotos` was snapshotted above
            // must survive, since they were never sent for recognition.
            let recognizedIDs = Set(recognizedPhotos.map(ObjectIdentifier.init))
            photos.removeAll { recognizedIDs.contains(ObjectIdentifier($0)) }
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = (error as? VisionProviderError)?.errorDescription ?? error.localizedDescription
        }
    }
}
