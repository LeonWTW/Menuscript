// Defines the shared currency-rate data and service boundaries used by live, cached, manual, and demo flows.
// It also centralizes conversion between market-date strings and Date values.

import Foundation

/// A currency quote whose market date is deliberately represented as an ISO
/// date-only value. Keeping quoteDate separate from fetchedAt prevents a
/// timezone change from moving a market quote to the previous/next day.
struct FXRate: Equatable, Sendable {
    /// The number of target-currency units received for one source-currency unit.
    var rate: Double
    /// The market date supplied with the quote, stored as `yyyy-MM-dd` to avoid timezone shifts.
    var quoteDate: String
    /// The exact time the app fetched or saved the quote, used to decide when cached data expires.
    var fetchedAt: Date
    /// Identifies where the quote came from so the UI and persistence layer can explain it.
    var source: Source

    /// The possible origins of a currency quote.
    enum Source: Equatable, Sendable {
        case live
        case cached
        case manual
        case mock

        /// The string form persisted on MenuSession.fxSource.
        var persistedValue: String {
            switch self {
            case .live: return "live"
            case .cached: return "cached"
            case .manual: return "manual"
            case .mock: return "mock"
            }
        }
    }

    /// Creates a quote while keeping its market date separate from the time it was fetched.
    init(rate: Double, quoteDate: String, fetchedAt: Date, source: Source) {
        self.rate = rate
        self.quoteDate = quoteDate
        self.fetchedAt = fetchedAt
        self.source = source
    }

    /// Compatibility initializer for Wave 1 call sites/tests. New code should
    /// pass a date-only quoteDate and an independent fetchedAt timestamp.
    init(rate: Double, date: Date, source: Source) {
        self.init(
            rate: rate,
            quoteDate: FXQuoteDate.string(from: date),
            fetchedAt: date,
            source: source
        )
    }

    /// Compatibility view used by the existing SwiftData/UI layer. The value
    /// is always UTC midnight for quoteDate, never local midnight.
    var date: Date {
        FXQuoteDate.date(from: quoteDate) ?? fetchedAt
    }
}

/// Common lookup interface shared by live and offline currency providers.
protocol FXRateProviding: Sendable {
    /// Returns the best available conversion quote for a currency pair, or nil when none can be resolved.
    func rate(from: String, to: String) async -> FXRate?
}

/// Narrow settings-side boundary for manual FX overrides. Keeping this
/// separate from `FXRateProviding` lets Settings edit local preferences
/// without constructing a live networking service.
protocol FXManualOverrideStoring: Sendable {
    /// Saves a user-supplied rate, or removes the override when the supplied rate is nil or invalid.
    func setManualOverride(_ rate: Double?, from: String, to: String)
}

/// Converts quote dates to and from one strict, timezone-independent `yyyy-MM-dd` format.
enum FXQuoteDate {
    /// Formats a moment as its Gregorian calendar date in UTC.
    static func string(from date: Date) -> String {
        formatter().string(from: date)
    }

    /// Parses a strict `yyyy-MM-dd` value at UTC midnight, rejecting impossible or loosely formatted dates.
    static func date(from string: String) -> Date? {
        guard string.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let parsed = formatter().date(from: string),
              formatter().string(from: parsed) == string else {
            return nil
        }
        return parsed
    }

    /// Checks whether text is a real date in the app's required storage format.
    static func isCanonical(_ string: String) -> Bool {
        date(from: string) != nil
    }

    /// Builds a fresh strict formatter because DateFormatter is mutable and unsafe to share across threads.
    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}
