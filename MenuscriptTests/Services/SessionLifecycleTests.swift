// Verifies how editable menu sessions become immutable completed bills, including
// migration fallbacks, calculation capture, repeated finalization, and failures.

import Foundation
import SwiftData
import Testing
@testable import Menuscript

/// Protects the lifecycle contract that only a successfully saved, non-empty
/// order becomes completed and that its captured receipt never changes afterward.
@MainActor
@Suite("Session lifecycle and bill snapshots")
struct SessionLifecycleTests {
    /// A predictable test-only error used to simulate a database save failure
    /// without damaging or depending on real persistent storage.
    private enum InjectedFailure: Error, LocalizedError {
        case save

        /// Supplies stable text so the test can verify the user-facing error wrapper.
        var errorDescription: String? { "injected save failure" }
    }

    /// Creates a fresh in-memory database, isolating each scenario from real menu history.
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

    /// Builds a realistic draft containing priced, market-price, and unselected
    /// dishes so one sample order exercises the important snapshot rules together.
    private func makeOrder() -> MenuSession {
        let session = MenuSession(
            title: "Final dinner",
            detectedLanguage: "日文",
            targetLanguage: "繁體中文",
            menuCurrency: "JPY",
            homeCurrency: "HKD",
            fxRate: 0.05,
            fxRateDate: Date(timeIntervalSince1970: 1_725_062_400),
            fxSource: "frankfurter",
            fxQuoteDate: "2024-08-31",
            fxFetchedAt: Date(timeIntervalSince1970: 1_725_066_000),
            providerModeRaw: RuntimeMode.live.rawValue,
            peopleCount: 3,
            surchargePercent: 10
        )
        session.items = [
            MenuItem(
                originalName: "寿司",
                translatedName: "壽司",
                priceValue: 1_000,
                category: "主菜",
                quantity: 2,
                sortOrder: 0
            ),
            MenuItem(
                originalName: "本日鮮魚",
                translatedName: "是日鮮魚",
                priceNote: "時價",
                category: "主菜",
                quantity: 1,
                sortOrder: 1
            ),
            MenuItem(
                originalName: "茶",
                translatedName: "茶",
                priceValue: 300,
                category: "飲品",
                quantity: 0,
                sortOrder: 2
            )
        ]
        return session
    }

    /// Ensures new drafts and older or unknown stored values remain unfinished;
    /// this prevents an app update from falsely presenting an editable order as final.
    @Test("New, legacy, and unknown lifecycle values stay distinguishable")
    func lifecycleDefaultsAndLegacyFallback() {
        let draft = makeOrder()
        #expect(draft.lifecycleStatus == .draft)
        #expect(draft.isCompleted == false)

        let legacy = MenuSession(
            detectedLanguage: "日文",
            targetLanguage: "繁體中文",
            menuCurrency: "JPY",
            homeCurrency: "HKD",
            lifecycleStatusRaw: nil
        )
        #expect(legacy.lifecycleStatus == .legacyUnfinalized)
        #expect(legacy.isCompleted == false)

        legacy.lifecycleStatusRaw = "future-state"
        #expect(legacy.lifecycleStatus == .legacyUnfinalized)
    }

    /// Verifies finalization freezes every displayed value, keeps selected unpriced
    /// dishes visible, excludes their unknown price from totals, and omits unselected dishes.
    @Test("Finalizing captures every displayed value and excludes unpriced lines from totals")
    func draftToCompletedSnapshot() throws {
        let context = try makeContext()
        let session = makeOrder()
        context.insert(session)
        try context.save()
        let completedAt = Date(timeIntervalSince1970: 1_725_148_800)

        let snapshot = try SessionStore(context: context).finalize(
            session,
            completedAt: completedAt
        )

        #expect(session.lifecycleStatus == .completed)
        #expect(session.billSnapshot == snapshot)
        #expect(snapshot.version == BillSnapshot.currentVersion)
        #expect(snapshot.lines.count == 2)
        #expect(snapshot.lines.map(\.translatedName) == ["壽司", "是日鮮魚"])
        #expect(snapshot.lines[0].unitPrice == Decimal(1_000))
        #expect(snapshot.lines[0].quantity == 2)
        #expect(snapshot.lines[1].unitPrice == nil)
        #expect(snapshot.lines[1].priceNote == "時價")
        #expect(snapshot.hasUnpricedItems)
        #expect(snapshot.subtotal == Decimal(2_000))
        #expect(snapshot.surchargeAmount == Decimal(200))
        #expect(snapshot.total == Decimal(2_200))
        #expect(snapshot.peopleCount == 3)
        #expect(snapshot.perPersonOriginal == Decimal(734))
        #expect(snapshot.menuCurrency == "JPY")
        #expect(snapshot.homeCurrency == "HKD")
        #expect(snapshot.fxRate == 0.05)
        #expect(snapshot.fxRateDate == session.fxRateDate)
        #expect(snapshot.fxSource == "frankfurter")
        #expect(snapshot.fxQuoteDate == "2024-08-31")
        #expect(snapshot.fxFetchedAt == session.fxFetchedAt)
        #expect(snapshot.providerModeRaw == RuntimeMode.live.rawValue)
        #expect(snapshot.convertedSubtotal == Decimal(100))
        #expect(snapshot.convertedSurchargeAmount == Decimal(10))
        #expect(snapshot.convertedTotal == Decimal(110))
        #expect(snapshot.perPersonConverted == Decimal(string: "36.67"))
        #expect(snapshot.completedAt == completedAt)
    }

    /// Ensures tapping Finish more than once neither saves again nor rewrites the
    /// original receipt with later edits, preserving a trustworthy completed bill.
    @Test("Finalizing twice is idempotent and later model edits cannot change the snapshot")
    func finalizeIsIdempotentAndImmutable() throws {
        let context = try makeContext()
        let session = makeOrder()
        context.insert(session)
        try context.save()
        var saveCount = 0
        let store = SessionStore(
            context: context,
            saveAction: { context in
                saveCount += 1
                try context.save()
            }
        )

        let first = try store.finalize(
            session,
            completedAt: Date(timeIntervalSince1970: 10)
        )
        session.items[0].quantity = 99
        session.items[0].priceValue = 9_999
        session.surchargePercent = 30
        session.peopleCount = 20
        session.fxRate = 9
        session.menuCurrency = "USD"

        let second = try store.finalize(
            session,
            completedAt: Date(timeIntervalSince1970: 20)
        )

        #expect(saveCount == 1)
        #expect(second == first)
        #expect(session.billSnapshot == first)
        #expect(first.lines[0].quantity == 2)
        #expect(first.lines[0].unitPrice == Decimal(1_000))
        #expect(first.surchargePercent == 10)
        #expect(first.peopleCount == 3)
        #expect(first.fxRate == 0.05)
        #expect(first.menuCurrency == "JPY")
        #expect(first.completedAt == Date(timeIntervalSince1970: 10))
    }

    /// Simulates a failed database save and verifies the session returns fully to
    /// draft state instead of showing a completed bill that was never persisted.
    @Test("A failed finalize save restores draft status and snapshot bytes")
    func finalizeSaveFailureRollsBackLifecycle() throws {
        let context = try makeContext()
        let session = makeOrder()
        context.insert(session)
        try context.save()
        let store = SessionStore(
            context: context,
            saveAction: { _ in throw InjectedFailure.save }
        )

        do {
            _ = try store.finalize(session)
            Issue.record("Expected finalization to fail")
        } catch let error as SessionStoreError {
            #expect(error == .saveFailed("injected save failure"))
        }

        #expect(session.lifecycleStatus == .draft)
        #expect(session.lifecycleStatusRaw == "draft")
        #expect(session.billSnapshotData == nil)
        #expect(session.billSnapshot == nil)
    }

    /// Prevents an order with no selected dishes from being marked completed,
    /// which would otherwise create an empty and misleading receipt.
    @Test("An empty order cannot be marked completed")
    func emptyOrderDoesNotFinalize() throws {
        let context = try makeContext()
        let session = MenuSession(
            detectedLanguage: "日文",
            targetLanguage: "繁體中文",
            menuCurrency: "JPY",
            homeCurrency: "HKD"
        )
        context.insert(session)
        try context.save()

        do {
            _ = try SessionStore(context: context).finalize(session)
            Issue.record("Expected an empty order to fail")
        } catch let error as BillSnapshotError {
            #expect(error == .emptyOrder)
        }
        #expect(session.lifecycleStatus == .draft)
    }
}
