import Foundation
import Testing
@testable import Menuscript

@Suite("MenuLogic")
struct MenuLogicTests {

    private func makeItem(
        originalName: String = "orig",
        translatedName: String = "translated",
        priceValue: Decimal? = nil,
        category: String,
        quantity: Int = 0,
        sortOrder: Int
    ) -> MenuItem {
        MenuItem(
            originalName: originalName,
            translatedName: translatedName,
            priceValue: priceValue,
            category: category,
            quantity: quantity,
            sortOrder: sortOrder
        )
    }

    @Test("Categories are returned in first-appearance order by sortOrder")
    func categoriesFirstAppearanceOrder() {
        let items = [
            makeItem(category: "湯品", sortOrder: 2),
            makeItem(category: "主食", sortOrder: 0),
            makeItem(category: "主食", sortOrder: 1),
            makeItem(category: "飲品", sortOrder: 3),
        ]
        let result = MenuLogic.categories(items: items)
        #expect(result == ["主食", "湯品", "飲品"])
    }

    @Test("Filtered with nil category returns all items sorted by sortOrder")
    func filteredNilReturnsAllSorted() {
        let items = [
            makeItem(originalName: "B", category: "主食", sortOrder: 1),
            makeItem(originalName: "A", category: "湯品", sortOrder: 0),
        ]
        let result = MenuLogic.filtered(items: items, category: nil)
        #expect(result.map(\.originalName) == ["A", "B"])
    }

    @Test("Filtered by category returns only matching items sorted by sortOrder")
    func filteredByCategory() {
        let items = [
            makeItem(originalName: "B", category: "主食", sortOrder: 1),
            makeItem(originalName: "A", category: "湯品", sortOrder: 0),
            makeItem(originalName: "C", category: "主食", sortOrder: 2),
        ]
        let result = MenuLogic.filtered(items: items, category: "主食")
        #expect(result.map(\.originalName) == ["B", "C"])
    }

    @Test("Totals ignore qty-0 items but count unpriced ordered items in kinds/count, not subtotal")
    func totalsIgnoresZeroQtyAndNilPrice() {
        let items = [
            makeItem(priceValue: Decimal(500), category: "燒烤", quantity: 2, sortOrder: 0),
            makeItem(priceValue: Decimal(300), category: "燒烤", quantity: 0, sortOrder: 1),
            makeItem(priceValue: nil, category: "飲品", quantity: 3, sortOrder: 2),
            makeItem(priceValue: Decimal(650), category: "主食", quantity: 1, sortOrder: 3),
        ]
        let result = MenuLogic.totals(items: items)
        #expect(result.kinds == 3)
        #expect(result.count == 6)
        #expect(result.subtotal == Decimal(1650))
        #expect(result.hasUnpriced == true)
    }

    @Test("An order made up entirely of unpriced items still surfaces a non-zero kind/count so the cart bar is not hidden")
    func totalsOfUnpricedOnlyOrderIsNotHidden() {
        let items = [
            makeItem(priceValue: nil, category: "飲品", quantity: 2, sortOrder: 0),
        ]
        let result = MenuLogic.totals(items: items)
        #expect(result.kinds == 1)
        #expect(result.count == 2)
        #expect(result.subtotal == Decimal(0))
        #expect(result.hasUnpriced == true)
    }

    @Test("Totals of an empty list are all zero")
    func totalsEmpty() {
        let result = MenuLogic.totals(items: [])
        #expect(result.kinds == 0)
        #expect(result.count == 0)
        #expect(result.subtotal == Decimal(0))
        #expect(result.hasUnpriced == false)
    }
}
