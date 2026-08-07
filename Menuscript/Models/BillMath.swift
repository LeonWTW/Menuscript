// Contains deterministic money calculations that can be reused and tested
// without loading the interface, database, or network services.

import Foundation

/// Adds, converts, and splits bill amounts without changing the database or UI,
/// which keeps money rules predictable and easy to test.
enum BillMath {
    /// Adds price × quantity for every line; a zero-quantity line adds nothing.
    static func subtotal(lines: [(price: Decimal, qty: Int)]) -> Decimal {
        lines.reduce(Decimal(0)) { runningTotal, line in
            runningTotal + line.price * Decimal(line.qty)
        }
    }

    /// Subtotal plus a percentage surcharge (e.g. 10 for a 10% service charge).
    static func total(subtotal: Decimal, surchargePercent: Double) -> Decimal {
        let multiplier = Decimal(1) + decimal(from: surchargePercent) / Decimal(100)
        return subtotal * multiplier
    }

    /// Splits a total evenly and rounds each share upward to the requested decimal
    /// places so the combined shares never fall short of the bill.
    static func perPerson(total: Decimal, people: Int, fractionDigits: Int) -> Decimal {
        guard people > 0 else { return total }
        var share = total / Decimal(people)
        var rounded = Decimal(0)
        NSDecimalRound(&rounded, &share, fractionDigits, .up)
        return rounded
    }

    /// Converts an amount to another currency using the supplied exchange rate.
    static func converted(_ amount: Decimal, rate: Double) -> Decimal {
        amount * decimal(from: rate)
    }

    /// Returns the usual number of decimal places shown for a currency.
    static func fractionDigits(forCurrency code: String) -> Int {
        switch code.uppercased() {
        case "JPY", "KRW", "VND":
            return 0
        default:
            return 2
        }
    }

    /// Converts a floating-point rate through text first, avoiding tiny computer
    /// rounding artifacts in otherwise simple decimal values such as 0.1.
    private static func decimal(from double: Double) -> Decimal {
        Decimal(string: String(double)) ?? Decimal(double)
    }
}
