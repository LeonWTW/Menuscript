import Foundation

/// Pure bill-splitting arithmetic. No SwiftData, no UI — Decimal in, Decimal out.
enum BillMath {
    /// Sum of price × quantity across all lines. Lines with qty 0 contribute 0.
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

    /// Even split of `total` across `people`, rounded UP at `fractionDigits`
    /// so that `people × perPerson` is always >= `total`.
    static func perPerson(total: Decimal, people: Int, fractionDigits: Int) -> Decimal {
        guard people > 0 else { return total }
        var share = total / Decimal(people)
        var rounded = Decimal(0)
        NSDecimalRound(&rounded, &share, fractionDigits, .up)
        return rounded
    }

    /// Converts an amount using a floating-point FX rate.
    static func converted(_ amount: Decimal, rate: Double) -> Decimal {
        amount * decimal(from: rate)
    }

    /// Number of fraction digits conventionally used to display a currency.
    static func fractionDigits(forCurrency code: String) -> Int {
        switch code.uppercased() {
        case "JPY", "KRW", "VND":
            return 0
        default:
            return 2
        }
    }

    /// Converts a Double to Decimal via its shortest round-tripping string
    /// representation, avoiding binary-fraction artifacts (e.g. 0.1 + 0.2).
    private static func decimal(from double: Double) -> Decimal {
        Decimal(string: String(double)) ?? Decimal(double)
    }
}
