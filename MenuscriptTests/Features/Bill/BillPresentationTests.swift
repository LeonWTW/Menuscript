// Verifies that completed bills, menu cards, and follow-up actions always use
// the frozen bill snapshot instead of later edits to the live menu session.

import Foundation
import SwiftData
import Testing
@testable import Menuscript

/// Records the exact dish and languages sent to the explanation provider so
/// tests can prove completed-order actions use the values the user finalized.
private struct ActionExplainInvocation: Equatable, Sendable {
    let original: String
    let detectedLanguage: String
    let targetLanguage: String
}

/// A test-only vision provider that records explanation requests without using
/// the network. The actor keeps overlapping asynchronous calls from corrupting the record.
private actor ActionRecordingVisionProvider: MenuVisionProvider {
    private var storedInvocation: ActionExplainInvocation?

    /// Fails immediately because these tests must never enter menu extraction;
    /// doing so would reveal that the action was routed through the wrong path.
    func extractMenu(
        images: [Data],
        targetLanguage: String,
        allergens: [String]
    ) async throws -> ExtractedMenu {
        fatalError("Action-context tests never extract a menu")
    }

    /// Captures the explanation request and returns a predictable result for assertions.
    func explainDish(
        original: String,
        language: String,
        targetLanguage: String
    ) async throws -> String {
        storedInvocation = ActionExplainInvocation(
            original: original,
            detectedLanguage: language,
            targetLanguage: targetLanguage
        )
        return "Frozen explanation"
    }

    /// Returns the recorded request so the test can compare every input value.
    func invocation() -> ActionExplainInvocation? {
        storedInvocation
    }
}

/// A credential-free secret store proving mock explanation actions work without
/// supplying or saving a real API key.
private struct ActionContextSecretStore: SecretStore {
    /// Behaves as though no secret has ever been saved.
    func read(_ key: String) throws -> String? { nil }

    /// Accepts writes as a no-op because credential persistence is outside these tests.
    func set(_ value: String, forKey key: String) throws {}

    /// Accepts deletion as a no-op because the store contains no credentials.
    func delete(_ key: String) throws {}
}

/// Protects the read-only presentation contract for finalized bills and their actions.
@MainActor
@Suite("Snapshot-backed bill presentation")
struct BillPresentationTests {
    /// Creates a fresh in-memory database so each test is isolated and cannot
    /// read or change a person's real saved menus.
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

    /// Creates an isolated preference domain with a chosen provider mode and
    /// returns its name so the caller can remove it after the test.
    private func makeDefaults(useMock: Bool) throws -> (UserDefaults, String) {
        let suiteName = "BillPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(useMock, forKey: SettingsKeys.useMockProvider)
        return (defaults, suiteName)
    }

    /// Builds a representative editable order with one selected dish and optional
    /// exchange-rate/provider details shared by presentation scenarios.
    private func makeOrder(
        fxRate: Double? = nil,
        providerMode: RuntimeMode? = nil
    ) -> MenuSession {
        let session = MenuSession(
            detectedLanguage: "Japanese",
            targetLanguage: "English",
            menuCurrency: "JPY",
            homeCurrency: "USD",
            fxRate: fxRate,
            fxRateDate: fxRate.map { _ in Date(timeIntervalSince1970: 1_752_556_800) },
            fxSource: fxRate.map { _ in "frankfurter" },
            fxQuoteDate: fxRate.map { _ in "2025-07-15" },
            fxFetchedAt: fxRate.map { _ in Date(timeIntervalSince1970: 1_752_560_400) },
            providerModeRaw: providerMode?.rawValue,
            peopleCount: 2,
            surchargePercent: 10
        )
        session.items = [
            MenuItem(
                originalName: "凍結原名",
                translatedName: "Frozen name",
                priceValue: 1_000,
                category: "Main",
                quantity: 2,
                sortOrder: 0
            )
        ]
        return session
    }

    /// Marks a session completed with explicitly supplied snapshot bytes, allowing
    /// presentation rules to be tested independently of the persistence workflow.
    private func complete(
        _ session: MenuSession,
        snapshot: BillSnapshot
    ) throws {
        session.billSnapshotData = try BillSnapshotCodec.encode(snapshot)
        session.lifecycleStatusRaw = "completed"
    }

    /// Ensures drafts stay editable while missing, damaged, or future-version
    /// completed bills show an unavailable state rather than possibly wrong totals.
    @Test("Completed state distinguishes valid, missing, unreadable, and unsupported snapshots")
    func completedStateClassification() throws {
        let draft = makeOrder()
        #expect(draft.billState == .draft)

        let valid = makeOrder()
        let snapshot = try BillSnapshot.capture(from: valid, completedAt: .now)
        try complete(valid, snapshot: snapshot)
        #expect(valid.billState == .completed(snapshot))

        let missing = makeOrder()
        missing.lifecycleStatusRaw = "completed"
        #expect(missing.billState == .unavailable(.missing))
        #expect(BillPresentationState.resolve(for: missing) == .unavailable(.missing))
        #expect(MenuPresentationState.resolve(for: missing) == .unavailable(.missing))
        #expect(BillPresentationState.resolve(for: missing).displayModel == nil)
        #expect(MenuPresentationState.resolve(for: missing).orderPresentation == nil)

        let unreadable = makeOrder()
        unreadable.lifecycleStatusRaw = "completed"
        unreadable.billSnapshotData = Data("not-json".utf8)
        #expect(unreadable.billState == .unavailable(.unreadable))
        #expect(BillPresentationState.resolve(for: unreadable).displayModel == nil)
        #expect(MenuPresentationState.resolve(for: unreadable).orderPresentation == nil)

        var futureObject = try #require(
            JSONSerialization.jsonObject(
                with: try BillSnapshotCodec.encode(snapshot)
            ) as? [String: Any]
        )
        let futureVersion = BillSnapshot.currentVersion + 1
        futureObject["version"] = futureVersion
        let unsupported = makeOrder()
        unsupported.lifecycleStatusRaw = "completed"
        unsupported.billSnapshotData = try JSONSerialization.data(withJSONObject: futureObject)
        #expect(unsupported.billState == .unavailable(.unsupportedVersion(futureVersion)))
        #expect(BillPresentationState.resolve(for: unsupported).displayModel == nil)
        #expect(MenuPresentationState.resolve(for: unsupported).orderPresentation == nil)
    }

    /// Protects the receipt the user finalized: later live edits must not change
    /// its prices, quantities, exchange rate, totals, or selected-item cards.
    @Test("Completed optional FX and selected order cards never fall through to mutable values")
    func completedPresentationIsStrictlySnapshotBacked() throws {
        let session = makeOrder(fxRate: nil, providerMode: .mock)
        let selectedItem = try #require(session.items.first)
        let snapshot = try BillSnapshot.capture(
            from: session,
            completedAt: Date(timeIntervalSince1970: 100)
        )
        try complete(session, snapshot: snapshot)

        session.fxRate = 9
        session.fxRateDate = Date(timeIntervalSince1970: 200)
        session.fxSource = "manual"
        session.fxQuoteDate = "2099-12-31"
        selectedItem.originalName = "已被修改原名"
        selectedItem.translatedName = "Mutated name"
        selectedItem.priceValue = 9_999
        selectedItem.priceNote = "Mutated note"
        selectedItem.quantity = 99

        let bill = try #require(
            BillPresentationState.resolve(for: session).displayModel
        )
        let menu = try #require(
            MenuPresentationState.resolve(for: session).orderPresentation
        )
        let card = MenuItemCardPresentation.completed(selectedItem, snapshot: snapshot)

        #expect(bill.isReadOnly)
        #expect(bill.fxRate == nil)
        #expect(bill.fxRateDate == nil)
        #expect(bill.fxQuoteDate == nil)
        #expect(bill.fxSource == nil)
        #expect(bill.convertedTotal == nil)
        #expect(bill.perPersonConverted == nil)
        #expect(bill.lines.first?.translatedName == "Frozen name")
        #expect(bill.lines.first?.unitPrice == 1_000)
        #expect(bill.lines.first?.quantity == 2)
        #expect(menu.fxRate == nil)
        #expect(menu.convertedSubtotal == nil)
        #expect(menu.cartTotals.count == 2)
        #expect(menu.cartTotals.subtotal == 2_000)
        #expect(card.originalName == "凍結原名")
        #expect(card.translatedName == "Frozen name")
        #expect(card.unitPrice == 1_000)
        #expect(card.priceNote == nil)
        #expect(card.quantity == 2)
        #expect(card.isInCompletedOrder == true)
        #expect(BillFXPresentation.quoteDate(quoteDate: nil, legacyDate: nil) == nil)

        let unselected = MenuItem(
            originalName: "Live descriptive item",
            translatedName: "Not ordered",
            priceValue: 50,
            category: "Side",
            quantity: 7,
            sortOrder: 1
        )
        let unselectedCard = MenuItemCardPresentation.completed(
            unselected,
            snapshot: snapshot
        )
        #expect(unselectedCard.translatedName == "Not ordered")
        #expect(unselectedCard.quantity == 0)
        #expect(unselectedCard.isQuantityReadOnly)
        #expect(unselectedCard.isInCompletedOrder == false)
    }

    /// Ensures photo search and dish explanations use the finalized dish name and
    /// provider mode, even if the editable SwiftData objects later change.
    @Test("Completed card actions use frozen names and snapshot provider mode")
    func completedActionContextIsStrictlySnapshotBacked() async throws {
        let modelContext = try makeContext()
        let session = makeOrder(providerMode: .mock)
        modelContext.insert(session)
        try modelContext.save()
        let snapshot = try SessionStore(context: modelContext).finalize(
            session,
            completedAt: Date(timeIntervalSince1970: 100)
        )
        let selectedItem = try #require(session.items.first)

        selectedItem.originalName = "已被修改原名"
        selectedItem.translatedName = "Mutated name"
        session.providerModeRaw = RuntimeMode.live.rawValue

        let menu = try #require(
            MenuPresentationState.resolve(for: session).orderPresentation
        )
        let card = MenuItemCardPresentation.completed(selectedItem, snapshot: snapshot)
        let action = MenuItemActionContext.make(
            cardPresentation: card,
            lowConfidence: selectedItem.lowConfidence,
            session: session,
            snapshot: menu.snapshot
        )

        #expect(card.originalName == "凍結原名")
        #expect(card.translatedName == "Frozen name")
        #expect(action.originalName == card.originalName)
        #expect(action.translatedName == card.translatedName)
        #expect(action.photoSearchQuery == "凍結原名")
        #expect(action.providerMode == .mock)

        let (defaults, suiteName) = try makeDefaults(useMock: false)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = ActionRecordingVisionProvider()
        var resolvedMode: RuntimeMode?
        let result = try await DishExplanationService.fetchIfNeeded(
            currentExplanation: nil,
            forceRefresh: false,
            context: action,
            secretStore: ActionContextSecretStore(),
            defaults: defaults,
            liveFXFactory: { MockFXService() },
            runtimeResolver: { mode in
                resolvedMode = mode
                return RuntimeServices(
                    mode: mode,
                    visionProvider: provider,
                    fxRateProvider: MockFXService()
                )
            }
        )

        #expect(result == "Frozen explanation")
        #expect(resolvedMode == .mock)
        #expect(await provider.invocation() == ActionExplainInvocation(
            original: "凍結原名",
            detectedLanguage: "Japanese",
            targetLanguage: "English"
        ))
    }

    /// Preserves the meaning of a legacy snapshot with no provider mode: the app
    /// may use the current preference, but must not copy a later session mutation.
    @Test("Completed snapshot nil provider mode follows legacy preference, not mutated session")
    func completedActionContextPreservesMeaningfulNilMode() async throws {
        let modelContext = try makeContext()
        let session = makeOrder(providerMode: nil)
        modelContext.insert(session)
        try modelContext.save()
        let snapshot = try SessionStore(context: modelContext).finalize(
            session,
            completedAt: Date(timeIntervalSince1970: 100)
        )
        let selectedItem = try #require(session.items.first)

        selectedItem.originalName = "Mutated original"
        selectedItem.translatedName = "Mutated translation"
        session.providerModeRaw = RuntimeMode.live.rawValue

        let card = MenuItemCardPresentation.completed(selectedItem, snapshot: snapshot)
        let action = MenuItemActionContext.make(
            cardPresentation: card,
            lowConfidence: selectedItem.lowConfidence,
            session: session,
            snapshot: snapshot
        )
        #expect(action.originalName == "凍結原名")
        #expect(action.translatedName == "Frozen name")
        #expect(action.providerMode == nil)

        let (defaults, suiteName) = try makeDefaults(useMock: true)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = ActionRecordingVisionProvider()
        var resolvedMode: RuntimeMode?
        _ = try await DishExplanationService.fetchIfNeeded(
            currentExplanation: nil,
            forceRefresh: false,
            context: action,
            secretStore: ActionContextSecretStore(),
            defaults: defaults,
            liveFXFactory: { MockFXService() },
            runtimeResolver: { mode in
                resolvedMode = mode
                return RuntimeServices(
                    mode: mode,
                    visionProvider: provider,
                    fxRateProvider: MockFXService()
                )
            }
        )

        #expect(resolvedMode == .mock)
        #expect(await provider.invocation()?.original == "凍結原名")
    }

    /// Keeps existing version-one bills readable when they predate optional
    /// exchange-rate and provider metadata added by later app updates.
    @Test("Version-one JSON still decodes when optional FX and provider metadata are absent")
    func oldVersionOneJSONDecodesWithoutOptionalMetadata() throws {
        #expect(BillSnapshot.currentVersion == 1)
        let snapshot = try BillSnapshot.capture(
            from: makeOrder(fxRate: 0.05, providerMode: .live),
            completedAt: Date(timeIntervalSince1970: 100)
        )
        var object = try #require(
            JSONSerialization.jsonObject(
                with: try BillSnapshotCodec.encode(snapshot)
            ) as? [String: Any]
        )
        for key in [
            "fxRate",
            "fxRateDate",
            "fxSource",
            "fxQuoteDate",
            "fxFetchedAt",
            "providerModeRaw",
        ] {
            object.removeValue(forKey: key)
        }

        let decoded = try BillSnapshotCodec.decode(
            JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.version == 1)
        #expect(decoded.fxRate == nil)
        #expect(decoded.fxRateDate == nil)
        #expect(decoded.fxSource == nil)
        #expect(decoded.fxQuoteDate == nil)
        #expect(decoded.fxFetchedAt == nil)
        #expect(decoded.providerModeRaw == nil)
        #expect(decoded.lines == snapshot.lines)
        #expect(decoded.total == snapshot.total)
    }
}
