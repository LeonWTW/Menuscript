import XCTest
@testable import MenuTranslate

/// Tests for `GeminiProvider.parseExtractResponse` — pure function, no network.
final class ExtractedMenuDecodeTests: XCTestCase {

    /// Wraps inner menu JSON in a realistic Gemini `generateContent` envelope,
    /// including extra envelope-level keys the parser must ignore.
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

    // Fixture ①: normal envelope with 2 items.
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

    // Fixture ②: market-price item — price null, verbatim priceNote.
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

    // Fixture ③: inner text is malformed JSON → .decodeFailed.
    func testMalformedInnerJSONThrowsDecodeFailed() {
        let data = envelope(innerText: #"{"detectedLanguage": "日文", "items": ["#)
        XCTAssertThrowsError(try GeminiProvider.parseExtractResponse(data)) { error in
            guard case VisionProviderError.decodeFailed = error else {
                return XCTFail("expected .decodeFailed, got \(error)")
            }
        }
    }

    // Fixture ④: unknown JSON keys (envelope helper already adds envelope-level extras;
    // here the inner payload also carries unknown keys) → tolerated.
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

    // Decoded menu with zero items → .emptyMenu (not a decode failure, must not trigger retry).
    func testEmptyItemsThrowsEmptyMenu() {
        let inner = #"{"detectedLanguage": "日文", "menuCurrency": "JPY", "restaurantName": null, "items": []}"#
        XCTAssertThrowsError(try GeminiProvider.parseExtractResponse(envelope(innerText: inner))) { error in
            XCTAssertEqual(error as? VisionProviderError, .emptyMenu)
        }
    }

    // Wire contract says price is a STRING, but a numeric price is tolerated;
    // decimal strings must survive exactly (Decimal, not Double round-trip).
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

    // Defensive: model wrapped its JSON in a markdown fence despite instructions.
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

    // parseExplainResponse: same envelope, plain text inside.
    func testParseExplainResponseReturnsTrimmedText() throws {
        let text = "\n冬蔭功係泰國代表性酸辣蝦湯，主要材料有蝦、香茅、南薑同青檸葉。味道酸辣濃郁，通常配白飯食。 "
        let result = try GeminiProvider.parseExplainResponse(envelope(innerText: text))
        XCTAssertEqual(result, "冬蔭功係泰國代表性酸辣蝦湯，主要材料有蝦、香茅、南薑同青檸葉。味道酸辣濃郁，通常配白飯食。")
    }

    // Envelope with no candidates (e.g. safety-blocked) → .decodeFailed.
    func testEnvelopeWithoutCandidatesThrowsDecodeFailed() {
        let data = try! JSONSerialization.data(withJSONObject: ["promptFeedback": ["blockReason": "SAFETY"]])
        XCTAssertThrowsError(try GeminiProvider.parseExtractResponse(data)) { error in
            guard case VisionProviderError.decodeFailed = error else {
                return XCTFail("expected .decodeFailed, got \(error)")
            }
        }
    }
}
