import Foundation
import Testing
@testable import MenuTranslate

/// Tests the exact `BillMath` compositions `BillView` uses to derive its
/// numbers: order lines → subtotal → total → per-person, and
/// total → converted → per-person. Pure `BillMath` compositions — no UI
/// testing.
@Suite("BillView derived numbers")
struct BillViewLogicTests {

    private func makeItem(priceValue: Decimal?, quantity: Int, sortOrder: Int) -> MenuItem {
        MenuItem(
            originalName: "dish",
            translatedName: "dish",
            priceValue: priceValue,
            category: "測試",
            quantity: quantity,
            sortOrder: sortOrder
        )
    }

    /// Mirrors `BillView.subtotal`: items with quantity>0 and a priced
    /// value are mapped to (price, qty) lines and summed via `BillMath`.
    private func subtotal(of items: [MenuItem]) -> Decimal {
        let lines: [(price: Decimal, qty: Int)] = items
            .filter { $0.quantity > 0 }
            .compactMap { item in
                guard let price = item.priceValue else { return nil }
                return (price: price, qty: item.quantity)
            }
        return BillMath.subtotal(lines: lines)
    }

    @Test("Order lines subtotal sums priced, quantity>0 items and ignores unpriced/zero-qty lines")
    func orderLinesSubtotal() {
        let items = [
            makeItem(priceValue: Decimal(1280), quantity: 2, sortOrder: 0), // 2560
            makeItem(priceValue: nil, quantity: 1, sortOrder: 1),           // excluded: no price
            makeItem(priceValue: Decimal(550), quantity: 0, sortOrder: 2), // excluded: qty 0
            makeItem(priceValue: Decimal(420), quantity: 1, sortOrder: 3), // 420
        ]
        let result = subtotal(of: items)
        #expect(result == Decimal(2980))
    }

    @Test("Total applies a 10% surcharge on top of the order-lines subtotal")
    func totalWithTenPercentSurcharge() {
        let items = [
            makeItem(priceValue: Decimal(1000), quantity: 2, sortOrder: 0), // subtotal 2000
        ]
        let subtotalValue = subtotal(of: items)
        let result = BillMath.total(subtotal: subtotalValue, surchargePercent: 10)
        #expect(result == Decimal(2200))
    }

    @Test("Per-person JPY split of an evenly-divisible total needs no rounding")
    func perPersonJPYEvenSplit() {
        // 1800 subtotal + 10% surcharge = 1980, split 3 ways = 660 exactly.
        let total = BillMath.total(subtotal: Decimal(1800), surchargePercent: 10)
        #expect(total == Decimal(1980))
        let result = BillMath.perPerson(total: total, people: 3, fractionDigits: 0)
        #expect(result == Decimal(660))
    }

    @Test("Per-person JPY split of an uneven total rounds up so shares never fall short")
    func perPersonJPYUnevenSplitRoundsUp() {
        let result = BillMath.perPerson(total: Decimal(1000), people: 3, fractionDigits: 0)
        #expect(result == Decimal(334))
        #expect(result * Decimal(3) >= Decimal(1000))
    }

    @Test("Converted per-person splits the FX-converted total at the home currency's fraction digits, rounding up")
    func convertedPerPersonTwoFractionDigits() {
        // 1000 JPY converted at 0.0521 -> 52.1 HKD, split 3 ways at 2 digits.
        let convertedTotal = BillMath.converted(Decimal(1000), rate: 0.0521)
        #expect(convertedTotal == Decimal(string: "52.1"))
        let result = BillMath.perPerson(total: convertedTotal, people: 3, fractionDigits: 2)
        #expect(result == Decimal(string: "17.37"))
        #expect(result * Decimal(3) >= convertedTotal)
    }
}
