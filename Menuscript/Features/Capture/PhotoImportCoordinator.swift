import Foundation

/// Owns every asynchronous photo-library import for one Capture screen.
/// Reservations are made synchronously; a generation token plus task
/// cancellation prevents a dismissed/replaced screen from accepting late data.
@MainActor
final class PhotoImportCoordinator {
    typealias Loader = @Sendable () async -> Result<ImagePrep.PreparedPhoto, CapturedPhotoFailure>

    private var generation = UUID()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    @discardableResult
    func importBatch(
        loaders: [Loader],
        into viewModel: CaptureViewModel
    ) -> PhotoAddResult {
        guard !loaders.isEmpty else { return PhotoAddResult(accepted: 0, rejected: 0) }

        let reservation = viewModel.reservePhotoSlots(count: loaders.count)
        let acceptedLoaders = Array(loaders.prefix(reservation.ids.count))
        guard !acceptedLoaders.isEmpty else {
            return PhotoAddResult(accepted: 0, rejected: reservation.rejected)
        }

        let batchID = UUID()
        let batchGeneration = generation
        let reservedIDs = reservation.ids

        let task = Task { [weak self, weak viewModel] in
            for (id, loader) in zip(reservedIDs, acceptedLoaders) {
                guard !Task.isCancelled else { break }
                let result = await loader()
                guard !Task.isCancelled,
                      let self,
                      self.generation == batchGeneration,
                      let viewModel else {
                    break
                }
                viewModel.resolvePhotoSlot(id: id, with: result)
            }

            guard let self, self.generation == batchGeneration else { return }
            self.tasks[batchID] = nil
        }
        tasks[batchID] = task

        return PhotoAddResult(accepted: reservedIDs.count, rejected: reservation.rejected)
    }

    /// Cancels all imports and removes only unresolved reservations. Ready or
    /// failed slots from already-completed work remain explicit in the grid.
    func cancelAll(in viewModel: CaptureViewModel) {
        generation = UUID()
        for task in tasks.values {
            task.cancel()
        }
        tasks.removeAll()
        viewModel.removePendingPhotoSlots()
    }
}

/// Distinguishes Capture actually leaving the hierarchy from SwiftUI calling
/// `onDisappear` while one of Capture's own child presentations covers it.
/// Keeping this decision outside the View makes reservation retention
/// deterministic and directly testable.
@MainActor
enum CaptureImportLifecycle {
    static func handleDisappear(
        isPresentingCamera: Bool,
        isPresentingSettings: Bool,
        coordinator: PhotoImportCoordinator,
        viewModel: CaptureViewModel
    ) {
        guard !isPresentingCamera, !isPresentingSettings else { return }
        coordinator.cancelAll(in: viewModel)
    }
}
