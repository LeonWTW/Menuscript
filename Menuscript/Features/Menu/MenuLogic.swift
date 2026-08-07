// Contains deterministic menu sorting, filtering, and cart calculations so
// screen views remain simple and the rules can be tested without SwiftUI.

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

    /// Cart totals over all items with `quantity > 0` (matching `BillView.orderLines`):
    /// `kinds` is the count of distinct ordered items and `count` is the sum of their
    /// quantities — both include market-price lines, so an order made up entirely of
    /// unpriced items still surfaces a non-zero cart. `subtotal` sums `priceValue × quantity`
    /// over the priced subset only; `hasUnpriced` flags whether any ordered line was left
    /// out of `subtotal` because it has no price.
    static func totals(items: [MenuItem]) -> (kinds: Int, count: Int, subtotal: Decimal, hasUnpriced: Bool) {
        let ordered = items.filter { $0.quantity > 0 }
        let count = ordered.reduce(0) { $0 + $1.quantity }
        let subtotal = ordered.reduce(Decimal(0)) { runningTotal, item in
            runningTotal + (item.priceValue ?? 0) * Decimal(item.quantity)
        }
        let hasUnpriced = ordered.contains { $0.priceValue == nil }
        return (kinds: ordered.count, count: count, subtotal: subtotal, hasUnpriced: hasUnpriced)
    }
}
