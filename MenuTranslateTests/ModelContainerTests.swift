import Foundation
import Testing
import SwiftData
@testable import MenuTranslate

@Suite("ModelContainer")
struct ModelContainerTests {

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([MenuSession.self, MenuItem.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @Test("Insert a session with two items and fetch them back")
    func insertAndFetch() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let session = MenuSession(
            detectedLanguage: "日文",
            targetLanguage: "繁體中文",
            menuCurrency: "JPY",
            homeCurrency: "HKD"
        )
        let itemA = MenuItem(originalName: "寿司", translatedName: "壽司", category: "主菜", sortOrder: 0)
        let itemB = MenuItem(originalName: "味噌汁", translatedName: "味噌湯", category: "湯", sortOrder: 1)
        session.items = [itemA, itemB]

        context.insert(session)
        try context.save()

        let fetchedSessions = try context.fetch(FetchDescriptor<MenuSession>())
        #expect(fetchedSessions.count == 1)
        #expect(fetchedSessions.first?.items.count == 2)

        let fetchedItems = try context.fetch(FetchDescriptor<MenuItem>())
        #expect(fetchedItems.count == 2)
    }

    @Test("Deleting a session cascades to delete its items")
    func deleteCascades() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let session = MenuSession(
            detectedLanguage: "日文",
            targetLanguage: "繁體中文",
            menuCurrency: "JPY",
            homeCurrency: "HKD"
        )
        let itemA = MenuItem(originalName: "寿司", translatedName: "壽司", category: "主菜", sortOrder: 0)
        let itemB = MenuItem(originalName: "味噌汁", translatedName: "味噌湯", category: "湯", sortOrder: 1)
        session.items = [itemA, itemB]

        context.insert(session)
        try context.save()

        let sessionsBeforeDelete = try context.fetch(FetchDescriptor<MenuSession>())
        #expect(sessionsBeforeDelete.count == 1)

        if let toDelete = sessionsBeforeDelete.first {
            context.delete(toDelete)
        }
        try context.save()

        let remainingItems = try context.fetch(FetchDescriptor<MenuItem>())
        #expect(remainingItems.count == 0)
    }
}
