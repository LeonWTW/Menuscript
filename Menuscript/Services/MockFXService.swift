import Foundation

/// Deterministic, process-local FX provider for demo mode. It deliberately has
/// no URLSession or UserDefaults dependency, so every supported conversion is
/// available in airplane mode and no state leaks between demo runs.
struct MockFXService: FXRateProviding {
    static let fixedQuoteDate = "2026-01-15"

    /// Currency units per one mock USD. Cross-rates are derived from this
    /// table, which keeps every pair internally consistent.
    private static let unitsPerUSD: [String: Double] = [
        "AED": 3.6725,
        "AUD": 1.51,
        "BRL": 5.80,
        "CAD": 1.36,
        "CHF": 0.90,
        "CNY": 7.25,
        "CZK": 23,
        "DKK": 6.86,
        "EUR": 0.92,
        "GBP": 0.79,
        "HKD": 7.80,
        "IDR": 16_300,
        "INR": 86.5,
        "JPY": 160,
        "KRW": 1_380,
        "MYR": 4.45,
        "MXN": 18,
        "NOK": 11,
        "NZD": 1.66,
        "PHP": 58.5,
        "PLN": 3.95,
        "SAR": 3.75,
        "SEK": 10.5,
        "SGD": 1.35,
        "THB": 36,
        "TRY": 36,
        "TWD": 32.5,
        "USD": 1,
        "VND": 25_000,
        "ZAR": 18.5,
    ]

    func rate(from rawFrom: String, to rawTo: String) async -> FXRate? {
        let from = rawFrom.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let to = rawTo.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let fromUnits = Self.unitsPerUSD[from],
              let toUnits = Self.unitsPerUSD[to] else {
            return nil
        }

        let fixedDate = FXQuoteDate.date(from: Self.fixedQuoteDate) ?? .distantPast
        return FXRate(
            rate: toUnits / fromUnits,
            quoteDate: Self.fixedQuoteDate,
            fetchedAt: fixedDate,
            source: .mock
        )
    }
}
