import Foundation

/// Deterministic, process-local FX provider for demo mode. It deliberately has
/// no URLSession or UserDefaults dependency, so every supported conversion is
/// available in airplane mode and no state leaks between demo runs.
struct MockFXService: FXRateProviding {
    static let fixedQuoteDate = "2026-01-15"

    /// Currency units per one mock USD. Cross-rates are derived from this
    /// table, which keeps every pair internally consistent.
    private static let unitsPerUSD: [String: Double] = [
        "AUD": 1.51,
        "CAD": 1.36,
        "CHF": 0.90,
        "CNY": 7.25,
        "EUR": 0.92,
        "GBP": 0.79,
        "HKD": 7.80,
        "JPY": 160,
        "KRW": 1_380,
        "MXN": 18,
        "SGD": 1.35,
        "THB": 36,
        "TWD": 32.5,
        "USD": 1,
        "VND": 25_000,
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
