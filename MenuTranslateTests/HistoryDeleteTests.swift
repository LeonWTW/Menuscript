import Foundation
import Testing
import SwiftData
@testable import MenuTranslate

@MainActor
@Suite("HistoryDelete")
struct HistoryDeleteTests {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([MenuSession.self, MenuItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    private func makeSession(title: String, itemNames: [String]) -> MenuSession {
        let session = MenuSession(
            title: title,
            detectedLanguage: "日文",
            targetLanguage: "繁體中文",
            menuCurrency: "JPY",
            homeCurrency: "HKD"
        )
        session.items = itemNames.enumerated().map { index, name in
            MenuItem(originalName: name, translatedName: name, category: "主菜", sortOrder: index)
        }
        return session
    }

    @Test("Deleting one session cascades its items and leaves the other session intact")
    func deleteOneSessionCascadesItems() throws {
        let context = try makeContext()

        let sessionA = makeSession(title: "餐廳 A", itemNames: ["壽司", "味噌湯"])
        let sessionB = makeSession(title: "餐廳 B", itemNames: ["拉麵"])

        context.insert(sessionA)
        context.insert(sessionB)
        try context.save()

        let sessionsBeforeDelete = try context.fetch(FetchDescriptor<MenuSession>())
        #expect(sessionsBeforeDelete.count == 2)

        context.delete(sessionA)
        try context.save()

        let remainingSessions = try context.fetch(FetchDescriptor<MenuSession>())
        #expect(remainingSessions.count == 1)
        #expect(remainingSessions.first?.title == "餐廳 B")

        let remainingItems = try context.fetch(FetchDescriptor<MenuItem>())
        #expect(remainingItems.count == 1)
        #expect(remainingItems.allSatisfy { $0.session?.title == "餐廳 B" })
    }

    @Test("Deleting all sessions clears both the session and item tables")
    func deleteAllSessionsClearsBothTables() throws {
        let context = try makeContext()

        let sessionA = makeSession(title: "餐廳 A", itemNames: ["壽司", "味噌湯"])
        let sessionB = makeSession(title: "餐廳 B", itemNames: ["拉麵"])

        context.insert(sessionA)
        context.insert(sessionB)
        try context.save()

        let allSessions = try context.fetch(FetchDescriptor<MenuSession>())
        for session in allSessions {
            context.delete(session)
        }
        try context.save()

        let remainingSessions = try context.fetch(FetchDescriptor<MenuSession>())
        let remainingItems = try context.fetch(FetchDescriptor<MenuItem>())
        #expect(remainingSessions.count == 0)
        #expect(remainingItems.count == 0)
    }
}
