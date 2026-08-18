// Verifies how Gemini networking turns HTTP and connection failures into safe, actionable app errors.
// A scripted URLProtocol replaces the internet so status codes, headers, malformed
// bodies, and secret-leak attempts are predictable.

import Foundation
import Testing
@testable import Menuscript

/// A test-only URLSession interceptor that returns configurable responses while recording the outgoing request.
private final class GeminiURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var headers: [String: String] = [:]
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var networkError: Error?
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var lastRequest: URLRequest?

    /// Intercepts every request because the injected session exists only for this transport suite.
    override class func canInit(with request: URLRequest) -> Bool { true }
    /// Preserves the original request so header and URL privacy assertions see the exact provider output.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Delivers the configured network error or HTTP response through URLSession's standard callback sequence.
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

    /// Requires no cancellation cleanup because the fake completes immediately.
    override func stopLoading() {}
}

/// Embeds a secret in user-facing and debug descriptions to confirm transport errors
/// remove sensitive values before leaving the service.
private struct SecretBearingTransportError: LocalizedError, CustomStringConvertible {
    let secret: String

    /// Simulates unsafe text that a third-party networking error might expose to the interface.
    var errorDescription: String? { "transport failed with API key \(secret)" }
    /// Simulates unsafe diagnostic text that must also be discarded.
    var description: String { "debug transport error containing \(secret)" }
}

/// Regression coverage for Gemini's HTTP classification, retry timing, and credential-safe error handling.
/// The suite is serialized because its URLProtocol fake is configured through shared static state.
@Suite("Gemini transport", .serialized)
final class GeminiTransportTests {
    private let session: URLSession

    /// Creates an ephemeral session wired only to the fake transport and resets all scripted state.
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiURLProtocol.self]
        session = URLSession(configuration: configuration)
        reset()
    }

    /// Protects the status rules that drive distinct Settings, billing, permission,
    /// retry, and payload guidance.
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

    /// Confirms rate limits preserve valid server wait times in both supported header
    /// formats and remain safe when no wait time is supplied.
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

    /// Ensures a trimmed key stays only in its header even when Google's returned message deliberately echoes it.
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

    /// Ensures a huge, unreadable error body gets limited parsing and cannot replace the
    /// safe status-based message.
    @Test("Oversized or malformed error bodies stay bounded to status fallback")
    func malformedEnvelopeFallback() async throws {
        install(
            status: 400,
            body: Data(repeating: 0x41, count: 2_000_000)
        )
        #expect(try await requestError() == .invalidRequest)
    }

    /// Confirms ordinary connection failures become a known network category without retaining credential text.
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

    /// Proves even a custom error that embeds the key in every description is replaced by fixed, secret-free wording.
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

    /// Defines the small allowlist of connection messages that may safely reach UI and diagnostics.
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

    /// Performs one expected-to-fail explanation request and returns the provider's typed error for concise assertions.
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

    /// Programs the fake transport with one status, body, and optional header set, clearing previous state first.
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

    /// Restores neutral fake-network values so test cases cannot affect one another.
    private func reset() {
        GeminiURLProtocol.statusCode = 200
        GeminiURLProtocol.headers = [:]
        GeminiURLProtocol.responseData = Data()
        GeminiURLProtocol.networkError = nil
        GeminiURLProtocol.requestCount = 0
        GeminiURLProtocol.lastRequest = nil
    }
}
