import Foundation
import Testing
@testable import Menuscript

private final class GeminiURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var headers: [String: String] = [:]
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var networkError: Error?
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastRequest = request
        if let networkError = Self.networkError {
            client?.urlProtocol(self, didFailWithError: networkError)
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: Self.statusCode,
                httpVersion: nil,
                headerFields: Self.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct SecretBearingTransportError: LocalizedError, CustomStringConvertible {
    let secret: String

    var errorDescription: String? { "transport failed with API key \(secret)" }
    var description: String { "debug transport error containing \(secret)" }
}

@Suite("Gemini transport", .serialized)
final class GeminiTransportTests {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiURLProtocol.self]
        session = URLSession(configuration: configuration)
        reset()
    }

    @Test("Google error envelope maps to actionable typed failures")
    func statusMatrix() async throws {
        let cases: [(Int, String, [String: String], VisionProviderError)] = [
            (
                401,
                #"{"error":{"code":401,"message":"Authentication required","status":"UNAUTHENTICATED"}}"#,
                [:],
                .invalidAPIKey
            ),
            (
                400,
                #"{"error":{"code":400,"message":"API key not valid","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#,
                [:],
                .invalidAPIKey
            ),
            (
                400,
                #"{"error":{"code":400,"message":"Malformed generation config","status":"INVALID_ARGUMENT"}}"#,
                [:],
                .invalidRequest
            ),
            (
                403,
                #"{"error":{"code":403,"message":"Caller lacks permission","status":"PERMISSION_DENIED"}}"#,
                [:],
                .permissionDenied
            ),
            (
                400,
                #"{"error":{"code":400,"message":"Billing account is not enabled","status":"FAILED_PRECONDITION","details":[{"reason":"BILLING_DISABLED"}]}}"#,
                [:],
                .billingRequired
            ),
            (
                429,
                #"{"error":{"code":429,"message":"Quota exceeded","status":"RESOURCE_EXHAUSTED","details":[{"reason":"RATE_LIMIT_QUOTA_EXCEEDED"}]}}"#,
                ["Retry-After": "15"],
                .quotaExceeded(retryAfter: 15)
            ),
            (
                404,
                #"{"error":{"code":404,"message":"Requested model was not found","status":"NOT_FOUND"}}"#,
                [:],
                .modelUnavailable
            ),
            (
                503,
                #"{"error":{"code":503,"message":"API key not valid","status":"UNAUTHENTICATED","details":[{"reason":"API_KEY_INVALID"}]}}"#,
                [:],
                .serviceUnavailable
            ),
            (413, "{}", [:], .payloadTooLarge),
            (418, "{}", [:], .http(418)),
        ]

        for (status, body, headers, expected) in cases {
            install(status: status, body: Data(body.utf8), headers: headers)
            let error = try await requestError()
            #expect(error == expected)
            #expect(GeminiURLProtocol.requestCount == 1)
        }
    }

    @Test("Plain 429 preserves numeric and HTTP-date Retry-After when possible")
    func retryAfter() async throws {
        install(status: 429, body: Data(), headers: ["Retry-After": "30"])
        #expect(try await requestError() == .rateLimitedWithRetryAfter(30))

        install(status: 429, body: Data(), headers: [:])
        #expect(try await requestError() == .rateLimited)

        let fixedNow = try #require(FXQuoteDate.date(from: "2026-07-15"))
        let httpDate = GeminiProvider.transportError(
            statusCode: 429,
            retryAfterHeader: "Wed, 15 Jul 2026 00:01:00 GMT",
            data: Data(),
            now: fixedNow
        )
        #expect(httpDate == .rateLimitedWithRetryAfter(60))
    }

    @Test("API key is trimmed and cannot leak through URL or server error")
    func keyNeverLeaks() async throws {
        let secret = "sensitive-key-material"
        install(
            status: 400,
            body: Data(
                #"{"error":{"code":400,"message":"API key sensitive-key-material not valid","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"#.utf8
            )
        )

        let error = try await requestError(key: " \n\(secret)\t ")
        #expect(error == .invalidAPIKey)
        #expect(error.errorDescription?.contains(secret) == false)
        #expect(String(describing: error).contains(secret) == false)

        let request = try #require(GeminiURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == secret)
        #expect(request.url?.absoluteString.contains(secret) == false)
        #expect(request.url?.query == nil)
    }

    @Test("Oversized or malformed error bodies stay bounded to status fallback")
    func malformedEnvelopeFallback() async throws {
        install(
            status: 400,
            body: Data(repeating: 0x41, count: 2_000_000)
        )
        #expect(try await requestError() == .invalidRequest)
    }

    @Test("URLSession failures map to typed network errors without key material")
    func networkFailure() async throws {
        reset()
        GeminiURLProtocol.networkError = URLError(.notConnectedToInternet)
        let error = try await requestError(key: "network-secret")
        guard case .network(let detail) = error else {
            Issue.record("Expected typed network error, got \(error)")
            return
        }
        #expect(detail.contains("network-secret") == false)
        #expect(error.errorDescription?.contains("network-secret") == false)
    }

    @Test("Arbitrary transport error text containing an API key is discarded")
    func customNetworkFailureCannotRetainSecret() async throws {
        let secret = "sentinel-api-key-must-not-survive"
        reset()
        GeminiURLProtocol.networkError = SecretBearingTransportError(secret: secret)

        let error = try await requestError(key: secret)
        guard case .network(let detail) = error else {
            Issue.record("Expected typed network error, got \(error)")
            return
        }
        #expect(detail == "network request failed")
        #expect(detail.contains(secret) == false)
        #expect(error.errorDescription?.contains(secret) == false)
        #expect(String(describing: error).contains(secret) == false)
    }

    @Test("Known URL error codes map to fixed safe messages")
    func safeURLFailureMapping() {
        #expect(GeminiProvider.safeNetworkMessage(for: .notConnectedToInternet) == "offline")
        #expect(GeminiProvider.safeNetworkMessage(for: .timedOut) == "request timed out")
        #expect(GeminiProvider.safeNetworkMessage(for: .networkConnectionLost) == "connection lost")
        #expect(GeminiProvider.safeNetworkMessage(for: .cannotConnectToHost) == "service unreachable")
        #expect(GeminiProvider.safeNetworkMessage(for: .cancelled) == "request cancelled")
        #expect(GeminiProvider.safeNetworkMessage(for: .unknown) == "network request failed")
        #expect(GeminiProvider.safeNetworkMessage(for: nil) == "network request failed")
    }

    private func requestError(key: String = "test-key") async throws -> VisionProviderError {
        let provider = GeminiProvider(
            apiKey: { key },
            session: session
        )
        do {
            _ = try await provider.explainDish(
                original: "唐揚げ",
                language: "Japanese",
                targetLanguage: "English"
            )
            Issue.record("Expected Gemini request to fail")
            return .http(-1)
        } catch let error as VisionProviderError {
            return error
        }
    }

    private func install(
        status: Int,
        body: Data,
        headers: [String: String] = [:]
    ) {
        reset()
        GeminiURLProtocol.statusCode = status
        GeminiURLProtocol.responseData = body
        GeminiURLProtocol.headers = headers
    }

    private func reset() {
        GeminiURLProtocol.statusCode = 200
        GeminiURLProtocol.headers = [:]
        GeminiURLProtocol.responseData = Data()
        GeminiURLProtocol.networkError = nil
        GeminiURLProtocol.requestCount = 0
        GeminiURLProtocol.lastRequest = nil
    }
}
