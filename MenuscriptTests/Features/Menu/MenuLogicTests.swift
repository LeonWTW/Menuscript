// Verifies the pure menu-list rules that group dishes, filter categories, and summarize an order.
// Keeping these checks outside SwiftUI makes the user-visible behavior easy to reason about.

import Foundation
import Testing
@testable import Menuscript

@Suite("MenuLogic")
/// Protects dish ordering, category selection, and cart totals including unpriced items.
struct MenuLogicTests {

    /// Creates a menu item with only the fields needed by a specific logic test.
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
    /// Confirms category chips follow the visual dish order and do not repeat labels.
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
    /// Confirms clearing the category filter restores every dish in recognition order.
    func filteredNilReturnsAllSorted() {
        let items = [
            makeItem(originalName: "B", category: "主食", sortOrder: 1),
            makeItem(originalName: "A", category: "湯品", sortOrder: 0),
        ]
        let result = MenuLogic.filtered(items: items, category: nil)
        #expect(result.map(\.originalName) == ["A", "B"])
    }

    @Test("Filtered by category returns only matching items sorted by sortOrder")
    /// Confirms selecting a category hides other dishes without changing dish order.
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
    /// Confirms cart counts include ordered market-price dishes while the numeric subtotal excludes unknown prices.
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
    /// Confirms an all-unpriced order still appears in the cart instead of looking empty.
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
    /// Confirms an empty menu selection produces zero counts and no unpriced warning.
    func totalsEmpty() {
        let result = MenuLogic.totals(items: [])
        #expect(result.kinds == 0)
        #expect(result.count == 0)
        #expect(result.subtotal == Decimal(0))
        #expect(result.hasUnpriced == false)
    }
}
