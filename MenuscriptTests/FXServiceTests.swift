import Foundation
import Testing
@testable import Menuscript

private final class FXURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var lastURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastURL = request.url
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class SequencedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(_ dates: [Date]) {
        precondition(!dates.isEmpty)
        self.dates = dates
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        if dates.count > 1 {
            return dates.removeFirst()
        }
        return dates[0]
    }
}

@Suite("FX services", .serialized)
final class FXServiceTests {
    private struct CacheV2: Codable {
        let version: Int
        let rate: Double
        let quoteDate: String
        let fetchedAt: Date
    }

    private struct LegacyCache: Codable {
        let rate: Double
        let date: Date
        let fetchedAt: Date
    }

    private let suiteName = "FXServiceTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let session: URLSession
    private let now = FXQuoteDate.date(from: "2026-07-15")!

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FXURLProtocol.self]
        session = URLSession(configuration: configuration)
        resetTransport()
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Frankfurter v2 supports TWD and validates the echoed pair")
    func v2TWDLiveQuote() async throws {
        installResponse(
            #"{"date":"2026-07-14","base":"JPY","quote":"TWD","rate":0.1902}"#
        )

        let quote = try #require(await makeService().rate(from: " jpy ", to: "twd"))
        #expect(quote.rate == 0.1902)
        #expect(quote.quoteDate == "2026-07-14")
        #expect(quote.fetchedAt == now)
        #expect(quote.source == .live)
        #expect(FXURLProtocol.lastURL?.path == "/v2/rate/JPY/TWD")
        #expect(FXURLProtocol.lastURL?.query == nil)
    }

    @Test("Live quote writes a versioned date-only cache")
    func liveQuoteWritesV2Cache() async throws {
        installResponse(
            #"{"date":"2026-07-14","base":"USD","quote":"JPY","rate":160.5}"#
        )
        _ = await makeService().rate(from: "USD", to: "JPY")

        let data = try #require(defaults.data(forKey: "fx.cache.USD.JPY"))
        let cached = try JSONDecoder().decode(CacheV2.self, from: data)
        #expect(cached.version == 2)
        #expect(cached.rate == 160.5)
        #expect(cached.quoteDate == "2026-07-14")
        #expect(cached.fetchedAt == now)
    }

    @Test("Mismatched pair, invalid rate and malformed date are rejected")
    func rejectsMalformedLiveQuotes() async {
        let invalidResponses = [
            #"{"date":"2026-07-14","base":"EUR","quote":"TWD","rate":0.1902}"#,
            #"{"date":"2026-07-14","base":"JPY","quote":"USD","rate":0.1902}"#,
            #"{"date":"2026-07-14","base":"JPY","quote":"TWD","rate":0}"#,
            #"{"date":"2026-7-14","base":"JPY","quote":"TWD","rate":0.1902}"#,
        ]

        for json in invalidResponses {
            installResponse(json)
            #expect(await makeService().rate(from: "JPY", to: "TWD") == nil)
        }
    }

    @Test("Canonical provider date is preserved even when ahead of the local calendar")
    func providerDateMayLeadLocalCalendar() async throws {
        installResponse(
            #"{"date":"2026-07-16","base":"JPY","quote":"TWD","rate":0.19835}"#
        )
        let quote = try #require(await makeService().rate(from: "JPY", to: "TWD"))
        #expect(quote.quoteDate == "2026-07-16")
        #expect(quote.rate == 0.19835)
    }

    @Test("Fresh cache is accepted through the seven-day boundary, then expires")
    func cacheTTLBoundaries() async throws {
        let fetchedAt = now.addingTimeInterval(-FXService.cacheLifetime)
        try seedV2Cache(
            rate: 150,
            quoteDate: "2026-07-10",
            fetchedAt: fetchedAt
        )
        installFailure()

        let boundary = try #require(await makeService().rate(from: "USD", to: "JPY"))
        #expect(boundary.source == .cached)
        #expect(boundary.rate == 150)

        let afterBoundary = now.addingTimeInterval(0.001)
        let expired = await makeService(now: afterBoundary).rate(from: "USD", to: "JPY")
        #expect(expired == nil)
    }

    @Test("Future-dated cache metadata is rejected")
    func futureFetchedAtIsRejected() async throws {
        try seedV2Cache(
            rate: 150,
            quoteDate: "2026-07-10",
            fetchedAt: now.addingTimeInterval(1)
        )
        installFailure()
        #expect(await makeService().rate(from: "USD", to: "JPY") == nil)
    }

    @Test("Legacy cache payload decodes while still obeying TTL")
    func legacyCacheCompatibility() async throws {
        let legacyDate = try #require(FXQuoteDate.date(from: "2026-07-12"))
        let payload = LegacyCache(
            rate: 151,
            date: legacyDate,
            fetchedAt: now.addingTimeInterval(-60)
        )
        defaults.set(
            try JSONEncoder().encode(payload),
            forKey: "fx.cache.USD.JPY"
        )
        installFailure()

        let quote = try #require(await makeService().rate(from: "USD", to: "JPY"))
        #expect(quote.source == .cached)
        #expect(quote.rate == 151)
        #expect(quote.quoteDate == "2026-07-12")
        #expect(quote.fetchedAt == now.addingTimeInterval(-60))
    }

    @Test("Stale legacy cache payload is rejected")
    func staleLegacyCacheIsRejected() async throws {
        let legacyDate = try #require(FXQuoteDate.date(from: "2026-07-01"))
        let payload = LegacyCache(
            rate: 151,
            date: legacyDate,
            fetchedAt: now.addingTimeInterval(-FXService.cacheLifetime - 1)
        )
        defaults.set(
            try JSONEncoder().encode(payload),
            forKey: "fx.cache.USD.JPY"
        )
        installFailure()

        #expect(await makeService().rate(from: "USD", to: "JPY") == nil)
    }

    @Test("Cache fallback re-reads the clock after a failed live attempt")
    func fallbackUsesPostFailureTimeForTTL() async throws {
        try seedV2Cache(
            rate: 150,
            quoteDate: "2026-07-10",
            fetchedAt: now.addingTimeInterval(-FXService.cacheLifetime)
        )
        installFailure()
        let clock = SequencedClock([now, now.addingTimeInterval(1)])
        let service = FXService(
            session: session,
            defaults: defaults,
            clock: { clock.now() }
        )

        #expect(await service.rate(from: "USD", to: "JPY") == nil)
        #expect(FXURLProtocol.requestCount == 1)
    }

    @Test("Manual override remains date-only and wins without network")
    func manualOverrideWins() async throws {
        let service = makeService()
        service.setManualOverride(999, from: " usd ", to: "jpy")
        installFailure()

        let quote = try #require(await service.rate(from: "USD", to: "JPY"))
        #expect(quote.source == .manual)
        #expect(quote.rate == 999)
        #expect(quote.quoteDate == "2026-07-15")
        #expect(FXURLProtocol.requestCount == 0)

        service.setManualOverride(nil, from: "USD", to: "JPY")
        #expect(defaults.object(forKey: "fx.override.USD.JPY") == nil)
        #expect(defaults.object(forKey: "fx.override.quoteDate.USD.JPY") == nil)
    }

    @Test("Legacy manual override Date is converted to canonical UTC date")
    func legacyManualDateCompatibility() async throws {
        let legacyDate = try #require(FXQuoteDate.date(from: "2023-11-14"))
        defaults.set(999, forKey: "fx.override.USD.JPY")
        defaults.set(legacyDate, forKey: "fx.override.date.USD.JPY")

        let quote = try #require(await makeService().rate(from: "USD", to: "JPY"))
        #expect(quote.quoteDate == "2023-11-14")
        #expect(quote.date == legacyDate)
    }

    @Test("New-old-new manual override prefers a newer legacy write date")
    func newerLegacyManualWriteWinsOverStaleQuoteDate() async throws {
        let initialNewDate = try #require(FXQuoteDate.date(from: "2026-07-10"))
        let laterOldBuildWrite = try #require(FXQuoteDate.date(from: "2026-07-12"))

        // New build writes both formats.
        makeService(now: initialNewDate).setManualOverride(
            900,
            from: "USD",
            to: "JPY"
        )
        #expect(defaults.string(forKey: "fx.override.quoteDate.USD.JPY") == "2026-07-10")

        // Old build then changes only the value and legacy Date, leaving the
        // newer format stale. Returning to a new build must surface this write.
        defaults.set(999, forKey: "fx.override.USD.JPY")
        defaults.set(laterOldBuildWrite, forKey: "fx.override.date.USD.JPY")

        let quote = try #require(await makeService(now: laterOldBuildWrite).rate(
            from: "USD",
            to: "JPY"
        ))
        #expect(quote.rate == 999)
        #expect(quote.quoteDate == "2026-07-12")
        #expect(quote.fetchedAt == laterOldBuildWrite)
        #expect(FXURLProtocol.requestCount == 0)
    }

    @Test("Same known currency short-circuits without network")
    func sameCurrencyShortCircuits() async throws {
        installFailure()
        let quote = try #require(await makeService().rate(from: "usd", to: "USD"))
        #expect(quote.rate == 1)
        #expect(quote.quoteDate == "2026-07-15")
        #expect(quote.source == .live)
        #expect(FXURLProtocol.requestCount == 0)
    }

    @Test("Invalid free-text currency codes never reach URLSession or defaults")
    func invalidCodesAreRejectedEarly() async {
        installFailure()
        #expect(await makeService().rate(from: "USD/JPY", to: "TWD") == nil)
        #expect(await makeService().rate(from: "US", to: "TWD") == nil)
        #expect(FXURLProtocol.requestCount == 0)
    }

    @Test("Quote-date conversion is invariant to the process default timezone")
    func quoteDateIgnoresDefaultTimezone() {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }

        for identifier in ["Pacific/Honolulu", "America/Los_Angeles", "Asia/Tokyo"] {
            NSTimeZone.default = TimeZone(identifier: identifier)!
            #expect(FXQuoteDate.string(from: now) == "2026-07-15")
            #expect(FXQuoteDate.date(from: "2026-07-15") == now)
        }
    }

    @Test("Default live session has bounded timeouts")
    func defaultSessionHasTimeouts() {
        let configuration = FXService.makeDefaultSession().configuration
        #expect(configuration.timeoutIntervalForRequest == 10)
        #expect(configuration.timeoutIntervalForResource == 15)
    }

    @Test("Mock FX derives deterministic cross-rates including TWD")
    func mockFXCrossRates() async throws {
        let service = MockFXService()
        let jpyTWD = try #require(await service.rate(from: "JPY", to: "TWD"))
        let twdJPY = try #require(await service.rate(from: "TWD", to: "JPY"))

        #expect(jpyTWD.source == .mock)
        #expect(jpyTWD.quoteDate == MockFXService.fixedQuoteDate)
        #expect(abs(jpyTWD.rate * twdJPY.rate - 1) < 0.000_000_1)
        #expect(await service.rate(from: "ZZZ", to: "USD") == nil)
        #expect(await service.rate(from: "ZZZ", to: "ZZZ") == nil)
    }

    @Test("Mock FX supports the required demo travel currencies with stable cross-rates")
    func mockFXSupportsRequiredTravelCurrencies() async throws {
        let service = MockFXService()
        let expectedUSDQuotes: [String: Double] = [
            "PHP": 58.5,
            "INR": 86.5,
            "IDR": 16_300,
            "MYR": 4.45,
            "NZD": 1.66,
            "DKK": 6.86,
            "NOK": 11,
            "SEK": 10.5,
            "PLN": 3.95,
            "CZK": 23,
            "TRY": 36,
            "AED": 3.6725,
            "SAR": 3.75,
            "BRL": 5.80,
            "ZAR": 18.5,
        ]

        for (currency, expectedRate) in expectedUSDQuotes {
            let quote = try #require(await service.rate(from: "USD", to: currency))
            #expect(quote.rate == expectedRate)
            #expect(quote.source == .mock)
            #expect(quote.quoteDate == MockFXService.fixedQuoteDate)
            #expect(quote.rate.isFinite)
            #expect(quote.rate > 0)
        }

        let jpyToPHP = try #require(await service.rate(from: "JPY", to: "PHP"))
        #expect(jpyToPHP.rate == 0.365625)
        #expect(jpyToPHP.source == .mock)
        #expect(jpyToPHP.quoteDate == MockFXService.fixedQuoteDate)
        #expect(jpyToPHP.rate.isFinite)
        #expect(jpyToPHP.rate > 0)

        let phpToINR = try #require(await service.rate(from: "PHP", to: "INR"))
        let inrToNZD = try #require(await service.rate(from: "INR", to: "NZD"))
        let phpToNZD = try #require(await service.rate(from: "PHP", to: "NZD"))
        #expect(abs((phpToINR.rate * inrToNZD.rate) - phpToNZD.rate) < 0.000_000_000_001)
    }

    private func makeService(
        now currentTime: Date? = nil
    ) -> FXService {
        let time = currentTime ?? now
        return FXService(
            session: session,
            defaults: defaults,
            clock: { time }
        )
    }

    private func installResponse(_ json: String, statusCode: Int = 200) {
        resetTransport()
        FXURLProtocol.requestHandler = { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                  ) else {
                throw URLError(.badServerResponse)
            }
            return (response, Data(json.utf8))
        }
    }

    private func installFailure() {
        resetTransport()
        FXURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }
    }

    private func resetTransport() {
        FXURLProtocol.requestHandler = nil
        FXURLProtocol.requestCount = 0
        FXURLProtocol.lastURL = nil
    }

    private func seedV2Cache(
        rate: Double,
        quoteDate: String,
        fetchedAt: Date
    ) throws {
        let payload = CacheV2(
            version: 2,
            rate: rate,
            quoteDate: quoteDate,
            fetchedAt: fetchedAt
        )
        defaults.set(
            try JSONEncoder().encode(payload),
            forKey: "fx.cache.USD.JPY"
        )
    }
}
