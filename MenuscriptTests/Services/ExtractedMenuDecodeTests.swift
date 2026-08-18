// Verifies that Gemini response text becomes safe, precise menu data even when the model returns imperfect JSON.
// A local envelope builder reproduces the API shape without networking, so parser
// compatibility and cleanup rules can be tested directly.

import XCTest
@testable import Menuscript

/// Regression coverage for menu and explanation response parsing, including tolerant input and strict money handling.
final class ExtractedMenuDecodeTests: XCTestCase {

    /// Wraps inner menu JSON in a realistic Gemini `generateContent` envelope,
    /// including extra keys the parser must ignore, so tests need no real API response.
    private func envelope(innerText: String) -> Data {
        let body: [String: Any] = [
            "candidates": [[
                "content": [
                    "parts": [["text": innerText]],
                    "role": "model",
                ],
                "finishReason": "STOP",
                "index": 0,
            ]],
            "usageMetadata": [
                "promptTokenCount": 1234,
                "candidatesTokenCount": 321,
                "totalTokenCount": 1555,
            ],
            "modelVersion": "gemini-2.5-flash",
            "responseId": "abc123",
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    /// Confirms a normal response preserves menu metadata, dish text, exact prices, categories, and confidence flags.
    func testParsesNormalEnvelopeWithTwoItems() throws {
        let inner = """
        {
          "detectedLanguage": "日文",
          "menuCurrency": "JPY",
          "restaurantName": "やきとり大吉",
          "items": [
            {"original": "焼き鳥盛り合わせ", "translated": "燒雞串拼盤", "price": "980", "priceNote": null, "category": "燒烤", "lowConfidence": false},
            {"original": "生ビール", "translated": "生啤酒", "price": "550", "priceNote": null, "category": "飲品", "lowConfidence": true}
          ]
        }
        """
        let menu = try GeminiProvider.parseExtractResponse(envelope(innerText: inner))

        XCTAssertEqual(menu.detectedLanguage, "日文")
        XCTAssertEqual(menu.menuCurrency, "JPY")
        XCTAssertEqual(menu.restaurantName, "やきとり大吉")
        XCTAssertEqual(menu.items.count, 2)

        XCTAssertEqual(menu.items[0].original, "焼き鳥盛り合わせ")
        XCTAssertEqual(menu.items[0].translated, "燒雞串拼盤")
        XCTAssertEqual(menu.items[0].price, Decimal(980))
        XCTAssertNil(menu.items[0].priceNote)
        XCTAssertEqual(menu.items[0].category, "燒烤")
        XCTAssertFalse(menu.items[0].lowConfidence)

        XCTAssertEqual(menu.items[1].price, Decimal(550))
        XCTAssertTrue(menu.items[1].lowConfidence)
    }

    /// Ensures non-numeric market pricing remains explanatory text instead of becoming a misleading bill amount.
    func testMarketPriceItemHasNilPriceAndVerbatimNote() throws {
        let inner = """
        {
          "detectedLanguage": "日文",
          "menuCurrency": "JPY",
          "restaurantName": null,
          "items": [
            {"original": "本日の刺身", "translated": "今日刺身", "price": null, "priceNote": "時価", "category": "刺身", "lowConfidence": false}
          ]
        }
        """
        let menu = try GeminiProvider.parseExtractResponse(envelope(innerText: inner))

        XCTAssertNil(menu.restaurantName)
        XCTAssertEqual(menu.items.count, 1)
        XCTAssertNil(menu.items[0].price)
        XCTAssertEqual(menu.items[0].priceNote, "時価")
    }

    /// Maps broken inner JSON to a decode failure so the provider can make its single corrective retry.
    func testMalformedInnerJSONThrowsDecodeFailed() {
        let data = envelope(innerText: #"{"detectedLanguage": "日文", "items": ["#)
        XCTAssertThrowsError(try GeminiProvider.parseExtractResponse(data)) { error in
            guard case VisionProviderError.decodeFailed = error else {
                return XCTFail("expected .decodeFailed, got \(error)")
            }
        }
    }

    /// Ignores unfamiliar fields at both envelope and menu levels so harmless Gemini additions do not break the app.
    func testUnknownKeysAreTolerated() throws {
        let inner = """
        {
          "detectedLanguage": "韓文",
          "menuCurrency": "KRW",
          "restaurantName": "김밥천국",
          "confidenceScore": 0.93,
          "pageCount": 2,
          "items": [
            {"original": "김치찌개", "translated": "泡菜鍋", "price": "9000", "priceNote": null, "category": "湯品", "lowConfidence": false, "spiciness": 3, "recommended": true}
          ]
        }
        """
        let menu = try GeminiProvider.parseExtractResponse(envelope(innerText: inner))

        XCTAssertEqual(menu.menuCurrency, "KRW")
        XCTAssertEqual(menu.items.count, 1)
        XCTAssertEqual(menu.items[0].price, Decimal(9000))
        XCTAssertEqual(menu.items[0].category, "湯品")
    }

    /// Treats a valid but itemless response as an empty menu, not malformed JSON that should trigger a retry.
    func testEmptyItemsThrowsEmptyMenu() {
        let inner = #"{"detectedLanguage": "日文", "menuCurrency": "JPY", "restaurantName": null, "items": []}"#
        XCTAssertThrowsError(try GeminiProvider.parseExtractResponse(envelope(innerText: inner))) { error in
            XCTAssertEqual(error as? VisionProviderError, .emptyMenu)
        }
    }

    /// Accepts older numeric prices, preserves decimal precision, moves non-prices to
    /// notes, and handles thousands separators.
    func testPriceParsingToleranceAndExactness() throws {
        let inner = """
        {
          "detectedLanguage": "英文",
          "menuCurrency": "USD",
          "items": [
            {"original": "Clam Chowder", "translated": "周打蜆湯", "price": "12.5", "category": "湯品", "lowConfidence": false},
            {"original": "Lobster Roll", "translated": "龍蝦包", "price": 28, "category": "主食", "lowConfidence": false},
            {"original": "Daily Fish", "translated": "是日鮮魚", "price": "MP", "category": "主食", "lowConfidence": false},
            {"original": "Oysters", "translated": "生蠔", "price": "1,200", "category": "前菜", "lowConfidence": false}
          ]
        }
        """
        let menu = try GeminiProvider.parseExtractResponse(envelope(innerText: inner))

        XCTAssertEqual(menu.items[0].price, Decimal(string: "12.5"))
        XCTAssertEqual(menu.items[1].price, Decimal(28))
        // Non-numeric text in price falls through to priceNote instead of being mis-parsed.
        XCTAssertNil(menu.items[2].price)
        XCTAssertEqual(menu.items[2].priceNote, "MP")
        // Thousands separators are stripped.
        XCTAssertEqual(menu.items[3].price, Decimal(1200))
    }

    /// Prevents a negative recognized value from reducing bill totals by keeping it as untrusted price text.
    func testNegativePriceFallsThroughToPriceNote() throws {
        let inner = """
        {
          "detectedLanguage": "英文",
          "menuCurrency": "USD",
          "restaurantName": null,
          "items": [
            {"original": "Mystery Item", "translated": "神秘餐點", "price": "-500", "priceNote": null, "category": "主食", "lowConfidence": false}
          ]
        }
        """
        let menu = try GeminiProvider.parseExtractResponse(envelope(innerText: inner))

        XCTAssertNil(menu.items[0].price)
        XCTAssertEqual(menu.items[0].priceNote, "-500")
    }

    /// Tolerates a markdown code fence that Gemini may add despite being asked for bare JSON.
    func testCodeFencedInnerJSONIsStillParsed() throws {
        let inner = """
        ```json
        {"detectedLanguage": "泰文", "menuCurrency": "THB", "restaurantName": null, "items": [
          {"original": "ต้มยำกุ้ง", "translated": "冬蔭功", "price": "150", "priceNote": null, "category": "湯品", "lowConfidence": false}
        ]}
        ```
        """
        let menu = try GeminiProvider.parseExtractResponse(envelope(innerText: inner))
        XCTAssertEqual(menu.items.count, 1)
        XCTAssertEqual(menu.items[0].price, Decimal(150))
    }

    /// Removes surrounding whitespace from a plain-text dish explanation before it reaches the interface.
    func testParseExplainResponseReturnsTrimmedText() throws {
        let text = "\n冬蔭功係泰國代表性酸辣蝦湯，主要材料有蝦、香茅、南薑同青檸葉。味道酸辣濃郁，通常配白飯食。 "
        let result = try GeminiProvider.parseExplainResponse(envelope(innerText: text))
        XCTAssertEqual(result, "冬蔭功係泰國代表性酸辣蝦湯，主要材料有蝦、香茅、南薑同青檸葉。味道酸辣濃郁，通常配白飯食。")
    }

    /// Replaces a missing or blank category with “Other” so the interface never shows an unlabeled group.
    func testMissingOrBlankCategoryFallsBackToOther() throws {
        let inner = """
        {
          "detectedLanguage": "日文",
          "menuCurrency": "JPY",
          "restaurantName": null,
          "items": [
            {"original": "A", "translated": "A", "price": "100", "priceNote": null, "lowConfidence": false},
            {"original": "B", "translated": "B", "price": "200", "priceNote": null, "category": "   ", "lowConfidence": false}
          ]
        }
        """
        let menu = try GeminiProvider.parseExtractResponse(envelope(innerText: inner))
        XCTAssertEqual(menu.items[0].category, "其他")
        XCTAssertEqual(menu.items[1].category, "其他")
    }

    /// Turns a response with no generated candidate, such as a safety block, into a clear decode failure.
    func testEnvelopeWithoutCandidatesThrowsDecodeFailed() {
        let data = try! JSONSerialization.data(withJSONObject: ["promptFeedback": ["blockReason": "SAFETY"]])
        XCTAssertThrowsError(try GeminiProvider.parseExtractResponse(data)) { error in
            guard case VisionProviderError.decodeFailed = error else {
                return XCTFail("expected .decodeFailed, got \(error)")
            }
        }
    }

    /// Confirms new summary and possible-allergen fields reach the app's menu item unchanged.
    func testSummaryAndPossibleAllergensDecodeOntoItem() throws {
        let inner = """
        {
          "detectedLanguage": "日文",
          "menuCurrency": "JPY",
          "restaurantName": null,
          "items": [
            {"original": "担々麺", "translated": "擔擔麵", "summary": "香辣芝麻湯底拉麵", "price": "980", "priceNote": null, "category": "主食", "lowConfidence": false, "possibleAllergens": ["peanut"]}
          ]
        }
        """
        let menu = try GeminiProvider.parseExtractResponse(envelope(innerText: inner))
        XCTAssertEqual(menu.items[0].summary, "香辣芝麻湯底拉麵")
        XCTAssertEqual(menu.items[0].possibleAllergens, ["peanut"])
    }

    /// Protects compatibility with older responses that predate summaries and allergen suggestions.
    func testLegacyPayloadWithoutNewKeysDecodesWithDefaults() throws {
        let inner = """
        {
          "detectedLanguage": "日文",
          "menuCurrency": "JPY",
          "restaurantName": null,
          "items": [
            {"original": "焼き鳥", "translated": "燒雞串", "price": "180", "priceNote": null, "category": "燒烤", "lowConfidence": false}
          ]
        }
        """
        let menu = try GeminiProvider.parseExtractResponse(envelope(innerText: inner))
        XCTAssertNil(menu.items[0].summary)
        XCTAssertEqual(menu.items[0].possibleAllergens, [])
    }

    /// Cleans blank summaries and allergen entries so empty labels never reach the interface.
    func testWhitespaceOnlySummaryNormalisesToNil() throws {
        let inner = """
        {
          "detectedLanguage": "日文",
          "menuCurrency": "JPY",
          "restaurantName": null,
          "items": [
            {"original": "枝豆", "translated": "毛豆", "summary": "   ", "price": "300", "priceNote": null, "category": "前菜", "lowConfidence": false, "possibleAllergens": ["  ", "soy"]}
          ]
        }
        """
        let menu = try GeminiProvider.parseExtractResponse(envelope(innerText: inner))
        XCTAssertNil(menu.items[0].summary)
        XCTAssertEqual(menu.items[0].possibleAllergens, ["soy"])
    }

    /// Deduplicates repeated allergen names despite case or padding so one warning never appears multiple times.
    func testDuplicatePossibleAllergensAreDeduped() throws {
        let inner = """
        {
          "detectedLanguage": "日文",
          "menuCurrency": "JPY",
          "restaurantName": null,
          "items": [
            {"original": "味噌ラーメン", "translated": "味噌拉麵", "summary": "濃郁味噌湯底拉麵", "price": "900", "priceNote": null, "category": "主食", "lowConfidence": false, "possibleAllergens": ["soy", "Soy", " soy ", "wheat"]}
          ]
        }
        """
        let menu = try GeminiProvider.parseExtractResponse(envelope(innerText: inner))
        XCTAssertEqual(menu.items[0].possibleAllergens, ["soy", "wheat"])
    }
}
