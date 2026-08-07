// Coordinates reliable SwiftData writes for completing, updating, and deleting saved menu sessions.
// Each operation restores or isolates failed changes so the interface never claims that an unsaved mutation succeeded.

import Foundation
import SwiftData

/// Throwing persistence boundary for session finalization and destructive
/// history operations. Failed mutations are restored or isolated from the UI
/// context, so the app never reports a completed/deleted state that was not
/// saved.
@MainActor
struct SessionStore {
    /// Injectable save operation used to reproduce persistence failures in tests.
    typealias SaveAction = @MainActor (ModelContext) throws -> Void
    /// Injectable full-history fetch used to test delete-all failures without changing production queries.
    typealias FetchAllAction = @MainActor (ModelContext) throws -> [MenuSession]

    private let context: ModelContext
    private let saveAction: SaveAction
    private let fetchAllAction: FetchAllAction

    /// Creates a store around the UI's model context, with replaceable persistence actions for deterministic tests.
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

    /// Finalizes once. A second call returns the exact persisted snapshot and
    /// performs no write, so repeated taps or retries keep the same completed result.
    func finalize(_ session: MenuSession, completedAt: Date = .now) throws -> BillSnapshot {
        if session.lifecycleStatus == .completed {
            guard let snapshot = session.billSnapshot else {
                throw SessionStoreError.completedSessionMissingSnapshot
            }
            return snapshot
        }

        let snapshot = try BillSnapshot.capture(from: session, completedAt: completedAt)
        let encoded = try BillSnapshotCodec.encode(snapshot)
        let previousStatus = session.lifecycleStatusRaw
        let previousSnapshot = session.billSnapshotData

        session.billSnapshotData = encoded
        session.lifecycleStatusRaw = "completed"
        do {
            try saveAction(context)
            return snapshot
        } catch {
            session.lifecycleStatusRaw = previousStatus
            session.billSnapshotData = previousSnapshot
            throw SessionStoreError.saveFailed(error.localizedDescription)
        }
    }

    /// Persists a refreshed exchange-rate quote as one logical update. If the
    /// save fails, only the five quote fields touched here are restored; other
    /// pending edits in the shared UI context remain intact.
    func updateFXRate(_ rate: FXRate, for session: MenuSession) throws {
        let previousRate = session.fxRate
        let previousRateDate = session.fxRateDate
        let previousSource = session.fxSource
        let previousQuoteDate = session.fxQuoteDate
        let previousFetchedAt = session.fxFetchedAt

        session.fxRate = rate.rate
        session.fxRateDate = rate.date
        session.fxSource = rate.source.persistedValue
        session.fxQuoteDate = rate.quoteDate
        session.fxFetchedAt = rate.fetchedAt

        do {
            try saveAction(context)
        } catch {
            session.fxRate = previousRate
            session.fxRateDate = previousRateDate
            session.fxSource = previousSource
            session.fxQuoteDate = previousQuoteDate
            session.fxFetchedAt = previousFetchedAt
            throw SessionStoreError.fxSaveFailed(error.localizedDescription)
        }
    }

    /// Deletes one saved session through the same all-or-nothing path used for bulk deletion.
    func delete(_ session: MenuSession) throws {
        try delete([session])
    }

    /// Deletes the requested sessions as one isolated persistence operation and leaves an empty request unchanged.
    func delete(_ sessions: [MenuSession]) throws {
        guard !sessions.isEmpty else { return }
        do {
            try persistDeletion(of: sessions)
        } catch {
            throw SessionStoreError.deleteFailed(error.localizedDescription)
        }
    }

    /// Fetches and deletes all sessions, returning the count only after the deletion is saved successfully.
    @discardableResult
    func deleteAll() throws -> Int {
        let sessions: [MenuSession]
        do {
            sessions = try fetchAllAction(context)
        } catch {
            throw SessionStoreError.fetchFailed(error.localizedDescription)
        }
        guard !sessions.isEmpty else { return 0 }

        do {
            try persistDeletion(of: sessions)
            return sessions.count
        } catch {
            throw SessionStoreError.deleteFailed(error.localizedDescription)
        }
    }

    /// Deletes in a short-lived context. If fetching or saving fails, that
    /// context is discarded and the UI's context was never mutated, avoiding
    /// SwiftData's unsafe cascade-delete rollback path for faulted children.
    private func persistDeletion(of sessions: [MenuSession]) throws {
        let targetIDs = Set(sessions.map(\.id))
        let deletionContext = ModelContext(context.container)
        deletionContext.autosaveEnabled = false
        let persistedSessions = try deletionContext.fetch(FetchDescriptor<MenuSession>())
        let targets = persistedSessions.filter { targetIDs.contains($0.id) }
        guard targets.count == targetIDs.count else {
            throw SessionStoreError.sessionsNotPersisted
        }
        for session in targets {
            deletionContext.delete(session)
        }
        try saveAction(deletionContext)
    }
}

/// Persistence failures grouped by the user operation that could not be completed.
enum SessionStoreError: Error, LocalizedError, Equatable {
    case completedSessionMissingSnapshot
    case sessionsNotPersisted
    case saveFailed(String)
    case fxSaveFailed(String)
    case fetchFailed(String)
    case deleteFailed(String)

    /// Provides localized explanations that describe what was preserved and whether the user can retry.
    var errorDescription: String? {
        switch self {
        case .completedSessionMissingSnapshot:
            return L10n.string("已完成帳單缺少可讀取嘅快照，記錄未有再被修改。")
        case .sessionsNotPersisted:
            return L10n.string("部分菜單記錄未完成儲存，今次未有刪除任何記錄。")
        case .saveFailed(let detail):
            return L10n.string("未能儲存帳單，請再試一次。（%@）", detail)
        case .fxSaveFailed:
            return L10n.string("最新匯率未能儲存，請稍後再試。")
        case .fetchFailed(let detail):
            return L10n.string("未能讀取菜單記錄，請再試一次。（%@）", detail)
        case .deleteFailed(let detail):
            return L10n.string("未能刪除菜單記錄，原有記錄已保留。（%@）", detail)
        }
    }
}
