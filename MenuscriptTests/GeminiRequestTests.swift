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

    /// The prompt text (last part) of an extract request.
    private func promptText(of request: URLRequest) throws -> String {
        try XCTUnwrap(try parts(of: request).last?["text"] as? String)
    }

    /// Navigates body → generationConfig.responseSchema → items.items (the per-dish OBJECT schema).
    private func itemSchema(of request: URLRequest) throws -> [String: Any] {
        let body = try bodyJSON(of: request)
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        let schema = try XCTUnwrap(config["responseSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let itemsSchema = try XCTUnwrap(properties["items"] as? [String: Any])
        return try XCTUnwrap(itemsSchema["items"] as? [String: Any])
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

    func testAPIKeyIsTrimmedBeforeEnteringHeader() throws {
        let request = try makeProvider(key: " \n test-key-123 \t").buildExtractRequest(
            images: [imageA],
            targetLanguage: "English"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-goog-api-key"),
            "test-key-123"
        )
        XCTAssertFalse(try XCTUnwrap(request.url?.absoluteString).contains("test-key-123"))
    }

    func testFinalSerializedBodyCannotExceed18MB() {
        XCTAssertEqual(GeminiProvider.maximumRequestBodyBytes, 18_000_000)
        // Base64 expands 13.5 MB to exactly 18 MB before JSON/prompt overhead,
        // so the final serialized request must be rejected.
        let largeImage = Data(repeating: 0xAB, count: 13_500_000)
        XCTAssertThrowsError(try makeProvider().buildExtractRequest(
            images: [largeImage],
            targetLanguage: "English"
        )) { error in
            XCTAssertEqual(error as? VisionProviderError, .payloadTooLarge)
        }
    }

    func testSerializedBodyBoundaryAllowsExactly18MBAndRejectsOneByteMore() throws {
        let exactLimit = Data(count: GeminiProvider.maximumRequestBodyBytes)
        XCTAssertEqual(
            try GeminiProvider.validateSerializedRequestBody(exactLimit).count,
            18_000_000
        )

        let oneByteOver = Data(count: GeminiProvider.maximumRequestBodyBytes + 1)
        XCTAssertThrowsError(
            try GeminiProvider.validateSerializedRequestBody(oneByteOver)
        ) { error in
            XCTAssertEqual(error as? VisionProviderError, .payloadTooLarge)
        }
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

    // MARK: - Allergen & summary extraction contract

    func testAllergenRuleAndListPresentOnlyWhenAllergensNonEmpty() throws {
        let withAllergens = try makeProvider().buildExtractRequest(
            images: [imageA], targetLanguage: "繁體中文", allergens: ["peanut", "soy"]
        )
        let promptWith = try promptText(of: withAllergens)
        XCTAssertTrue(promptWith.contains("The traveller avoids"), "allergen rule must be present")
        XCTAssertTrue(promptWith.contains("possibleAllergens"), "allergen rule names the possibleAllergens field")
        XCTAssertTrue(promptWith.contains("peanut, soy"), "the joined avoided list appears verbatim")
        XCTAssertTrue(
            promptWith.contains("Menu-printed allergen information"),
            "rule 12 must override rule 10's ignore-allergy-footnotes instruction for this field"
        )

        let withoutAllergens = try makeProvider().buildExtractRequest(
            images: [imageA], targetLanguage: "繁體中文", allergens: []
        )
        let promptWithout = try promptText(of: withoutAllergens)
        XCTAssertFalse(promptWithout.contains("The traveller avoids"), "no allergen rule when the list is empty")
        XCTAssertFalse(promptWithout.contains("possibleAllergens"), "no allergen field mentioned when the list is empty")
    }

    func testSummaryRuleAlwaysPresentRegardlessOfAllergens() throws {
        for allergens in [[], ["peanut"]] as [[String]] {
            let request = try makeProvider().buildExtractRequest(
                images: [imageA], targetLanguage: "繁體中文", allergens: allergens
            )
            let prompt = try promptText(of: request)
            XCTAssertTrue(prompt.contains("\"summary\""), "summary rule present (allergens=\(allergens))")
        }
    }

    func testItemSchemaAlwaysHasSummaryInPropertiesAndRequired() throws {
        for allergens in [[], ["peanut"]] as [[String]] {
            let request = try makeProvider().buildExtractRequest(
                images: [imageA], targetLanguage: "繁體中文", allergens: allergens
            )
            let item = try itemSchema(of: request)
            let properties = try XCTUnwrap(item["properties"] as? [String: Any])
            let summarySchema = try XCTUnwrap(properties["summary"] as? [String: Any], "summary in properties (allergens=\(allergens))")
            XCTAssertEqual(summarySchema["type"] as? String, "STRING")
            let required = try XCTUnwrap(item["required"] as? [String])
            XCTAssertTrue(required.contains("summary"), "summary required (allergens=\(allergens))")
        }
    }

    func testItemSchemaHasPossibleAllergensOnlyWhenAllergensNonEmpty() throws {
        let withItem = try itemSchema(of: makeProvider().buildExtractRequest(
            images: [imageA], targetLanguage: "繁體中文", allergens: ["peanut"]
        ))
        let withProps = try XCTUnwrap(withItem["properties"] as? [String: Any])
        let allergenSchema = try XCTUnwrap(withProps["possibleAllergens"] as? [String: Any])
        XCTAssertEqual(allergenSchema["type"] as? String, "ARRAY")
        XCTAssertTrue(try XCTUnwrap(withItem["required"] as? [String]).contains("possibleAllergens"))

        let withoutItem = try itemSchema(of: makeProvider().buildExtractRequest(
            images: [imageA], targetLanguage: "繁體中文", allergens: []
        ))
        let withoutProps = try XCTUnwrap(withoutItem["properties"] as? [String: Any])
        XCTAssertNil(withoutProps["possibleAllergens"], "no allergen field when the list is empty")
        XCTAssertFalse(try XCTUnwrap(withoutItem["required"] as? [String]).contains("possibleAllergens"))
    }

    func testAllergensAndCorrectiveSuffixCoexistInRebuild() throws {
        // Guards the corrective-retry path: rebuilding with a suffix must NOT drop allergens.
        let suffix = "Your previous output failed to parse: missing key 'items' at root. Return ONLY valid JSON matching the schema."
        let request = try makeProvider().buildExtractRequest(
            images: [imageA], targetLanguage: "繁體中文", allergens: ["peanut", "soy"], correctiveSuffix: suffix
        )
        let prompt = try promptText(of: request)
        XCTAssertTrue(prompt.contains("peanut, soy"), "allergen list survives the corrective rebuild")
        XCTAssertTrue(prompt.hasSuffix(suffix), "corrective suffix still appended after the allergen rule")

        let properties = try XCTUnwrap(try itemSchema(of: request)["properties"] as? [String: Any])
        XCTAssertNotNil(properties["possibleAllergens"], "allergen schema survives the corrective rebuild")
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
