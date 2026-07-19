import Foundation
import Testing
@testable import Menuscript

/// Intercepts URLSession traffic so FXServiceTests never touches the network.
private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.requestCount += 1
        guard let handler = MockURLProtocol.requestHandler else {
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

@Suite(.serialized)
final class FXServiceTests {
    private let suiteName = "FXServiceTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let service: FXService

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        service = FXService(session: session, defaults: defaults)

        MockURLProtocol.requestHandler = nil
        MockURLProtocol.requestCount = 0
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Live success returns .live and caches the rate")
    func liveSuccessCachesRate() async throws {
        MockURLProtocol.requestHandler = { request in
            let url = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            )
            let json = #"{"date":"2026-07-01","rates":{"JPY":170.5}}"#
            return (response, Data(json.utf8))
        }

        let rate = try #require(await service.rate(from: "usd", to: "jpy"))
        #expect(rate.source == .live)
        #expect(rate.rate == 170.5)
        #expect(MockURLProtocol.requestCount == 1)

        let cachedData = try #require(defaults.data(forKey: "fx.cache.USD.JPY"))
        let cachedJSON = try #require(
            JSONSerialization.jsonObject(with: cachedData) as? [String: Any]
        )
        #expect(cachedJSON["rate"] as? Double == 170.5)
    }

    @Test("Network failure with an existing cache falls back to the cached rate")
    func networkFailureFallsBackToCache() async throws {
        let seeded = ["rate": 150.0, "date": 0.0, "fetchedAt": 0.0]
        let seededData = try JSONSerialization.data(withJSONObject: seeded)
        defaults.set(seededData, forKey: "fx.cache.USD.JPY")

        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let rate = try #require(await service.rate(from: "USD", to: "JPY"))
        #expect(rate.source == .cached)
        #expect(rate.rate == 150.0)
    }

    @Test("Manual override wins over live and cache")
    func manualOverrideWins() async throws {
        let seeded = ["rate": 150.0, "date": 0.0, "fetchedAt": 0.0]
        let seededData = try JSONSerialization.data(withJSONObject: seeded)
        defaults.set(seededData, forKey: "fx.cache.USD.JPY")

        service.setManualOverride(999.0, from: "USD", to: "JPY")

        MockURLProtocol.requestHandler = { _ in
            throw URLError(.unknown) // must never be called
        }

        let rate = try #require(await service.rate(from: "USD", to: "JPY"))
        #expect(rate.source == .manual)
        #expect(rate.rate == 999.0)
        #expect(MockURLProtocol.requestCount == 0)

        service.setManualOverride(nil, from: "USD", to: "JPY")
        let overrideValue = defaults.double(forKey: "fx.override.USD.JPY")
        #expect(overrideValue == 0)
    }

    @Test("Same currency short-circuits to 1.0 without hitting the network")
    func sameCurrencyShortCircuits() async throws {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.unknown) // must never be called
        }

        let rate = try #require(await service.rate(from: "usd", to: "USD"))
        #expect(rate.rate == 1.0)
        #expect(rate.source == .live)
        #expect(MockURLProtocol.requestCount == 0)
    }

    @Test("Default session enforces a 10s request timeout and 15s resource timeout")
    func defaultSessionHasTimeouts() {
        let configuration = FXService.makeDefaultSession().configuration
        #expect(configuration.timeoutIntervalForRequest == 10)
        #expect(configuration.timeoutIntervalForResource == 15)
    }

    @Test("Manual override surfaces the date it was set, not the date it's read")
    func manualOverrideReturnsSetDate() async throws {
        let setDate = Date(timeIntervalSince1970: 1_700_000_000)
        defaults.set(999.0, forKey: "fx.override.USD.JPY")
        defaults.set(setDate, forKey: "fx.override.date.USD.JPY")

        let rate = try #require(await service.rate(from: "USD", to: "JPY"))
        #expect(rate.source == .manual)
        #expect(rate.date == setDate)
    }

    @Test("Legacy override without a stored timestamp falls back to the current date")
    func legacyOverrideWithoutTimestampFallsBackToNow() async throws {
        defaults.set(999.0, forKey: "fx.override.USD.JPY")

        let before = Date()
        let rate = try #require(await service.rate(from: "USD", to: "JPY"))
        let after = Date()

        #expect(rate.source == .manual)
        #expect(rate.date >= before && rate.date <= after)
    }
}
