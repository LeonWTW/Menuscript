// Resolves currency rates from a manual preference, the Frankfurter API, or a recent local cache.
// Validation and expiry checks keep malformed or stale financial data out of bill calculations.

import Foundation

/// Fetches currency conversion rates with a manual-override → live → fresh
/// cache fallback chain. Frankfurter v2 is used for every supported pair,
/// including TWD. Cached quotes have a hard seven-day lifetime.
///
/// The class is immutable apart from thread-safe URLSession/UserDefaults
/// dependencies. UserDefaults is not annotated Sendable, hence unchecked.
final class FXService: @unchecked Sendable, FXRateProviding, FXManualOverrideStoring {
    /// The longest a downloaded quote may be reused when the live service is unavailable.
    static let cacheLifetime: TimeInterval = 7 * 24 * 60 * 60

    private let session: URLSession
    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    private let maxCacheAge: TimeInterval

    /// Creates the rate service with injectable networking, preferences, time, and cache lifetime for testing.
    /// Negative cache lifetimes are treated as zero so cached quotes can never become valid unexpectedly.
    init(
        session: URLSession = FXService.makeDefaultSession(),
        defaults: UserDefaults = .standard,
        clock: @escaping @Sendable () -> Date = { Date() },
        maxCacheAge: TimeInterval = FXService.cacheLifetime
    ) {
        self.session = session
        self.defaults = defaults
        self.clock = clock
        self.maxCacheAge = max(0, maxCacheAge)
    }

    /// Creates a short-lived, non-persistent network session for rate requests.
    /// FX sits immediately after a potentially paid Gemini request, so a
    /// blackholed rates host must not hold that flow indefinitely.
    static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }

    /// Resolves a normalized currency pair using manual, live, then fresh-cache priority.
    /// Matching currencies return 1 immediately, while cancellation stops before a cache fallback.
    func rate(from rawFrom: String, to rawTo: String) async -> FXRate? {
        guard let from = Self.normalizedCurrencyCode(rawFrom),
              let to = Self.normalizedCurrencyCode(rawTo) else {
            return nil
        }

        let now = clock()
        if from == to {
            return FXRate(
                rate: 1,
                quoteDate: FXQuoteDate.string(from: now),
                fetchedAt: now,
                source: .live
            )
        }

        let overrideValue = defaults.double(forKey: Self.overrideKey(from: from, to: to))
        if overrideValue.isFinite, overrideValue > 0 {
            let legacyDate = defaults.object(
                forKey: Self.overrideDateKey(from: from, to: to)
            ) as? Date
            let storedQuoteDate = defaults.string(
                forKey: Self.overrideQuoteDateKey(from: from, to: to)
            )
            let quoteDate = Self.manualQuoteDate(
                storedQuoteDate: storedQuoteDate,
                legacyDate: legacyDate,
                fallback: now
            )
            return FXRate(
                rate: overrideValue,
                quoteDate: quoteDate,
                fetchedAt: legacyDate ?? now,
                source: .manual
            )
        }

        let cacheKey = Self.cacheKey(from: from, to: to)
        do {
            let live = try await fetchLive(from: from, to: to)
            let payload = CachedPayloadV2(
                version: 2,
                rate: live.rate,
                quoteDate: live.quoteDate,
                fetchedAt: now
            )
            if let data = try? JSONEncoder().encode(payload) {
                defaults.set(data, forKey: cacheKey)
            }
            return FXRate(
                rate: live.rate,
                quoteDate: live.quoteDate,
                fetchedAt: now,
                source: .live
            )
        } catch {
            guard !Task.isCancelled else { return nil }
        }

        // A live attempt can take long enough to cross the hard TTL. Read the
        // injected clock again instead of validating against its pre-flight
        // value, otherwise a cache entry can be returned after it expires.
        return cachedRate(forKey: cacheKey, now: clock())
    }

    /// Delegates manual-rate persistence to the small settings-safe store that shares this service's dependencies.
    func setManualOverride(_ rate: Double?, from rawFrom: String, to rawTo: String) {
        FXManualOverrideStore(defaults: defaults, clock: clock)
            .setManualOverride(rate, from: rawFrom, to: rawTo)
    }

    /// Downloads and strictly validates one Frankfurter quote before it can enter app state or the cache.
    private func fetchLive(
        from: String,
        to: String
    ) async throws -> (rate: Double, quoteDate: String) {
        guard let url = URL(
            string: "https://api.frankfurter.dev/v2/rate/\(from)/\(to)"
        ) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(FrankfurterV2Response.self, from: data)
        guard Self.normalizedCurrencyCode(decoded.base) == from,
              Self.normalizedCurrencyCode(decoded.quote) == to,
              decoded.rate.isFinite,
              decoded.rate > 0,
              FXQuoteDate.isCanonical(decoded.date) else {
            throw URLError(.cannotParseResponse)
        }
        return (decoded.rate, decoded.date)
    }

    /// Reads the current cache format first, then supports the older format during migration.
    /// Both formats must pass the same value, date, and age checks before being returned.
    private func cachedRate(forKey key: String, now: Date) -> FXRate? {
        guard let data = defaults.data(forKey: key) else { return nil }

        if let payload = try? JSONDecoder().decode(CachedPayloadV2.self, from: data),
           payload.version == 2,
           isUsableCachedRate(
               rate: payload.rate,
               quoteDate: payload.quoteDate,
               fetchedAt: payload.fetchedAt,
               now: now
           ) {
            return FXRate(
                rate: payload.rate,
                quoteDate: payload.quoteDate,
                fetchedAt: payload.fetchedAt,
                source: .cached
            )
        }

        // Legacy payload written by the v1 client. Date is converted to a
        // standard UTC date-only value, while fetchedAt still enforces cache expiry.
        if let legacy = try? JSONDecoder().decode(LegacyCachedPayload.self, from: data) {
            let quoteDate = FXQuoteDate.string(from: legacy.date)
            guard isUsableCachedRate(
                rate: legacy.rate,
                quoteDate: quoteDate,
                fetchedAt: legacy.fetchedAt,
                now: now
            ) else {
                return nil
            }
            return FXRate(
                rate: legacy.rate,
                quoteDate: quoteDate,
                fetchedAt: legacy.fetchedAt,
                source: .cached
            )
        }

        return nil
    }

    /// Accepts only positive finite rates with real quote dates and non-future fetch times within the cache limit.
    private func isUsableCachedRate(
        rate: Double,
        quoteDate: String,
        fetchedAt: Date,
        now: Date
    ) -> Bool {
        guard rate.isFinite, rate > 0, FXQuoteDate.isCanonical(quoteDate) else {
            return false
        }
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age <= maxCacheAge
    }

    /// Converts user or API input to an uppercase three-letter ISO-style code, rejecting every other shape.
    static func normalizedCurrencyCode(_ code: String) -> String? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.range(
            of: "^[A-Z]{3}$",
            options: .regularExpression
        ) != nil else {
            return nil
        }
        return normalized
    }

    /// During the compatibility window a new build writes both keys, while an
    /// old build only updates the legacy Date. If that old-build write is on a
    /// later UTC date, the date-only key is stale and must not win when the
    /// user returns to a new build.
    private static func manualQuoteDate(
        storedQuoteDate: String?,
        legacyDate: Date?,
        fallback: Date
    ) -> String {
        let canonicalStored = storedQuoteDate.flatMap {
            FXQuoteDate.isCanonical($0) ? $0 : nil
        }
        let legacyQuoteDate = legacyDate.map(FXQuoteDate.string(from:))

        switch (canonicalStored, legacyQuoteDate) {
        case let (stored?, legacy?):
            // Canonical ISO dates sort chronologically.
            return legacy > stored ? legacy : stored
        case let (stored?, nil):
            return stored
        case let (nil, legacy?):
            return legacy
        case (nil, nil):
            return FXQuoteDate.string(from: fallback)
        }
    }

    /// Builds the preference key for a manual conversion value.
    static func overrideKey(from: String, to: String) -> String {
        "fx.override.\(from).\(to)"
    }

    /// Builds the legacy preference key for the exact time a manual value was saved.
    static func overrideDateKey(from: String, to: String) -> String {
        "fx.override.date.\(from).\(to)"
    }

    /// Builds the preference key for a manual quote's timezone-safe market date.
    static func overrideQuoteDateKey(from: String, to: String) -> String {
        "fx.override.quoteDate.\(from).\(to)"
    }

    /// Builds the private preference key for a downloaded quote payload.
    private static func cacheKey(from: String, to: String) -> String {
        "fx.cache.\(from).\(to)"
    }
}

/// The exact fields expected from Frankfurter's version-two rate endpoint.
private struct FrankfurterV2Response: Decodable {
    let date: String
    let base: String
    let quote: String
    let rate: Double
}

/// The current cached representation, separating market date from download time.
private struct CachedPayloadV2: Codable {
    let version: Int
    let rate: Double
    let quoteDate: String
    let fetchedAt: Date
}

/// The previous cache representation retained only so existing installations can read old data safely.
private struct LegacyCachedPayload: Codable {
    let rate: Double
    let date: Date
    let fetchedAt: Date
}
