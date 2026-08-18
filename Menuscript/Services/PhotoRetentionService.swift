// Applies the photo-retention setting by removing the original photos of older
// completed sessions, while their finalized bills and dishes stay untouched.

import Foundation
import SwiftData

/// Throwing persistence boundary for the retention policy's single destructive
/// operation. Pruning is deliberately narrow: it clears a session's original
/// photos and records when that happened. It never deletes a session, never
/// rewrites a completed bill, and never touches a menu the user can still edit.
@MainActor
struct PhotoRetentionService {
    /// Injectable save operation used to reproduce persistence failures in tests.
    typealias SaveAction = @MainActor (ModelContext) throws -> Void
    /// Injectable full-history fetch so pruning can be tested without changing production queries.
    typealias FetchAllAction = @MainActor (ModelContext) throws -> [MenuSession]

    private let context: ModelContext
    private let saveAction: SaveAction
    private let fetchAllAction: FetchAllAction

    /// Creates a service around the UI's model context, with replaceable
    /// persistence actions for deterministic tests.
    init(
        context: ModelContext,
        saveAction: @escaping SaveAction = { try $0.save() },
        fetchAllAction: @escaping FetchAllAction = {
            try $0.fetch(FetchDescriptor<MenuSession>())
        }
    ) {
        self.context = context
        self.saveAction = saveAction
        self.fetchAllAction = fetchAllAction
    }

    /// Removes the original photos of completed sessions that are at least one
    /// retention window old, and reports how many sessions were pruned.
    ///
    /// Age is measured from `createdAt` and the boundary is inclusive, so a
    /// session exactly one window old is pruned. Drafts, sessions saved by older
    /// app versions, and completed sessions without a stored bill are all
    /// protected: for those the photos are the only surviving record of the meal.
    @discardableResult
    func pruneExpiredPhotos(policy: PhotoRetentionPolicy, now: Date = .now) throws -> Int {
        guard let window = policy.retentionWindow else { return 0 }

        // Every change is made in a short-lived context that never autosaves, so
        // a failed save is discarded whole and the UI's own context can never
        // commit a half-finished prune.
        let pruneContext = ModelContext(context.container)
        pruneContext.autosaveEnabled = false

        let sessions: [MenuSession]
        do {
            sessions = try fetchAllAction(pruneContext)
        } catch {
            throw PhotoRetentionError.fetchFailed(error.localizedDescription)
        }

        // Small stored fields are tested before `photos`, so the large
        // external-storage data is only loaded for sessions that may be pruned.
        let expired = sessions.filter { session in
            session.lifecycleStatus == .completed
                && session.billSnapshotData != nil
                && now.timeIntervalSince(session.createdAt) >= window
                && session.photosPrunedAt == nil
                && !session.photos.isEmpty
        }
        guard !expired.isEmpty else { return 0 }

        for session in expired {
            session.photos = []
            session.photosPrunedAt = now
        }

        do {
            try saveAction(pruneContext)
        } catch {
            throw PhotoRetentionError.saveFailed(error.localizedDescription)
        }
        return expired.count
    }
}
