import Foundation

struct FXRate: Equatable, Sendable {
    var rate: Double
    var date: Date
    var source: Source

    enum Source: Equatable, Sendable {
        case live
        case cached
        case manual

        /// The string form persisted on `MenuSession.fxSource`.
        var persistedValue: String {
            switch self {
            case .live: return "live"
            case .cached: return "cached"
            case .manual: return "manual"
            }
        }
    }
}

/// Fetches currency conversion rates with a manual-override → live → cached
/// fallback chain. Holds only immutable dependencies so it is safe to share
/// across concurrency domains. `@unchecked` only because `UserDefaults` isn't
/// annotated `Sendable` yet, despite being thread-safe.
final class FXService: @unchecked Sendable {
    private let session: URLSession
    private let defaults: UserDefaults

    init(session: URLSession = FXService.makeDefaultSession(), defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
    }

    /// `.shared`'s default configuration has no per-request timeout; FX
    /// lookups sit on the critical path right after a successful (paid)
    /// Gemini extraction, so a blackholed host must not hang indefinitely.
    static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }

    func rate(from: String, to: String) async -> FXRate? {
        let from = from.uppercased()
        let to = to.uppercased()

        if from == to {
            return FXRate(rate: 1.0, date: Date(), source: .live)
        }

        let overrideValue = defaults.double(forKey: Self.overrideKey(from: from, to: to))
        if overrideValue > 0 {
            let overrideDate = defaults.object(forKey: Self.overrideDateKey(from: from, to: to)) as? Date ?? Date()
            return FXRate(rate: overrideValue, date: overrideDate, source: .manual)
        }

        let cacheKey = Self.cacheKey(from: from, to: to)

        if let live = try? await fetchLive(from: from, to: to) {
            let payload = CachedPayload(rate: live.rate, date: live.date, fetchedAt: Date())
            if let data = try? JSONEncoder().encode(payload) {
                defaults.set(data, forKey: cacheKey)
            }
            return FXRate(rate: live.rate, date: live.date, source: .live)
        }

        if let data = defaults.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode(CachedPayload.self, from: data) {
            return FXRate(rate: cached.rate, date: cached.date, source: .cached)
        }

        return nil
    }

    func setManualOverride(_ rate: Double?, from: String, to: String) {
        let from = from.uppercased()
        let to = to.uppercased()
        let key = Self.overrideKey(from: from, to: to)
        let dateKey = Self.overrideDateKey(from: from, to: to)
        if let rate {
            defaults.set(rate, forKey: key)
            defaults.set(Date(), forKey: dateKey)
        } else {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: dateKey)
        }
    }

    private func fetchLive(from: String, to: String) async throws -> (rate: Double, date: Date) {
        // Defense-in-depth: `from`/`to` can originate from free-text Settings
        // fields or a Gemini-detected currency, so reject anything that isn't
        // a plain 3-letter code before it reaches the query string.
        guard Self.isValidCurrencyCode(from), Self.isValidCurrencyCode(to) else {
            throw URLError(.badURL)
        }
        var components = URLComponents(string: "https://api.frankfurter.dev/v1/latest")
        components?.queryItems = [
            URLQueryItem(name: "from", value: from),
            URLQueryItem(name: "to", value: to),
        ]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(FrankfurterResponse.self, from: data)
        guard let rateValue = decoded.rates[to] else {
            throw URLError(.cannotParseResponse)
        }

        return (rateValue, Self.parseDate(decoded.date) ?? Date())
    }

    /// `from`/`to` are expected to already be uppercased by the caller.
    private static func isValidCurrencyCode(_ code: String) -> Bool {
        code.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil
    }

    private static func overrideKey(from: String, to: String) -> String {
        "fx.override.\(from).\(to)"
    }

    private static func overrideDateKey(from: String, to: String) -> String {
        "fx.override.date.\(from).\(to)"
    }

    private static func cacheKey(from: String, to: String) -> String {
        "fx.cache.\(from).\(to)"
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}

private struct FrankfurterResponse: Decodable {
    let date: String
    let rates: [String: Double]
}

private struct CachedPayload: Codable {
    var rate: Double
    var date: Date
    var fetchedAt: Date
}
