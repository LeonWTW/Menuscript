import Foundation
import SwiftData
import Testing
@testable import Menuscript

@MainActor
@Suite("Lifecycle disk persistence")
struct SessionPersistenceTests {
    private func makeContainer(at url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            "LifecycleTests",
            schema: AppSchema.current,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: AppSchema.current,
            configurations: [configuration]
        )
    }

    @Test("Completed snapshots and legacy nil status survive a disk round trip")
    func completedAndLegacyDiskRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MenuscriptLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("sessions.store")
        let completedID = UUID()
        let legacyID = UUID()
        let completedAt = Date(timeIntervalSince1970: 1_725_148_800)
        var expectedSnapshot: BillSnapshot?

        do {
            let container = try makeContainer(at: storeURL)
            let context = ModelContext(container)
            let completed = MenuSession(
                id: completedID,
                detectedLanguage: "日文",
                targetLanguage: "繁體中文",
                menuCurrency: "JPY",
                homeCurrency: "HKD",
                fxRate: 0.05,
                fxRateDate: FXQuoteDate.date(from: "2026-07-14"),
                fxSource: "mock",
                fxQuoteDate: "2026-07-14",
                fxFetchedAt: Date(timeIntervalSince1970: 1_752_451_200),
                providerModeRaw: RuntimeMode.mock.rawValue,
                peopleCount: 2,
                surchargePercent: 8
            )
            completed.items = [
                MenuItem(
                    originalName: "うどん",
                    translatedName: "烏冬",
                    priceValue: 500,
                    category: "麵",
                    quantity: 2,
                    sortOrder: 0
                )
            ]
            let legacy = MenuSession(
                id: legacyID,
                detectedLanguage: "英文",
                targetLanguage: "繁體中文",
                menuCurrency: "USD",
                homeCurrency: "HKD",
                lifecycleStatusRaw: nil
            )
            context.insert(completed)
            context.insert(legacy)
            try context.save()
            expectedSnapshot = try SessionStore(context: context).finalize(
                completed,
                completedAt: completedAt
            )
        }

        do {
            let container = try makeContainer(at: storeURL)
            let context = ModelContext(container)
            let sessions = try context.fetch(FetchDescriptor<MenuSession>())
            let completed = try #require(sessions.first { $0.id == completedID })
            let legacy = try #require(sessions.first { $0.id == legacyID })

            #expect(completed.lifecycleStatus == .completed)
            #expect(completed.billSnapshot == expectedSnapshot)
            #expect(completed.billSnapshot?.completedAt == completedAt)
            #expect(completed.fxQuoteDate == "2026-07-14")
            #expect(completed.fxFetchedAt == Date(timeIntervalSince1970: 1_752_451_200))
            #expect(completed.providerMode == .mock)
            #expect(completed.billSnapshot?.fxQuoteDate == "2026-07-14")
            #expect(completed.billSnapshot?.fxFetchedAt == completed.fxFetchedAt)
            #expect(completed.billSnapshot?.providerModeRaw == RuntimeMode.mock.rawValue)
            #expect(legacy.lifecycleStatus == .legacyUnfinalized)
            #expect(legacy.isCompleted == false)
            #expect(legacy.billSnapshotData == nil)
        }
    }

    @Test("Snapshot codec rejects unsupported versions")
    func rejectsUnsupportedSnapshotVersion() throws {
        let session = MenuSession(
            detectedLanguage: "日文",
            targetLanguage: "繁體中文",
            menuCurrency: "JPY",
            homeCurrency: "HKD",
            items: [
                MenuItem(
                    originalName: "寿司",
                    translatedName: "壽司",
                    priceValue: 100,
                    category: "主菜",
                    quantity: 1,
                    sortOrder: 0
                )
            ]
        )
        let snapshot = try BillSnapshot.capture(from: session, completedAt: .now)
        let encoded = try BillSnapshotCodec.encode(snapshot)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["version"] = BillSnapshot.currentVersion + 1
        let futureData = try JSONSerialization.data(withJSONObject: object)

        do {
            _ = try BillSnapshotCodec.decode(futureData)
            Issue.record("Expected an unsupported version error")
        } catch let error as BillSnapshotError {
            #expect(error == .unsupportedVersion(BillSnapshot.currentVersion + 1))
        }
    }
}
