// Verifies the exact money calculations used to turn selected dishes into bill totals and splits.
// The cases use Decimal values so rounding and currency rules stay predictable.

import Foundation
import Testing
@testable import Menuscript

@Suite("BillMath")
/// Protects the bill calculator's rules for subtotals, surcharges, conversion, and per-person rounding.
struct BillMathTests {

    @Test("Subtotal of an empty line list is zero")
    /// Confirms a bill with no order lines starts at zero instead of producing a missing value.
    func subtotalEmpty() {
        let result = BillMath.subtotal(lines: [])
        #expect(result == Decimal(0))
    }

    @Test("Subtotal sums price times qty across multiple lines")
    /// Confirms each line price is multiplied by its quantity before all lines are added together.
    func subtotalMultiLine() {
        let lines: [(price: Decimal, qty: Int)] = [
            (price: Decimal(string: "12.50")!, qty: 2),
            (price: Decimal(string: "5.00")!, qty: 3),
        ]
        let result = BillMath.subtotal(lines: lines)
        #expect(result == Decimal(string: "40.00"))
    }

    @Test("Subtotal excludes lines with qty 0")
    /// Confirms unselected dishes do not contribute to the amount owed.
    func subtotalExcludesZeroQty() {
        let lines: [(price: Decimal, qty: Int)] = [
            (price: Decimal(string: "12.50")!, qty: 2),
            (price: Decimal(string: "99.00")!, qty: 0),
        ]
        let result = BillMath.subtotal(lines: lines)
        #expect(result == Decimal(string: "25.00"))
    }

    @Test("Total applies a 10% surcharge with exact Decimal arithmetic")
    /// Confirms a percentage surcharge is added with exact money arithmetic.
    func totalAppliesSurcharge() {
        let result = BillMath.total(subtotal: Decimal(1000), surchargePercent: 10)
        #expect(result == Decimal(1100))
    }

    @Test("Per-person split of 1000 JPY across 3 people rounds up at 0 digits")
    /// Confirms whole-number currencies round each share up so the collected shares cover the bill.
    func perPersonRoundsUpZeroDigits() {
        let result = BillMath.perPerson(total: Decimal(1000), people: 3, fractionDigits: 0)
        #expect(result == Decimal(334))
        // Contract: N x perPerson must never fall short of total.
        #expect(result * Decimal(3) >= Decimal(1000))
    }

    @Test("Per-person split of 100.00 across 3 people rounds up at 2 digits")
    /// Confirms two-decimal currencies also round upward rather than leave a small unpaid remainder.
    func perPersonRoundsUpTwoDigits() {
        let result = BillMath.perPerson(total: Decimal(string: "100.00")!, people: 3, fractionDigits: 2)
        #expect(result == Decimal(string: "33.34"))
        #expect(result * Decimal(3) >= Decimal(string: "100.00")!)
    }

    @Test("Converted multiplies the amount by an FX rate")
    /// Confirms converting a bill applies the supplied exchange rate once.
    func convertedMultipliesByRate() {
        let result = BillMath.converted(Decimal(600), rate: 0.052)
        #expect(result == Decimal(string: "31.2"))
    }

    @Test("Zero-decimal currencies", arguments: ["JPY", "KRW", "VND"])
    /// Confirms currencies normally written without minor units display no decimal places.
    func fractionDigitsZeroDecimal(code: String) {
        #expect(BillMath.fractionDigits(forCurrency: code) == 0)
    }

    @Test("Two-decimal currencies", arguments: ["USD", "EUR", "HKD", "TWD", "GBP"])
    /// Confirms other supported currencies use the standard two decimal places.
    func fractionDigitsDefaultTwo(code: String) {
        #expect(BillMath.fractionDigits(forCurrency: code) == 2)
    }
}
