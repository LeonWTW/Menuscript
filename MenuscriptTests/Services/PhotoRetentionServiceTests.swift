// Verifies photo pruning deletes only what the retention policy allows: old
// completed sessions lose their original photos, and everything else — drafts,
// recent visits, and every finalized bill — survives untouched.

import Foundation
import SwiftData
import Testing
@testable import Menuscript

/// Protects menu history from an over-broad cleanup. These tests pin the two
/// fields pruning may write, the sessions it must refuse to touch, the
/// inclusive age boundary, and the guarantee that a failed save leaves every
/// original photo in place.
@MainActor
@Suite("PhotoRetentionService pruning")
struct PhotoRetentionServiceTests {
    /// Predictable test-only failures injected at fetch or save boundaries so
    /// failure behavior can be exercised without breaking a real database.
    private enum InjectedFailure: Error, LocalizedError {
        case fetch
        case save

        /// Gives each simulated failure stable text for checking the service's error mapping.
        var errorDescription: String? {
            switch self {
            case .fetch: "injected fetch failure"
            case .save: "injected save failure"
            }
        }
    }

    /// A fixed clock so every age comparison in these tests is exact rather than
    /// relative to when the suite happens to run.
    private let now = Date(timeIntervalSince1970: 1_755_302_400)
    private let corruptBillPayload = Data("{\"v\":1}".utf8)
    private let photos = [Data([0x01]), Data([0x02])]

    /// Creates the same payload the production finalization path stores: a
    /// versioned, encoded snapshot from an order with a selected item.
    private func validBillPayload() throws -> Data {
        let session = MenuSession(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            detectedLanguage: "日文",
            targetLanguage: "繁體中文",
            menuCurrency: "JPY",
            homeCurrency: "HKD",
            fxRate: 0.05,
            fxRateDate: Date(timeIntervalSince1970: 1_700_086_400),
            fxSource: "fixture",
            fxQuoteDate: "2023-11-15",
            fxFetchedAt: Date(timeIntervalSince1970: 1_700_086_400),
            providerModeRaw: RuntimeMode.mock.rawValue,
            peopleCount: 2,
            surchargePercent: 10
        )
        session.items = [
            MenuItem(
                originalName: "Fixture dish",
                translatedName: "測試菜式",
                priceValue: 100,
                category: "Fixture",
                quantity: 1,
                sortOrder: 0
            )
        ]

        let snapshot = try BillSnapshot.capture(
            from: session,
            completedAt: Date(timeIntervalSince1970: 1_700_172_800)
        )
        return try BillSnapshotCodec.encode(snapshot)
    }

    /// Creates a syntactically valid future snapshot that the current codec
    /// intentionally rejects before decoding its complete bill shape.
    private func unsupportedBillPayload() throws -> Data {
        var object = try #require(
            JSONSerialization.jsonObject(with: validBillPayload()) as? [String: Any]
        )
        object["version"] = BillSnapshot.currentVersion + 1
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Creates an isolated in-memory database so pruning results can be counted
    /// without touching real user history.
    private func makeContext() throws -> ModelContext {
        let configuration = ModelConfiguration(
            schema: AppSchema.current,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: AppSchema.current,
            configurations: [configuration]
        )
        return ModelContext(container)
    }

    /// Inserts one complete session, including a dish and an exchange rate, so
    /// every test can assert that pruning left the rest of the record alone.
    @discardableResult
    private func makeSession(
        in context: ModelContext,
        createdAt: Date,
        lifecycleStatusRaw: String?,
        billSnapshotData: Data?,
        photos: [Data]
    ) -> MenuSession {
        let session = MenuSession(
            createdAt: createdAt,
            title: "Session",
            detectedLanguage: "日文",
            targetLanguage: "繁體中文",
            menuCurrency: "JPY",
            homeCurrency: "HKD",
            fxRate: 0.05,
            photos: photos,
            peopleCount: 2,
            lifecycleStatusRaw: lifecycleStatusRaw,
            billSnapshotData: billSnapshotData
        )
        session.items = [
            MenuItem(
                originalName: "Dish",
                translatedName: "菜",
                priceValue: 100,
                category: "測試",
                quantity: 1,
                sortOrder: 0
            )
        ]
        context.insert(session)
        return session
    }

    /// Reads persisted state through a separate context, so assertions describe
    /// what is actually stored rather than what one context holds in memory.
    private func persistedSessions(in context: ModelContext) throws -> [MenuSession] {
        try ModelContext(context.container).fetch(FetchDescriptor<MenuSession>())
    }

    @Test("A completed session past the window loses its photos and is stamped")
    /// Confirms the ordinary case: an old finalized visit gives back its storage.
    func prunesExpiredCompletedSession() throws {
        let context = try makeContext()
        let session = makeSession(
            in: context,
            createdAt: now.addingTimeInterval(-40 * 86_400),
            lifecycleStatusRaw: "completed",
            billSnapshotData: try validBillPayload(),
            photos: photos
        )
        try context.save()
        var saveCount = 0
        let service = PhotoRetentionService(
            context: context,
            saveAction: { context in
                saveCount += 1
                try context.save()
            }
        )

        let prunedCount = try service.pruneExpiredPhotos(policy: .days30, now: now)

        #expect(prunedCount == 1)
        #expect(saveCount == 1)
        #expect(context.hasChanges == false)

        let persisted = try #require(persistedSessions(in: context).first { $0.id == session.id })
        #expect(persisted.photos.isEmpty)
        #expect(persisted.photosPrunedAt == now)
    }

    @Test("Pruning preserves the completed bill, its dishes, and session metadata")
    /// Confirms the deletion stays bounded to photos: the settled bill is the
    /// record the user keeps, so nothing else may change.
    func pruningPreservesBillAndMetadata() throws {
        let context = try makeContext()
        let createdAt = now.addingTimeInterval(-40 * 86_400)
        let billPayload = try validBillPayload()
        let session = makeSession(
            in: context,
            createdAt: createdAt,
            lifecycleStatusRaw: "completed",
            billSnapshotData: billPayload,
            photos: photos
        )
        try context.save()
        let service = PhotoRetentionService(context: context)

        #expect(try service.pruneExpiredPhotos(policy: .days30, now: now) == 1)

        let persisted = try #require(persistedSessions(in: context).first { $0.id == session.id })
        #expect(persisted.billSnapshotData == billPayload)
        #expect(persisted.items.count == 1)
        let item = try #require(persisted.items.first)
        #expect(item.originalName == "Dish")
        #expect(item.translatedName == "菜")
        #expect(item.priceValue == 100)
        #expect(item.category == "測試")
        #expect(item.quantity == 1)
        #expect(item.sortOrder == 0)
        #expect(persisted.title == "Session")
        #expect(persisted.peopleCount == 2)
        #expect(persisted.fxRate == 0.05)
        #expect(persisted.createdAt == createdAt)
        #expect(persisted.lifecycleStatusRaw == "completed")
    }

    @Test("A completed session inside the window keeps its photos")
    /// Confirms a recent visit stays re-checkable and triggers no write at all.
    func keepsSessionInsideWindow() throws {
        let context = try makeContext()
        let session = makeSession(
            in: context,
            createdAt: now.addingTimeInterval(-29 * 86_400),
            lifecycleStatusRaw: "completed",
            billSnapshotData: try validBillPayload(),
            photos: photos
        )
        try context.save()
        var saveCount = 0
        let service = PhotoRetentionService(
            context: context,
            saveAction: { context in
                saveCount += 1
                try context.save()
            }
        )

        #expect(try service.pruneExpiredPhotos(policy: .days30, now: now) == 0)
        #expect(saveCount == 0)

        let persisted = try #require(persistedSessions(in: context).first { $0.id == session.id })
        #expect(persisted.photos.count == 2)
        #expect(persisted.photosPrunedAt == nil)
    }

    @Test("Drafts, legacy sessions, and snapshotless sessions are never pruned")
    /// Confirms photos are kept wherever they are the only record of the meal,
    /// no matter how old the session is.
    func protectsUnfinalizedSessions() throws {
        let context = try makeContext()
        let ancient = now.addingTimeInterval(-400 * 86_400)
        let draft = makeSession(
            in: context,
            createdAt: ancient,
            lifecycleStatusRaw: "draft",
            billSnapshotData: nil,
            photos: photos
        )
        let legacy = makeSession(
            in: context,
            createdAt: ancient,
            lifecycleStatusRaw: nil,
            billSnapshotData: nil,
            photos: photos
        )
        let snapshotlessCompleted = makeSession(
            in: context,
            createdAt: ancient,
            lifecycleStatusRaw: "completed",
            billSnapshotData: nil,
            photos: photos
        )
        try context.save()
        var saveCount = 0
        let service = PhotoRetentionService(
            context: context,
            saveAction: { context in
                saveCount += 1
                try context.save()
            }
        )

        #expect(try service.pruneExpiredPhotos(policy: .days30, now: now) == 0)
        #expect(saveCount == 0)

        let persisted = try persistedSessions(in: context)
        #expect(persisted.count == 3)
        for session in [draft, legacy, snapshotlessCompleted] {
            let persistedSession = try #require(persisted.first { $0.id == session.id })
            #expect(persistedSession.photos.count == 2)
            #expect(persistedSession.photosPrunedAt == nil)
        }
    }

    @Test("Keep forever performs no database work at all")
    /// Confirms the opt-out is honored before anything is read or written.
    func keepForeverDoesNothing() throws {
        let context = try makeContext()
        let session = makeSession(
            in: context,
            createdAt: now.addingTimeInterval(-400 * 86_400),
            lifecycleStatusRaw: "completed",
            billSnapshotData: try validBillPayload(),
            photos: photos
        )
        try context.save()
        var fetchCount = 0
        var saveCount = 0
        let service = PhotoRetentionService(
            context: context,
            saveAction: { context in
                saveCount += 1
                try context.save()
            },
            fetchAllAction: { context in
                fetchCount += 1
                return try context.fetch(FetchDescriptor<MenuSession>())
            }
        )

        #expect(try service.pruneExpiredPhotos(policy: .forever, now: now) == 0)
        #expect(fetchCount == 0)
        #expect(saveCount == 0)

        let persisted = try #require(persistedSessions(in: context).first { $0.id == session.id })
        #expect(persisted.photos.count == 2)
    }

    @Test("The age boundary is inclusive to the second")
    /// Confirms a session exactly one window old is pruned while one second
    /// younger is kept, so the documented threshold is unambiguous.
    func ageBoundaryIsInclusive() throws {
        let context = try makeContext()
        let exactlyExpiredAt = now.addingTimeInterval(-2_592_000)
        let oneSecondYoungerAt = now.addingTimeInterval(-2_592_000 + 1)
        let expiredSession = makeSession(
            in: context,
            createdAt: exactlyExpiredAt,
            lifecycleStatusRaw: "completed",
            billSnapshotData: try validBillPayload(),
            photos: photos
        )
        let keptSession = makeSession(
            in: context,
            createdAt: oneSecondYoungerAt,
            lifecycleStatusRaw: "completed",
            billSnapshotData: try validBillPayload(),
            photos: photos
        )
        try context.save()
        let service = PhotoRetentionService(context: context)

        #expect(try service.pruneExpiredPhotos(policy: .days30, now: now) == 1)

        let persisted = try persistedSessions(in: context)
        let expired = try #require(persisted.first { $0.id == expiredSession.id })
        let kept = try #require(persisted.first { $0.id == keptSession.id })
        #expect(expired.photos.isEmpty)
        #expect(expired.photosPrunedAt == now)
        #expect(kept.photos.count == 2)
        #expect(kept.photosPrunedAt == nil)
    }

    @Test("A session that never had photos is left unstamped")
    /// Confirms the stamp means "photos were removed", so the Menu screen never
    /// claims a cleanup that did not happen.
    func doesNotStampSessionsWithoutPhotos() throws {
        let context = try makeContext()
        let session = makeSession(
            in: context,
            createdAt: now.addingTimeInterval(-400 * 86_400),
            lifecycleStatusRaw: "completed",
            billSnapshotData: try validBillPayload(),
            photos: []
        )
        try context.save()
        var saveCount = 0
        let service = PhotoRetentionService(
            context: context,
            saveAction: { context in
                saveCount += 1
                try context.save()
            }
        )

        #expect(try service.pruneExpiredPhotos(policy: .days30, now: now) == 0)
        #expect(saveCount == 0)

        let persisted = try #require(persistedSessions(in: context).first { $0.id == session.id })
        #expect(persisted.photosPrunedAt == nil)
    }

    @Test("Running again prunes nothing and keeps the original stamp")
    /// Confirms launch-time pruning is idempotent: repeated runs never rewrite
    /// history or report work they did not do.
    func pruningIsIdempotent() throws {
        let context = try makeContext()
        let session = makeSession(
            in: context,
            createdAt: now.addingTimeInterval(-40 * 86_400),
            lifecycleStatusRaw: "completed",
            billSnapshotData: try validBillPayload(),
            photos: photos
        )
        try context.save()
        var saveCount = 0
        let service = PhotoRetentionService(
            context: context,
            saveAction: { context in
                saveCount += 1
                try context.save()
            }
        )

        #expect(try service.pruneExpiredPhotos(policy: .days30, now: now) == 1)
        #expect(try service.pruneExpiredPhotos(policy: .days30, now: now.addingTimeInterval(3_600)) == 0)
        #expect(saveCount == 1)

        let persisted = try #require(persistedSessions(in: context).first { $0.id == session.id })
        #expect(persisted.photosPrunedAt == now)
    }

    @Test("A corrupt completed snapshot keeps its original photos and causes no save")
    /// Confirms malformed bytes never make an otherwise expired session
    /// unrecoverable by deleting its only remaining source record.
    func corruptSnapshotKeepsPhotosWithoutSaving() throws {
        let context = try makeContext()
        let createdAt = now.addingTimeInterval(-40 * 86_400)
        let session = makeSession(
            in: context,
            createdAt: createdAt,
            lifecycleStatusRaw: "completed",
            billSnapshotData: corruptBillPayload,
            photos: photos
        )
        try context.save()
        var saveCount = 0
        let service = PhotoRetentionService(
            context: context,
            saveAction: { context in
                saveCount += 1
                try context.save()
            }
        )

        #expect(try service.pruneExpiredPhotos(policy: .days30, now: now) == 0)
        #expect(saveCount == 0)
        #expect(context.hasChanges == false)

        let persisted = try #require(persistedSessions(in: context).first { $0.id == session.id })
        #expect(persisted.photos == photos)
        #expect(persisted.photosPrunedAt == nil)
        #expect(persisted.billSnapshotData == corruptBillPayload)
        #expect(persisted.createdAt == createdAt)
        #expect(persisted.lifecycleStatusRaw == "completed")
        #expect(persisted.title == "Session")
        #expect(persisted.peopleCount == 2)
        #expect(persisted.items.count == 1)
    }

    @Test("An unsupported completed snapshot keeps its original photos and causes no save")
    /// Confirms a bill written by a future app version remains protected rather
    /// than being mistaken for a recoverable completed record.
    func unsupportedSnapshotKeepsPhotosWithoutSaving() throws {
        let context = try makeContext()
        let createdAt = now.addingTimeInterval(-40 * 86_400)
        let unsupportedPayload = try unsupportedBillPayload()
        let session = makeSession(
            in: context,
            createdAt: createdAt,
            lifecycleStatusRaw: "completed",
            billSnapshotData: unsupportedPayload,
            photos: photos
        )
        try context.save()
        var saveCount = 0
        let service = PhotoRetentionService(
            context: context,
            saveAction: { context in
                saveCount += 1
                try context.save()
            }
        )

        #expect(try service.pruneExpiredPhotos(policy: .days30, now: now) == 0)
        #expect(saveCount == 0)
        #expect(context.hasChanges == false)

        let persisted = try #require(persistedSessions(in: context).first { $0.id == session.id })
        #expect(persisted.photos == photos)
        #expect(persisted.photosPrunedAt == nil)
        #expect(persisted.billSnapshotData == unsupportedPayload)
        #expect(persisted.createdAt == createdAt)
        #expect(persisted.lifecycleStatusRaw == "completed")
        #expect(persisted.title == "Session")
        #expect(persisted.peopleCount == 2)
        #expect(persisted.items.count == 1)
    }

    @Test("A mixed batch prunes only the session with a readable completed bill")
    /// Confirms invalid records stay unchanged while eligible records are still
    /// pruned in the same single persistence write.
    func mixedValidAndCorruptSnapshotsPruneOnlyValidSession() throws {
        let context = try makeContext()
        let createdAt = now.addingTimeInterval(-40 * 86_400)
        let validPayload = try validBillPayload()
        let validSession = makeSession(
            in: context,
            createdAt: createdAt,
            lifecycleStatusRaw: "completed",
            billSnapshotData: validPayload,
            photos: photos
        )
        let corruptSession = makeSession(
            in: context,
            createdAt: createdAt,
            lifecycleStatusRaw: "completed",
            billSnapshotData: corruptBillPayload,
            photos: photos
        )
        try context.save()
        var saveCount = 0
        let service = PhotoRetentionService(
            context: context,
            saveAction: { context in
                saveCount += 1
                try context.save()
            }
        )

        #expect(try service.pruneExpiredPhotos(policy: .days30, now: now) == 1)
        #expect(saveCount == 1)
        #expect(context.hasChanges == false)

        let persisted = try persistedSessions(in: context)
        let valid = try #require(persisted.first { $0.id == validSession.id })
        let corrupt = try #require(persisted.first { $0.id == corruptSession.id })
        #expect(valid.photos.isEmpty)
        #expect(valid.photosPrunedAt == now)
        #expect(valid.billSnapshotData == validPayload)
        #expect(corrupt.photos == photos)
        #expect(corrupt.photosPrunedAt == nil)
        #expect(corrupt.billSnapshotData == corruptBillPayload)
        #expect(corrupt.createdAt == createdAt)
        #expect(corrupt.lifecycleStatusRaw == "completed")
        #expect(corrupt.title == "Session")
        #expect(corrupt.peopleCount == 2)
        #expect(corrupt.items.count == 1)
    }

    @Test("An all-invalid batch keeps every original photo and causes no save")
    /// Confirms the early return remains write-free when no expired record has
    /// a currently readable completed bill.
    func allInvalidSnapshotsKeepPhotosWithoutSaving() throws {
        let context = try makeContext()
        let createdAt = now.addingTimeInterval(-40 * 86_400)
        let unsupportedPayload = try unsupportedBillPayload()
        let corruptSession = makeSession(
            in: context,
            createdAt: createdAt,
            lifecycleStatusRaw: "completed",
            billSnapshotData: corruptBillPayload,
            photos: photos
        )
        let unsupportedSession = makeSession(
            in: context,
            createdAt: createdAt,
            lifecycleStatusRaw: "completed",
            billSnapshotData: unsupportedPayload,
            photos: photos
        )
        try context.save()
        var saveCount = 0
        let service = PhotoRetentionService(
            context: context,
            saveAction: { context in
                saveCount += 1
                try context.save()
            }
        )

        #expect(try service.pruneExpiredPhotos(policy: .days30, now: now) == 0)
        #expect(saveCount == 0)
        #expect(context.hasChanges == false)

        let persisted = try persistedSessions(in: context)
        let corrupt = try #require(persisted.first { $0.id == corruptSession.id })
        let unsupported = try #require(persisted.first { $0.id == unsupportedSession.id })
        #expect(corrupt.photos == photos)
        #expect(corrupt.photosPrunedAt == nil)
        #expect(corrupt.billSnapshotData == corruptBillPayload)
        #expect(corrupt.createdAt == createdAt)
        #expect(corrupt.lifecycleStatusRaw == "completed")
        #expect(unsupported.photos == photos)
        #expect(unsupported.photosPrunedAt == nil)
        #expect(unsupported.billSnapshotData == unsupportedPayload)
        #expect(unsupported.createdAt == createdAt)
        #expect(unsupported.lifecycleStatusRaw == "completed")
    }

    @Test("An empty history saves nothing")
    /// Confirms a first launch with no records performs no write.
    func emptyStoreSavesNothing() throws {
        let context = try makeContext()
        var saveCount = 0
        let service = PhotoRetentionService(
            context: context,
            saveAction: { context in
                saveCount += 1
                try context.save()
            }
        )

        #expect(try service.pruneExpiredPhotos(policy: .days30, now: now) == 0)
        #expect(saveCount == 0)
    }

    @Test("A failed save keeps every original photo")
    /// Confirms the discarded private context is the rollback: a storage failure
    /// can never leave photos half-deleted.
    func failedSaveKeepsPhotos() throws {
        let context = try makeContext()
        let billPayload = try validBillPayload()
        let session = makeSession(
            in: context,
            createdAt: now.addingTimeInterval(-40 * 86_400),
            lifecycleStatusRaw: "completed",
            billSnapshotData: billPayload,
            photos: photos
        )
        try context.save()
        let service = PhotoRetentionService(
            context: context,
            saveAction: { _ in throw InjectedFailure.save }
        )

        do {
            _ = try service.pruneExpiredPhotos(policy: .days30, now: now)
            Issue.record("Expected pruning to fail")
        } catch let error as PhotoRetentionError {
            #expect(error == .saveFailed("injected save failure"))
        }

        #expect(session.photos.count == 2)
        #expect(session.photosPrunedAt == nil)

        let persisted = try #require(persistedSessions(in: context).first { $0.id == session.id })
        #expect(persisted.photos.count == 2)
        #expect(persisted.photosPrunedAt == nil)
        #expect(persisted.billSnapshotData == billPayload)
    }

    @Test("A failed fetch reports the failure and touches nothing")
    /// Confirms an unreadable history is an error the user sees, not a silent
    /// cleanup of whatever happened to load.
    func failedFetchKeepsPhotos() throws {
        let context = try makeContext()
        let session = makeSession(
            in: context,
            createdAt: now.addingTimeInterval(-40 * 86_400),
            lifecycleStatusRaw: "completed",
            billSnapshotData: try validBillPayload(),
            photos: photos
        )
        try context.save()
        let service = PhotoRetentionService(
            context: context,
            fetchAllAction: { _ in throw InjectedFailure.fetch }
        )

        do {
            _ = try service.pruneExpiredPhotos(policy: .days30, now: now)
            Issue.record("Expected pruning to fail")
        } catch let error as PhotoRetentionError {
            #expect(error == .fetchFailed("injected fetch failure"))
        }

        let persisted = try #require(persistedSessions(in: context).first { $0.id == session.id })
        #expect(persisted.photos.count == 2)
        #expect(persisted.photosPrunedAt == nil)
    }
}
