import Foundation

/// Pure view-logic helpers for the Menu screen: category derivation, filtering
/// by category, and cart totals. No SwiftUI, no SwiftData — operates on plain
/// `MenuItem` arrays so it can be unit tested without a model container.
enum MenuLogic {
    /// Distinct categories in first-appearance order, walking `items` by
    /// ascending `sortOrder`.
    static func categories(items: [MenuItem]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            if seen.insert(item.category).inserted {
                result.append(item.category)
            }
        }
        return result
    }

    /// Items in `category` (or all items when `category` is nil), sorted by
    /// ascending `sortOrder`.
    static func filtered(items: [MenuItem], category: String?) -> [MenuItem] {
        let matching = category.map { wanted in items.filter { $0.category == wanted } } ?? items
        return matching.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Cart totals over items with `quantity > 0` and a non-nil `priceValue`:
    /// `kinds` is the count of distinct qualifying items, `count` is the sum
    /// of their quantities, and `subtotal` is the sum of `priceValue × quantity`.
    static func totals(items: [MenuItem]) -> (kinds: Int, count: Int, subtotal: Decimal) {
        let priced = items.filter { $0.quantity > 0 && $0.priceValue != nil }
        let count = priced.reduce(0) { $0 + $1.quantity }
        let subtotal = priced.reduce(Decimal(0)) { runningTotal, item in
            runningTotal + (item.priceValue ?? 0) * Decimal(item.quantity)
        }
        return (kinds: priced.count, count: count, subtotal: subtotal)
    }
}
