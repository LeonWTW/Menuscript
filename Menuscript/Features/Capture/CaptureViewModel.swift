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
    typealias RuntimeResolver = @MainActor () throws -> RuntimeServices?
    typealias ContextSave = @MainActor (ModelContext) throws -> Void

    static let liveDisclosureAcceptedKey = "privacy.googleGeminiDisclosureAccepted.v1"

    var photos: [CapturedPhoto] = []
    var isRecognizing: Bool = false
    var errorMessage: String? = nil
    var captureIssue: CaptureIssue? = nil
    var needsAPIKey: Bool = false
    var recoveryAction: ProviderRecoveryAction? = nil
    var needsLiveDisclosure: Bool = false
    var completedSession: MenuSession? = nil

    var canRecognize: Bool {
        !photos.isEmpty
            && pendingPhotoCount == 0
            && failedPhotoCount == 0
            && photos.allSatisfy(\.isReady)
            && !isRecognizing
    }

    /// One source of truth for every user-facing photo entry point. While a
    /// library import is pending, the user waits for it to settle before
    /// opening another picker/camera flow; the coordinator still defends
    /// against overlapping programmatic or stale events.
    var canAddMorePhotos: Bool {
        pendingPhotoCount == 0
            && remainingPhotoCapacity > 0
            && !isRecognizing
    }

    var remainingPhotoCapacity: Int {
        max(0, CaptureLimits.maxPhotoCount - photos.count)
    }

    var pendingPhotoCount: Int {
        photos.lazy.filter(\.isPending).count
    }

    var failedPhotoCount: Int {
        photos.lazy.filter { $0.failure != nil }.count
    }

    private let modelContext: ModelContext
    private let injectedProvider: MenuVisionProvider?
    private let injectedProviderMode: RuntimeMode?
    private let injectedFXProvider: (any FXRateProviding)?
    private let secretStore: any SecretStore
    private let liveFXFactory: RuntimeServiceResolver.LiveFXFactory
    private let runtimeResolver: RuntimeResolver?
    private let defaults: UserDefaults
    private let photoPreparer: (UIImage) -> ImagePrep.PreparedPhoto?
    private let saveContext: ContextSave
    private var recognizeTask: Task<Void, Never>?

    init(
        modelContext: ModelContext,
        provider: MenuVisionProvider? = nil,
        providerMode: RuntimeMode? = nil,
        secretStore: any SecretStore = KeychainStore(),
        fxProvider: (any FXRateProviding)? = nil,
        liveFXFactory: @escaping RuntimeServiceResolver.LiveFXFactory = { FXService() },
        runtimeResolver: RuntimeResolver? = nil,
        defaults: UserDefaults = .standard,
        photoPreparer: @escaping (UIImage) -> ImagePrep.PreparedPhoto? = ImagePrep.preparedPhoto(from:),
        saveContext: @escaping ContextSave = { try $0.save() }
    ) {
        self.modelContext = modelContext
        self.injectedProvider = provider
        self.injectedProviderMode = providerMode
        self.injectedFXProvider = fxProvider
        self.secretStore = secretStore
        if let fxProvider {
            self.liveFXFactory = { fxProvider }
        } else {
            self.liveFXFactory = liveFXFactory
        }
        self.runtimeResolver = runtimeResolver
        self.defaults = defaults
        self.photoPreparer = photoPreparer
        self.saveContext = saveContext
    }

    /// Camera, DEBUG and direct-call entry point. The global cap is enforced
    /// here as a final authority, and every accepted image occupies a stable
    /// slot even if its JPEG preparation fails.
    @discardableResult
    func addPhotos(_ images: [UIImage]) -> PhotoAddResult {
        let acceptedCount = min(images.count, remainingPhotoCapacity)
        let rejectedCount = images.count - acceptedCount

        var preparationFailures = 0
        for image in images.prefix(acceptedCount) {
            if let prepared = photoPreparer(image), !prepared.jpegData.isEmpty {
                photos.append(CapturedPhoto(
                    preview: prepared.preview,
                    state: .ready(prepared.jpegData)
                ))
            } else {
                preparationFailures += 1
                photos.append(CapturedPhoto(
                    preview: image,
                    state: .failed(.jpegEncodingFailed)
                ))
            }
        }

        if rejectedCount > 0 {
            captureIssue = .photoLimitExceeded(
                maximum: CaptureLimits.maxPhotoCount,
                rejected: rejectedCount
            )
        } else if preparationFailures > 0 {
            captureIssue = .photoPreparationFailed(count: failedPhotoCount)
        }

        return PhotoAddResult(accepted: acceptedCount, rejected: rejectedCount)
    }

    func removePhoto(at index: Int) {
        guard photos.indices.contains(index) else { return }
        photos.remove(at: index)
        reconcileCaptureIssue()
    }

    func removePhoto(id: UUID) {
        photos.removeAll { $0.id == id }
        reconcileCaptureIssue()
    }

    /// Reserves ordered slots before an asynchronous picker import starts.
    /// Pending reservations count toward the six-photo cap immediately.
    func reservePhotoSlots(count: Int) -> PhotoReservation {
        guard count > 0 else { return PhotoReservation(ids: [], rejected: 0) }
        let acceptedCount = min(count, remainingPhotoCapacity)
        let rejectedCount = count - acceptedCount
        let ids = (0..<acceptedCount).map { _ in UUID() }
        photos.append(contentsOf: ids.map { CapturedPhoto(id: $0) })

        if rejectedCount > 0 {
            captureIssue = .photoLimitExceeded(
                maximum: CaptureLimits.maxPhotoCount,
                rejected: rejectedCount
            )
        }
        return PhotoReservation(ids: ids, rejected: rejectedCount)
    }

    func resolvePhotoSlot(
        id: UUID,
        with result: Result<ImagePrep.PreparedPhoto, CapturedPhotoFailure>
    ) {
        guard let index = photos.firstIndex(where: { $0.id == id }), photos[index].isPending else {
            return
        }

        switch result {
        case .success(let prepared) where !prepared.jpegData.isEmpty:
            photos[index].preview = prepared.preview
            photos[index].state = .ready(prepared.jpegData)
        case .success(let prepared):
            photos[index].preview = prepared.preview
            photos[index].state = .failed(.jpegEncodingFailed)
            captureIssue = .photoPreparationFailed(count: failedPhotoCount)
        case .failure(let failure):
            photos[index].state = .failed(failure)
            captureIssue = .photoPreparationFailed(count: failedPhotoCount)
        }
    }

    func removePendingPhotoSlots() {
        photos.removeAll { $0.isPending }
        reconcileCaptureIssue()
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

    func acceptLiveDisclosure() {
        defaults.set(true, forKey: Self.liveDisclosureAcceptedKey)
        needsLiveDisclosure = false
    }

    func cancelLiveDisclosure() {
        needsLiveDisclosure = false
    }

    func clearProviderError() {
        errorMessage = nil
        recoveryAction = nil
        needsAPIKey = false
    }

    func recognize() async {
        guard !isRecognizing, !photos.isEmpty else { return }
        guard pendingPhotoCount == 0 else {
            captureIssue = .photosStillLoading(count: pendingPhotoCount)
            return
        }
        guard failedPhotoCount == 0 else {
            captureIssue = .photoPreparationFailed(count: failedPhotoCount)
            return
        }

        let recognizedPhotos = photos
        var imageData: [Data] = []
        imageData.reserveCapacity(recognizedPhotos.count)
        for photo in recognizedPhotos {
            guard let data = photo.jpegData, !data.isEmpty else {
                // Atomic preparation: never send a subset of the staged menu.
                captureIssue = .photoPreparationFailed(count: max(1, failedPhotoCount))
                return
            }
            imageData.append(data)
        }

        let estimatedRequestBytes = CaptureLimits.estimatedSerializedRequestBytes(imageData: imageData)
        guard CaptureLimits.isWithinRequestBudget(estimatedBytes: estimatedRequestBytes) else {
            captureIssue = .requestTooLarge(
                estimatedBytes: estimatedRequestBytes,
                limit: CaptureLimits.maxSerializedRequestBytes
            )
            return
        }

        errorMessage = nil
        captureIssue = nil
        needsAPIKey = false
        recoveryAction = nil
        needsLiveDisclosure = false
        isRecognizing = true
        defer { isRecognizing = false }

        let targetLanguage = SettingsKeys.nonEmptyString(
            SettingsKeys.targetLanguage,
            from: defaults,
            default: SettingsKeys.defaultTargetLanguage(appLanguage: AppLanguage.resolve(from: defaults))
        )
        let homeCurrency = SettingsKeys.nonEmptyString(SettingsKeys.homeCurrency, from: defaults, default: "USD")
        // Free-text / comma-joined settings: read raw — an empty value is a
        // valid "no allergens" state, not a fall-back-to-default like the reads above.
        let allergens = Allergen.parse(
            presets: defaults.string(forKey: SettingsKeys.allergenPresets) ?? "",
            custom: defaults.string(forKey: SettingsKeys.allergenCustom) ?? ""
        )

        let runtime: RuntimeServices
        let requiresDisclosure: Bool
        do {
            guard let resolved = try resolvedRuntime() else {
                handleProviderError(.missingAPIKey)
                return
            }
            runtime = resolved.services
            requiresDisclosure = resolved.requiresDisclosure
        } catch {
            handleRuntimeResolutionError(error)
            return
        }

        if requiresDisclosure,
           runtime.mode == .live,
           !defaults.bool(forKey: Self.liveDisclosureAcceptedKey) {
            needsLiveDisclosure = true
            return
        }

        do {
            let extracted = try await runtime.visionProvider.extractMenu(
                images: imageData,
                targetLanguage: targetLanguage,
                allergens: allergens
            )
            guard !Task.isCancelled else { return }

            let fxRate: FXRate?
            if extracted.menuCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                == homeCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
                fxRate = nil
            } else {
                fxRate = await runtime.fxRateProvider.rate(
                    from: extracted.menuCurrency,
                    to: homeCurrency
                )
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
                    summary: item.summary,
                    possibleAllergens: item.possibleAllergens,
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
                fxQuoteDate: fxRate?.quoteDate,
                fxFetchedAt: fxRate?.fetchedAt,
                providerModeRaw: runtime.mode.rawValue,
                photos: imageData,
                allergenProfile: allergens,
                items: items
            )

            guard !Task.isCancelled else { return }
            modelContext.insert(session)
            do {
                try saveContext(modelContext)
            } catch {
                discardInsertedGraph(session: session, items: items)
                completedSession = nil
                errorMessage = L10n.string("未能儲存菜單，請再試一次。", defaults: defaults)
                recoveryAction = .retry
                return
            }
            completedSession = session
            // Stable slot IDs remove exactly the recognized snapshot. Photos
            // reserved/appended later survive even if their UIImage instance
            // happens to be identical to one already recognized.
            let recognizedIDs = Set(recognizedPhotos.map(\.id))
            photos.removeAll { recognizedIDs.contains($0.id) }
        } catch {
            guard !Task.isCancelled else { return }
            if let providerError = error as? VisionProviderError {
                handleProviderError(providerError)
            } else {
                errorMessage = L10n.string("辨識暫時失敗，請再試一次。", defaults: defaults)
                recoveryAction = .retry
            }
        }
    }

    /// Cancels only the objects created by the failed recognition attempt.
    /// `ModelContext.rollback()` is intentionally avoided because the shared
    /// main context may contain unrelated, still-pending user edits.
    private func discardInsertedGraph(session: MenuSession, items: [MenuItem]) {
        for item in items where !item.isDeleted {
            modelContext.delete(item)
        }
        if !session.isDeleted {
            modelContext.delete(session)
        }
        // SwiftData otherwise keeps an unsaved insert→delete pair in both its
        // inserted and deleted arrays until a later save. Processing the
        // changes reconciles that pair without touching unrelated edits.
        modelContext.processPendingChanges()
    }

    private func resolvedRuntime() throws -> (
        services: RuntimeServices,
        requiresDisclosure: Bool
    )? {
        if let runtimeResolver {
            guard let services = try runtimeResolver() else { return nil }
            return (services, true)
        }

        if let injectedProvider {
            let mode = injectedProviderMode
                ?? (injectedProvider is MockVisionProvider ? .mock : .live)
            let fxProvider: any FXRateProviding
            if let injectedFXProvider {
                fxProvider = injectedFXProvider
            } else if mode == .mock {
                fxProvider = MockFXService()
            } else {
                fxProvider = liveFXFactory()
            }
            return (
                RuntimeServices(
                    mode: mode,
                    visionProvider: injectedProvider,
                    fxRateProvider: fxProvider
                ),
                false
            )
        }

        guard let services = try RuntimeServiceResolver.resolveFromPreferences(
            secretStore: secretStore,
            defaults: defaults,
            liveFXFactory: liveFXFactory
        ) else {
            return nil
        }
        return (services, true)
    }

    private func handleProviderError(_ error: VisionProviderError) {
        errorMessage = error.errorDescription
        recoveryAction = error.recoveryAction
        needsAPIKey = error.requiresAPIKeyUpdate
    }

    private func handleRuntimeResolutionError(_ error: Error) {
        if let keychainError = error as? KeychainError {
            errorMessage = keychainError.errorDescription
        } else {
            errorMessage = L10n.string("安全儲存空間暫時無法使用，請稍後再試。", defaults: defaults)
        }
        recoveryAction = .retry
        needsAPIKey = false
    }

    private func reconcileCaptureIssue() {
        switch captureIssue {
        case .photoLimitExceeded where remainingPhotoCapacity > 0:
            captureIssue = nil
        case .photosStillLoading where pendingPhotoCount == 0:
            captureIssue = nil
        case .photoPreparationFailed where failedPhotoCount == 0:
            captureIssue = nil
        default:
            break
        }
    }
}
