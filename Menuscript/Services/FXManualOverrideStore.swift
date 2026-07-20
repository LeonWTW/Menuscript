import Foundation

/// UserDefaults-backed manual-override writer with no URLSession dependency.
/// FXService reads the same keys when resolving its manual-first rate chain.
struct FXManualOverrideStore: @unchecked Sendable, FXManualOverrideStoring {
    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date

    init(
        defaults: UserDefaults = .standard,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        self.clock = clock
    }

    func setManualOverride(_ rate: Double?, from rawFrom: String, to rawTo: String) {
        guard let from = FXService.normalizedCurrencyCode(rawFrom),
              let to = FXService.normalizedCurrencyCode(rawTo) else {
            return
        }
        let key = FXService.overrideKey(from: from, to: to)
        let dateKey = FXService.overrideDateKey(from: from, to: to)
        let quoteDateKey = FXService.overrideQuoteDateKey(from: from, to: to)
        if let rate, rate.isFinite, rate > 0 {
            let now = clock()
            defaults.set(rate, forKey: key)
            // Retain the legacy Date during the compatibility window so an
            // older build and the canonical date-only reader stay coherent.
            defaults.set(now, forKey: dateKey)
            defaults.set(FXQuoteDate.string(from: now), forKey: quoteDateKey)
        } else {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: dateKey)
            defaults.removeObject(forKey: quoteDateKey)
        }
    }
}
