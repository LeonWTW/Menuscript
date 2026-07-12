import XCTest
@testable import Menuscript

/// Tests for `GeminiProvider.buildExtractRequest` / `buildExplainRequest` — pure functions, no network.
final class GeminiRequestTests: XCTestCase {

    private let imageA = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01])
    private let imageB = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x02])

    private func makeProvider(key: String? = "test-key-123") -> GeminiProvider {
        GeminiProvider(apiKey: { key })
    }

    private func bodyJSON(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func parts(of request: URLRequest) throws -> [[String: Any]] {
        let body = try bodyJSON(of: request)
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1, "all photos merge into one user turn")
        return try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
    }

    func testURLContainsModelIdAndGenerateContent() throws {
        let request = try makeProvider().buildExtractRequest(images: [imageA], targetLanguage: "繁體中文")
        let url = try XCTUnwrap(request.url?.absoluteString)

        XCTAssertTrue(url.contains("generativelanguage.googleapis.com"))
        XCTAssertTrue(url.contains("gemini-2.5-flash"), "URL must contain the model id")
        XCTAssertTrue(url.hasSuffix(":generateContent"))
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testCustomModelIdAppearsInURL() throws {
        let provider = GeminiProvider(apiKey: { "k" }, model: "gemini-2.5-pro")
        let request = try provider.buildExtractRequest(images: [imageA], targetLanguage: "繁體中文")
        XCTAssertTrue(try XCTUnwrap(request.url?.absoluteString).contains("gemini-2.5-pro"))
    }

    func testAPIKeyInHeaderOnlyNeverInURL() throws {
        let request = try makeProvider(key: "test-key-123").buildExtractRequest(images: [imageA], targetLanguage: "繁體中文")

        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key-123")

        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertFalse(url.contains("test-key-123"), "API key must never appear in the URL")
        XCTAssertFalse(url.lowercased().contains("key="), "no key query parameter allowed")
        XCTAssertNil(URLComponents(string: url)?.queryItems)
    }

    func testBodyHasOneInlineDataPartPerImagePlusOneTextPart() throws {
        let request = try makeProvider().buildExtractRequest(images: [imageA, imageB], targetLanguage: "繁體中文")
        let parts = try parts(of: request)

        XCTAssertEqual(parts.count, 3, "2 images + 1 text part")

        for (index, image) in [imageA, imageB].enumerated() {
            let inline = try XCTUnwrap(parts[index]["inline_data"] as? [String: Any], "part \(index) should be inline_data")
            XCTAssertEqual(inline["mime_type"] as? String, "image/jpeg")
            XCTAssertEqual(inline["data"] as? String, image.base64EncodedString())
        }

        let text = try XCTUnwrap(parts[2]["text"] as? String, "last part should be the prompt text")
        XCTAssertTrue(text.contains("繁體中文"), "prompt must carry the target language")
        XCTAssertNil(parts[2]["inline_data"])
    }

    func testGenerationConfigRequestsStructuredJSON() throws {
        let request = try makeProvider().buildExtractRequest(images: [imageA], targetLanguage: "繁體中文")
        let body = try bodyJSON(of: request)
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])

        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        XCTAssertEqual(try XCTUnwrap(config["temperature"] as? Double), 0.2, accuracy: 0.0001)

        let schema = try XCTUnwrap(config["responseSchema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "OBJECT")

        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let itemsSchema = try XCTUnwrap(properties["items"] as? [String: Any])
        XCTAssertEqual(itemsSchema["type"] as? String, "ARRAY")

        let itemSchema = try XCTUnwrap(itemsSchema["items"] as? [String: Any])
        let itemProperties = try XCTUnwrap(itemSchema["properties"] as? [String: Any])
        let priceSchema = try XCTUnwrap(itemProperties["price"] as? [String: Any])
        XCTAssertEqual(priceSchema["type"] as? String, "STRING", "price rides the wire as STRING and is parsed to Decimal in Swift")
    }

    func testMissingAPIKeyThrownBeforeAnyNetwork() {
        XCTAssertThrowsError(try makeProvider(key: nil).buildExtractRequest(images: [imageA], targetLanguage: "繁體中文")) { error in
            XCTAssertEqual(error as? VisionProviderError, .missingAPIKey)
        }
        // Empty string counts as missing too.
        XCTAssertThrowsError(try makeProvider(key: "").buildExtractRequest(images: [imageA], targetLanguage: "繁體中文")) { error in
            XCTAssertEqual(error as? VisionProviderError, .missingAPIKey)
        }
        XCTAssertThrowsError(try makeProvider(key: nil).buildExplainRequest(original: "焼き鳥", language: "日文", targetLanguage: "繁體中文")) { error in
            XCTAssertEqual(error as? VisionProviderError, .missingAPIKey)
        }
    }

    func testEmptyImagesThrowsInvalidImage() {
        XCTAssertThrowsError(try makeProvider().buildExtractRequest(images: [], targetLanguage: "繁體中文")) { error in
            XCTAssertEqual(error as? VisionProviderError, .invalidImage)
        }
    }

    func testCorrectiveSuffixIsAppendedToPromptOnRetryBuild() throws {
        let suffix = "Your previous output failed to parse: missing key 'items' at root. Return ONLY valid JSON matching the schema."
        let request = try makeProvider().buildExtractRequest(
            images: [imageA],
            targetLanguage: "繁體中文",
            correctiveSuffix: suffix
        )
        let parts = try parts(of: request)
        let text = try XCTUnwrap(parts.last?["text"] as? String)
        XCTAssertTrue(text.hasSuffix(suffix))
    }

    func testExplainRequestIsPlainTextWithDishAndLanguages() throws {
        let request = try makeProvider().buildExplainRequest(original: "焼き鳥", language: "日文", targetLanguage: "繁體中文")

        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-key-123")
        XCTAssertFalse(try XCTUnwrap(request.url?.absoluteString).contains("test-key-123"))

        let body = try bodyJSON(of: request)
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 1)

        let text = try XCTUnwrap(parts[0]["text"] as? String)
        XCTAssertTrue(text.contains("焼き鳥"))
        XCTAssertTrue(text.contains("日文"))
        XCTAssertTrue(text.contains("繁體中文"))

        // Plain text response: no JSON mime type, no schema.
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertNil(config["responseMimeType"])
        XCTAssertNil(config["responseSchema"])
    }
}
