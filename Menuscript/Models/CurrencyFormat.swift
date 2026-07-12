import Foundation

/// Formats amounts for display using a small explicit symbol map plus a
/// locale-independent number formatter, so output is deterministic in tests
/// regardless of the running device's locale.
enum CurrencyFormat {
    private static let symbols: [String: String] = [
        "JPY": "¥",
        "HKD": "HK$",
        "TWD": "NT$",
        "USD": "$",
        "EUR": "€",
    ]

    static func format(_ amount: Decimal, code: String) -> String {
        let upperCode = code.uppercased()
        let digits = BillMath.fractionDigits(forCurrency: upperCode)

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        formatter.roundingMode = .halfUp

        let amountString = formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"

        if let symbol = symbols[upperCode] {
            return "\(symbol)\(amountString)"
        }
        return "\(upperCode) \(amountString)"
    }
}
