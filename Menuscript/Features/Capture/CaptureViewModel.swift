// Owns capture-screen state and coordinates image preparation, recognition,
// service selection, and persistence so the SwiftUI view only renders state.

import Foundation
import Observation
import SwiftData
import UIKit

/// Carries one immutable UIKit image into the JPEG preparation task. UIImage
/// is only read by the injected, `@Sendable` preparer and is never shared back
/// to the main actor from that task.
private struct SendablePreparationImage: @unchecked Sendable {
    let image: UIImage
}

/// Pairs a reserved photo slot with the image that will be prepared for it.
/// Keeping the ID with the work lets results return in any order safely.
private struct PhotoPreparationRequest: Sendable {
    let id: UUID
    let image: SendablePreparationImage
}

/// Drives the "capture → recognize → persist" flow for a menu: holds the
/// photos the user has gathered, resolves a `MenuVisionProvider` (mock or
/// Gemini, per Settings) when none is injected, extracts and translates the
/// menu, fetches an FX rate, and persists the result as a `MenuSession`.
@Observable
@MainActor
final class CaptureViewModel: Identifiable {
    /// Supplies runtime services at the moment recognition starts, which keeps
    /// settings-driven production behavior replaceable in tests.
    typealias RuntimeResolver = @MainActor () throws -> RuntimeServices?
    /// Saves a model context; replaceable so tests can simulate save failures.
    typealias ContextSave = @MainActor (ModelContext) throws -> Void
    /// Compresses one image into the preview and JPEG data sent for recognition.
    typealias PhotoPreparer = @Sendable (UIImage) -> ImagePrep.PreparedPhoto?

    static let liveDisclosureAcceptedKey = "privacy.googleGeminiDisclosureAccepted.v1"

    var photos: [CapturedPhoto] = []
    var isRecognizing: Bool = false
    var errorMessage: String? = nil
    var captureIssue: CaptureIssue? = nil
    var needsAPIKey: Bool = false
    var recoveryAction: ProviderRecoveryAction? = nil
    var needsLiveDisclosure: Bool = false
    var completedSession: MenuSession? = nil

    /// True only when every staged photo is ready and no recognition is running.
    /// This central rule prevents partial or duplicate submissions.
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

    /// Number of additional slots available before the shared photo limit.
    var remainingPhotoCapacity: Int {
        max(0, CaptureLimits.maxPhotoCount - photos.count)
    }

    /// Counts imports that still need to finish preparing their image data.
    var pendingPhotoCount: Int {
        photos.lazy.filter(\.isPending).count
    }

    /// Counts photos that cannot be sent until the user replaces them.
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
    private let photoPreparer: PhotoPreparer
    private let saveContext: ContextSave
    private var recognizeTask: Task<Void, Never>?

    /// Creates the workflow with production dependencies by default and allows
    /// focused substitutes for previews and tests without branching the logic.
    init(
        modelContext: ModelContext,
        provider: MenuVisionProvider? = nil,
        providerMode: RuntimeMode? = nil,
        secretStore: any SecretStore = KeychainStore(),
        fxProvider: (any FXRateProviding)? = nil,
        liveFXFactory: @escaping RuntimeServiceResolver.LiveFXFactory = { FXService() },
        runtimeResolver: RuntimeResolver? = nil,
        defaults: UserDefaults = .standard,
        photoPreparer: @escaping PhotoPreparer = ImagePrep.preparedPhoto(from:),
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
    /// here as a final authority, and every accepted image reserves a stable
    /// slot before JPEG preparation moves off the main actor.
    @discardableResult
    func addPhotos(_ images: [UIImage]) -> PhotoAddResult {
        let reservation = reservePhotoSlots(count: images.count)
        let photoPreparer = photoPreparer
        var requests: [PhotoPreparationRequest] = []
        requests.reserveCapacity(reservation.ids.count)

        for (id, image) in zip(reservation.ids, images.prefix(reservation.ids.count)) {
            if let index = photos.firstIndex(where: { $0.id == id }) {
                // Direct camera/DEBUG additions already have a preview. Keep
                // it visible if background JPEG encoding later fails.
                photos[index].preview = image
            }
            requests.append(
                PhotoPreparationRequest(
                    id: id,
                    image: SendablePreparationImage(image: image)
                )
            )
        }

        Task { @MainActor [weak self, photoPreparer, requests] in
            for request in requests {
                let result = await Task.detached(priority: .userInitiated) {
                    let result: Result<ImagePrep.PreparedPhoto, CapturedPhotoFailure>
                    if let prepared = photoPreparer(request.image.image) {
                        result = .success(prepared)
                    } else {
                        result = .failure(.jpegEncodingFailed)
                    }
                    return result
                }.value

                guard !Task.isCancelled else { return }
                self?.resolvePhotoSlot(id: request.id, with: result)
            }
        }

        return PhotoAddResult(
            accepted: reservation.ids.count,
            rejected: reservation.rejected
        )
    }

    /// Removes a photo by its current grid position and clears any issue that
    /// the removal has resolved. Invalid positions are ignored safely.
    func removePhoto(at index: Int) {
        guard photos.indices.contains(index) else { return }
        photos.remove(at: index)
        reconcileCaptureIssue()
    }

    /// Removes the stable photo slot with `id`, which is safer while imports
    /// may finish asynchronously and change the array's contents.
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

    /// Applies a preparation result only to its still-pending reserved slot.
    /// Success stores JPEG data safe for background work; failure stays visible.
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

    /// Discards unresolved placeholders, normally after their import tasks are
    /// cancelled, while preserving photos that already reached a final state.
    func removePendingPhotoSlots() {
        photos.removeAll { $0.isPending }
        reconcileCaptureIssue()
    }

    /// Starts `recognize()` as a task owned by this view model, so a later
    /// `cancelRecognize()` call (for example, the user tapping Cancel) can actually
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

    /// Records the one-time consent for live Gemini requests and closes the
    /// disclosure so the caller can retry the pending recognition.
    func acceptLiveDisclosure() {
        defaults.set(true, forKey: Self.liveDisclosureAcceptedKey)
        needsLiveDisclosure = false
    }

    /// Closes the live-service disclosure without recording consent.
    func cancelLiveDisclosure() {
        needsLiveDisclosure = false
    }

    /// Resets provider-specific error state after an alert is dismissed.
    func clearProviderError() {
        errorMessage = nil
        recoveryAction = nil
        needsAPIKey = false
    }

    /// Runs the complete recognition transaction: validates all photos, resolves
    /// services and settings, calls vision/FX providers, then saves one session.
    /// Cancellation and save failure exit without leaving a partial session.
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

    /// Selects injected services for tests or resolves the current production
    /// mode from Settings. The returned flag says whether consent is required.
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
            } else {
                // Injected vision providers are used by tests and previews.
                // Keep them fully offline unless the caller explicitly supplies
                // an FX provider, regardless of the provider mode being tested.
                fxProvider = MockFXService()
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

    /// Converts a known vision-provider failure into alert and recovery state.
    private func handleProviderError(_ error: VisionProviderError) {
        errorMessage = error.errorDescription
        recoveryAction = error.recoveryAction
        needsAPIKey = error.requiresAPIKeyUpdate
    }

    /// Presents runtime setup failures without exposing storage implementation
    /// details, while retaining a specific message for known Keychain errors.
    private func handleRuntimeResolutionError(_ error: Error) {
        if let keychainError = error as? KeychainError {
            errorMessage = keychainError.errorDescription
        } else {
            errorMessage = L10n.string("安全儲存空間暫時無法使用，請稍後再試。", defaults: defaults)
        }
        recoveryAction = .retry
        needsAPIKey = false
    }

    /// Clears a capture warning once its underlying condition no longer exists.
    /// Unrelated warnings stay visible until explicitly handled.
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
