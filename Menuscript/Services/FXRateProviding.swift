import Foundation

/// A currency quote whose market date is deliberately represented as an ISO
/// date-only value. Keeping quoteDate separate from fetchedAt prevents a
/// timezone change from moving a market quote to the previous/next day.
struct FXRate: Equatable, Sendable {
    var rate: Double
    var quoteDate: String
    var fetchedAt: Date
    var source: Source

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

protocol FXRateProviding: Sendable {
    func rate(from: String, to: String) async -> FXRate?
}

/// Narrow settings-side boundary for manual FX overrides. Keeping this
/// separate from `FXRateProviding` lets Settings edit local preferences
/// without constructing a live networking service.
protocol FXManualOverrideStoring: Sendable {
    func setManualOverride(_ rate: Double?, from: String, to: String)
}

enum FXQuoteDate {
    static func string(from date: Date) -> String {
        formatter().string(from: date)
    }

    static func date(from string: String) -> Date? {
        guard string.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let parsed = formatter().date(from: string),
              formatter().string(from: parsed) == string else {
            return nil
        }
        return parsed
    }

    static func isCanonical(_ string: String) -> Bool {
        date(from: string) != nil
    }

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
