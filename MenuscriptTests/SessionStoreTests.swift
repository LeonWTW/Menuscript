import Foundation
import SwiftData
import Testing
@testable import Menuscript

@MainActor
@Suite("SessionStore persistence operations")
struct SessionStoreTests {
    private enum InjectedFailure: Error, LocalizedError {
        case fetch
        case save

        var errorDescription: String? {
            switch self {
            case .fetch: "injected fetch failure"
            case .save: "injected save failure"
            }
        }
    }

    private func makeContext(sessionCount: Int = 2) throws -> ModelContext {
        let configuration = ModelConfiguration(
            schema: AppSchema.current,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: AppSchema.current,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        for index in 0..<sessionCount {
            let session = MenuSession(
                title: "Session \(index)",
                detectedLanguage: "日文",
                targetLanguage: "繁體中文",
                menuCurrency: "JPY",
                homeCurrency: "HKD"
            )
            session.items = [
                MenuItem(
                    originalName: "Dish \(index)",
                    translatedName: "Dish \(index)",
                    priceValue: 100,
                    category: "測試",
                    quantity: 1,
                    sortOrder: 0
                )
            ]
            context.insert(session)
        }
        try context.save()
        return context
    }

    @Test("Updating an FX rate saves all quote fields without changing provider provenance")
    func updateFXRateSavesAllQuoteFields() throws {
        let context = try makeContext(sessionCount: 1)
        let session = try #require(
            context.fetch(FetchDescriptor<MenuSession>()).first
        )
        session.providerModeRaw = RuntimeMode.mock.rawValue
        try context.save()
        let fetchedAt = Date(timeIntervalSince1970: 1_752_556_800)
        let freshRate = FXRate(
            rate: 0.0067,
            quoteDate: "2025-07-15",
            fetchedAt: fetchedAt,
            source: .cached
        )
        var saveCount = 0
        let store = SessionStore(
            context: context,
            saveAction: { context in
                saveCount += 1
                try context.save()
            }
        )

        try store.updateFXRate(freshRate, for: session)

        #expect(saveCount == 1)
        #expect(session.fxRate == freshRate.rate)
        #expect(session.fxRateDate == freshRate.date)
        #expect(session.fxSource == "cached")
        #expect(session.fxQuoteDate == freshRate.quoteDate)
        #expect(session.fxFetchedAt == fetchedAt)
        #expect(session.providerModeRaw == RuntimeMode.mock.rawValue)

        let verificationContext = ModelContext(context.container)
        let persisted = try #require(
            verificationContext.fetch(FetchDescriptor<MenuSession>()).first
        )
        #expect(persisted.fxRate == freshRate.rate)
        #expect(persisted.fxRateDate == freshRate.date)
        #expect(persisted.fxSource == "cached")
        #expect(persisted.fxQuoteDate == freshRate.quoteDate)
        #expect(persisted.fxFetchedAt == fetchedAt)
        #expect(persisted.providerModeRaw == RuntimeMode.mock.rawValue)
    }

    @Test("A failed FX save restores only quote fields and preserves unrelated edits")
    func updateFXRateSaveFailureRestoresOnlyQuoteFields() throws {
        let context = try makeContext(sessionCount: 1)
        let session = try #require(
            context.fetch(FetchDescriptor<MenuSession>()).first
        )
        let originalRateDate = Date(timeIntervalSince1970: 1_725_062_400)
        let originalFetchedAt = Date(timeIntervalSince1970: 1_725_066_000)
        session.fxRate = 0.05
        session.fxRateDate = originalRateDate
        session.fxSource = "live"
        session.fxQuoteDate = "2024-08-31"
        session.fxFetchedAt = originalFetchedAt
        session.providerModeRaw = RuntimeMode.live.rawValue
        try context.save()

        session.title = "Unrelated pending title"
        session.peopleCount = 7
        let failedFetchedAt = Date(timeIntervalSince1970: 1_752_556_800)
        let failedRate = FXRate(
            rate: 0.0067,
            quoteDate: "2025-07-15",
            fetchedAt: failedFetchedAt,
            source: .manual
        )
        var valuesSeenBySave: (Double?, Date?, String?, String?, Date?)?
        let store = SessionStore(
            context: context,
            saveAction: { _ in
                valuesSeenBySave = (
                    session.fxRate,
                    session.fxRateDate,
                    session.fxSource,
                    session.fxQuoteDate,
                    session.fxFetchedAt
                )
                throw InjectedFailure.save
            }
        )

        do {
            try store.updateFXRate(failedRate, for: session)
            Issue.record("Expected FX update to fail")
        } catch let error as SessionStoreError {
            #expect(error == .fxSaveFailed("injected save failure"))
        }

        #expect(valuesSeenBySave?.0 == failedRate.rate)
        #expect(valuesSeenBySave?.1 == failedRate.date)
        #expect(valuesSeenBySave?.2 == "manual")
        #expect(valuesSeenBySave?.3 == failedRate.quoteDate)
        #expect(valuesSeenBySave?.4 == failedFetchedAt)
        #expect(session.fxRate == 0.05)
        #expect(session.fxRateDate == originalRateDate)
        #expect(session.fxSource == "live")
        #expect(session.fxQuoteDate == "2024-08-31")
        #expect(session.fxFetchedAt == originalFetchedAt)
        #expect(session.providerModeRaw == RuntimeMode.live.rawValue)
        #expect(session.title == "Unrelated pending title")
        #expect(session.peopleCount == 7)
        #expect(context.hasChanges)

        let verificationContext = ModelContext(context.container)
        let persisted = try #require(
            verificationContext.fetch(FetchDescriptor<MenuSession>()).first
        )
        #expect(persisted.title == "Session 0")
        #expect(persisted.peopleCount == 2)
        #expect(persisted.fxRate == 0.05)
        #expect(persisted.fxRateDate == originalRateDate)
        #expect(persisted.fxSource == "live")
        #expect(persisted.fxQuoteDate == "2024-08-31")
        #expect(persisted.fxFetchedAt == originalFetchedAt)
        #expect(persisted.providerModeRaw == RuntimeMode.live.rawValue)
    }

    @Test("Deleting selected sessions saves once and preserves unselected sessions")
    func deleteSelected() throws {
        let context = try makeContext(sessionCount: 3)
        let sessions = try context.fetch(FetchDescriptor<MenuSession>())
        var saveCount = 0
        let store = SessionStore(
            context: context,
            saveAction: { context in
                saveCount += 1
                try context.save()
            }
        )

        try store.delete(Array(sessions.prefix(2)))

        let remaining = try context.fetch(FetchDescriptor<MenuSession>())
        #expect(saveCount == 1)
        #expect(remaining.count == 1)
    }

    @Test("A failed selected delete rolls the context back")
    func deleteFailureRollsBack() throws {
        let context = try makeContext()
        let sessions = try context.fetch(FetchDescriptor<MenuSession>())
        let store = SessionStore(
            context: context,
            saveAction: { _ in throw InjectedFailure.save }
        )

        do {
            try store.delete(sessions[0])
            Issue.record("Expected deletion to fail")
        } catch let error as SessionStoreError {
            #expect(error == .deleteFailed("injected save failure"))
        }

        let remaining = try context.fetch(FetchDescriptor<MenuSession>())
        let remainingItems = try context.fetch(FetchDescriptor<MenuItem>())
        #expect(remaining.count == 2)
        #expect(remainingItems.count == 2)
    }

    @Test("Delete all reports its count and cascades related items")
    func deleteAll() throws {
        let context = try makeContext(sessionCount: 3)

        let deletedCount = try SessionStore(context: context).deleteAll()

        #expect(deletedCount == 3)
        #expect(try context.fetch(FetchDescriptor<MenuSession>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<MenuItem>()).isEmpty)
    }

    @Test("A failed delete-all fetch leaves persisted sessions untouched")
    func deleteAllFetchFailure() throws {
        let context = try makeContext()
        let store = SessionStore(
            context: context,
            fetchAllAction: { _ in throw InjectedFailure.fetch }
        )

        do {
            _ = try store.deleteAll()
            Issue.record("Expected fetch to fail")
        } catch let error as SessionStoreError {
            #expect(error == .fetchFailed("injected fetch failure"))
        }

        #expect(try context.fetch(FetchDescriptor<MenuSession>()).count == 2)
    }

    @Test("A failed delete-all save restores every session and child item")
    func deleteAllSaveFailureRollsBack() throws {
        let context = try makeContext()
        let store = SessionStore(
            context: context,
            saveAction: { _ in throw InjectedFailure.save }
        )

        do {
            _ = try store.deleteAll()
            Issue.record("Expected save to fail")
        } catch let error as SessionStoreError {
            #expect(error == .deleteFailed("injected save failure"))
        }

        #expect(try context.fetch(FetchDescriptor<MenuSession>()).count == 2)
        #expect(try context.fetch(FetchDescriptor<MenuItem>()).count == 2)
    }

    @Test("Persistence error descriptions route every branch through localization")
    func persistenceErrorsUseL10nContract() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contracts: [(path: String, calls: [String])] = [
            (
                "Menuscript/Services/SessionStore.swift",
                [
                    "return L10n.string(\"已完成帳單缺少可讀取嘅快照，記錄未有再被修改。\")",
                    "return L10n.string(\"部分菜單記錄未完成儲存，今次未有刪除任何記錄。\")",
                    "return L10n.string(\"未能儲存帳單，請再試一次。（%@）\", detail)",
                    "return L10n.string(\"最新匯率未能儲存，請稍後再試。\")",
                    "return L10n.string(\"未能讀取菜單記錄，請再試一次。（%@）\", detail)",
                    "return L10n.string(\"未能刪除菜單記錄，原有記錄已保留。（%@）\", detail)",
                ]
            ),
            (
                "Menuscript/Models/BillSnapshot.swift",
                [
                    "return L10n.string(\"請先揀至少一款菜式先完成帳單。\")",
                    "return L10n.string(\"帳單記錄版本（%lld）未能讀取。\", version)",
                ]
            ),
        ]

        for contract in contracts {
            let source = try String(
                contentsOf: repoRoot.appendingPathComponent(contract.path),
                encoding: .utf8
            )
            for expectedCall in contract.calls {
                #expect(source.contains(expectedCall), "Missing localization call in \(contract.path)")
            }
            #expect(
                source.components(separatedBy: "return L10n.string(").count - 1
                    == contract.calls.count,
                "Every errorDescription branch in \(contract.path) must use L10n.string"
            )
        }
    }
}
