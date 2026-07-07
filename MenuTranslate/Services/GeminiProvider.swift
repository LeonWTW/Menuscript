import Foundation

/// Gemini implementation of `MenuVisionProvider`.
///
/// Networking is a thin shell around pairs of pure, unit-testable functions:
/// `buildExtractRequest` / `parseExtractResponse` and `buildExplainRequest` / `parseExplainResponse`.
/// The API key travels ONLY in the `x-goog-api-key` header — never in the URL, never logged.
struct GeminiProvider: MenuVisionProvider {

    private let apiKey: @Sendable () -> String?
    private let model: String
    private let session: URLSession

    init(
        apiKey: @escaping @Sendable () -> String?,
        model: String = "gemini-2.5-flash",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        // A trailing/leading space typed into Settings' free-text model field
        // would otherwise land in the URL path and break the request invisibly.
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    // MARK: - MenuVisionProvider

    func extractMenu(images: [Data], targetLanguage: String) async throws -> ExtractedMenu {
        let request = try buildExtractRequest(images: images, targetLanguage: targetLanguage)
        let data = try await send(request)
        do {
            return try Self.parseExtractResponse(data)
        } catch VisionProviderError.decodeFailed(let reason) {
            // One corrective retry: identical request, prompt suffixed with the parse error.
            // A second parse failure propagates as .decodeFailed.
            let retryRequest = try buildExtractRequest(
                images: images,
                targetLanguage: targetLanguage,
                correctiveSuffix: "Your previous output failed to parse: \(reason). Return ONLY valid JSON matching the schema."
            )
            let retryData = try await send(retryRequest)
            return try Self.parseExtractResponse(retryData)
        }
    }

    func explainDish(original: String, language: String, targetLanguage: String) async throws -> String {
        let request = try buildExplainRequest(original: original, language: language, targetLanguage: targetLanguage)
        let data = try await send(request)
        return try Self.parseExplainResponse(data)
    }

    // MARK: - Request building (pure, internal for tests)

    /// Builds the `generateContent` request for menu extraction:
    /// one `inline_data` part per image followed by one text part (the extraction prompt),
    /// with a JSON response schema enforced via `generationConfig`.
    func buildExtractRequest(
        images: [Data],
        targetLanguage: String,
        correctiveSuffix: String? = nil
    ) throws -> URLRequest {
        let key = try requireAPIKey()
        guard !images.isEmpty else { throw VisionProviderError.invalidImage }

        var prompt = Self.extractPrompt(targetLanguage: targetLanguage)
        if let correctiveSuffix {
            prompt += "\n\n" + correctiveSuffix
        }

        var parts: [[String: Any]] = images.map { imageData in
            ["inline_data": [
                "mime_type": "image/jpeg",
                "data": imageData.base64EncodedString(),
            ]]
        }
        parts.append(["text": prompt])

        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "temperature": 0.2,
                "responseMimeType": "application/json",
                "responseSchema": Self.extractResponseSchema(),
            ],
        ]
        return try makeRequest(body: body, key: key)
    }

    /// Builds the `generateContent` request for a plain-text dish explanation (no schema).
    func buildExplainRequest(
        original: String,
        language: String,
        targetLanguage: String
    ) throws -> URLRequest {
        let key = try requireAPIKey()
        let prompt = """
        A traveller is looking at a restaurant menu written in \(language). \
        Explain the dish "\(original)" in \(targetLanguage), in 2-3 sentences: \
        what kind of dish it is, its main ingredients, and its taste and how it is typically eaten. \
        If several dishes share this name, describe the most common one. \
        Reply with plain text in \(targetLanguage) only — no markdown, no lists.
        """
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["temperature": 0.3],
        ]
        return try makeRequest(body: body, key: key)
    }

    private func requireAPIKey() throws -> String {
        guard let key = apiKey(), !key.isEmpty else {
            throw VisionProviderError.missingAPIKey
        }
        return key
    }

    private func makeRequest(body: [String: Any], key: String) throws -> URLRequest {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw VisionProviderError.network("無效嘅 API endpoint（model: \(model)）")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Key goes in this header only. Never append it to the URL query.
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: - Prompt

    /// The extraction prompt. Design goals: maximise handwriting recall (best guess +
    /// `lowConfidence`, never skip), merge/dedupe multi-photo menus, and keep prices machine-safe
    /// (single plain number → `price`; anything else verbatim into `priceNote`).
    private static func extractPrompt(targetLanguage: String) -> String {
        """
        You are an expert at reading restaurant menus for travellers — including messy handwriting, \
        stylised fonts, vertical CJK text, and photos with glare, blur or odd angles.

        You will receive one or more photos of the SAME menu (different pages, sections, or overlapping shots). \
        Merge everything into ONE menu.

        Rules:
        1. Read EVERY menu item in EVERY photo. If the same item appears in more than one photo, output it exactly once.
        2. NEVER skip an item because it is hard to read. If handwriting is unclear, partly hidden, or you had to guess, \
        still output your best guess and set "lowConfidence" to true. Set it to false only when you are confident.
        3. "original": the item name exactly as written on the menu, in its original script. \
        Normalise full-width digits to ASCII digits, change nothing else. Do not translate here.
        4. "translated": a natural \(targetLanguage) translation of the item name. Translate the dish meaningfully, \
        not character-by-character; keep proper nouns recognisable.
        5. "category": a SHORT \(targetLanguage) word grouping the item — e.g. when the target language is 繁體中文: \
        前菜, 主食, 燒烤, 湯品, 飲品, 甜品. Always write the category in \(targetLanguage). \
        Prefer the menu's own section headings (translated); otherwise infer one. \
        Reuse the exact same category string for items of the same group. Every item must have a category.
        6. Prices. "price" is a plain decimal number written as a STRING in the menu's own currency — \
        digits only, e.g. "600", "1200", "12.5". No currency symbols, no thousands separators. \
        Convert CJK numerals (五百 → "500").
           - The item shows exactly one plain price → set "price", leave "priceNote" null.
           - A range (e.g. "600〜"), market price (e.g. "時価", "時值", "MP"), multiple size/set prices \
        (e.g. "並500 大700", "S/M/L"), or anything not reducible to one number → set "price" to null \
        and copy the price text verbatim into "priceNote" in its original script.
           - No visible price → both null.
        7. "restaurantName": only if the restaurant's name is actually visible in a photo; otherwise null.
        8. "detectedLanguage": the menu's language as a short human-readable name written in \(targetLanguage) \
        (e.g. 日文, 韓文, 泰文).
        9. "menuCurrency": the ISO 4217 code of the menu's currency, inferred from currency symbols, language and \
        locale — 円/¥ on a Japanese menu → "JPY", ₩ → "KRW", ฿ → "THB", NT$ → "TWD". \
        If ambiguous, choose the most likely currency for the menu's language and country.
        10. Ignore text that is not a menu item: slogans, addresses, phone numbers, opening hours, Wi-Fi info, \
        allergy footnotes. A description or ingredient list printed under an item belongs to that item — \
        it is not a separate item.

        Target language: \(targetLanguage).
        Respond with ONLY the JSON object matching the response schema — no markdown, no code fences, no commentary.
        """
    }

    // MARK: - Wire schema

    /// Gemini structured-output schema mirroring `ExtractedMenu`
    /// (Gemini dialect: OBJECT/ARRAY/STRING/BOOLEAN + nullable/propertyOrdering).
    /// `price` is deliberately STRING on the wire: JSON numbers are decoded as binary floats,
    /// so "12.5" as a number could lose precision; we parse the string into `Decimal` ourselves.
    private static func extractResponseSchema() -> [String: Any] {
        let itemSchema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "original": ["type": "STRING", "description": "Item name exactly as written on the menu, original script"],
                "translated": ["type": "STRING", "description": "Item name translated into the target language"],
                "price": ["type": "STRING", "nullable": true, "description": "Single plain price as a decimal number string, e.g. \"600\" or \"12.5\"; null if none or not a single number"],
                "priceNote": ["type": "STRING", "nullable": true, "description": "Verbatim price text when price is null (range, market price, set prices)"],
                "category": ["type": "STRING", "description": "Short category in the target language"],
                "lowConfidence": ["type": "BOOLEAN", "description": "True when the reading is a guess (handwriting, blur, occlusion)"],
            ],
            "required": ["original", "translated", "category", "lowConfidence"],
            "propertyOrdering": ["original", "translated", "price", "priceNote", "category", "lowConfidence"],
        ]
        return [
            "type": "OBJECT",
            "properties": [
                "detectedLanguage": ["type": "STRING", "description": "Menu language as a human-readable name in the target language, e.g. 日文"],
                "menuCurrency": ["type": "STRING", "description": "ISO 4217 currency code, e.g. JPY"],
                "restaurantName": ["type": "STRING", "nullable": true],
                "items": ["type": "ARRAY", "items": itemSchema],
            ],
            "required": ["detectedLanguage", "menuCurrency", "items"],
            "propertyOrdering": ["detectedLanguage", "menuCurrency", "restaurantName", "items"],
        ]
    }

    // MARK: - Response parsing (pure, internal for tests)

    /// Unwraps the Gemini envelope (`candidates[0].content.parts[].text`), then decodes the inner
    /// JSON into `ExtractedMenu`. `price` arrives as a string (see `extractResponseSchema`) and is
    /// parsed with `Decimal(string:)` to avoid Double round-trip precision loss; a numeric `price`
    /// is tolerated as a fallback. Throws `.decodeFailed` on malformed payloads and `.emptyMenu`
    /// when the menu decodes but has no items.
    static func parseExtractResponse(_ data: Data) throws -> ExtractedMenu {
        let text = stripCodeFence(try innerText(from: data))
        guard let jsonData = text.data(using: .utf8) else {
            throw VisionProviderError.decodeFailed("inner text is not valid UTF-8")
        }
        let wire: WireMenu
        do {
            wire = try JSONDecoder().decode(WireMenu.self, from: jsonData)
        } catch {
            throw VisionProviderError.decodeFailed(describe(error))
        }

        let items = wire.items.map { raw -> ExtractedMenu.Item in
            var price: Decimal? = nil
            var priceNote = normalized(raw.priceNote)
            if let rawPrice = raw.price?.raw.trimmingCharacters(in: .whitespacesAndNewlines), !rawPrice.isEmpty {
                if let parsed = wirePriceDecimal(rawPrice) {
                    price = parsed
                } else if priceNote == nil {
                    // Model put non-numeric text (e.g. "時価", "600〜") into price: keep it as a note.
                    priceNote = rawPrice
                }
            }
            return ExtractedMenu.Item(
                original: raw.original.trimmingCharacters(in: .whitespacesAndNewlines),
                translated: raw.translated.trimmingCharacters(in: .whitespacesAndNewlines),
                price: price,
                priceNote: priceNote,
                category: normalized(raw.category) ?? "其他",
                lowConfidence: raw.lowConfidence ?? false
            )
        }
        guard !items.isEmpty else { throw VisionProviderError.emptyMenu }

        return ExtractedMenu(
            detectedLanguage: wire.detectedLanguage,
            menuCurrency: wire.menuCurrency,
            restaurantName: normalized(wire.restaurantName),
            items: items
        )
    }

    /// Unwraps the envelope and returns the trimmed plain-text explanation.
    static func parseExplainResponse(_ data: Data) throws -> String {
        let text = try innerText(from: data).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VisionProviderError.decodeFailed("empty explanation text") }
        return text
    }

    // MARK: - Parsing internals

    private struct GeminiEnvelope: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { var text: String? }
                var parts: [Part]?
            }
            var content: Content?
            var finishReason: String?
        }
        var candidates: [Candidate]?
    }

    /// Wire form of the inner menu JSON. Tolerant on purpose: unknown keys are ignored,
    /// `lowConfidence`/`category` may be missing, and `price` may arrive as string or number.
    private struct WireMenu: Decodable {
        struct WireItem: Decodable {
            var original: String
            var translated: String
            var price: StringOrNumber?
            var priceNote: String?
            var category: String?
            var lowConfidence: Bool?
        }
        var detectedLanguage: String
        var menuCurrency: String
        var restaurantName: String?
        var items: [WireItem]
    }

    /// Accepts a JSON string or number, preserving its textual form for exact Decimal parsing.
    private struct StringOrNumber: Decodable {
        var raw: String
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                raw = string
            } else if let decimal = try? container.decode(Decimal.self) {
                raw = "\(decimal)"
            } else {
                throw DecodingError.typeMismatch(
                    String.self,
                    .init(codingPath: decoder.codingPath, debugDescription: "price must be a string or number")
                )
            }
        }
    }

    private static func innerText(from data: Data) throws -> String {
        let envelope: GeminiEnvelope
        do {
            envelope = try JSONDecoder().decode(GeminiEnvelope.self, from: data)
        } catch {
            throw VisionProviderError.decodeFailed("unexpected response envelope: \(describe(error))")
        }
        let texts = envelope.candidates?.first?.content?.parts?.compactMap(\.text) ?? []
        let joined = texts.joined()
        guard !joined.isEmpty else {
            let reason = envelope.candidates?.first?.finishReason ?? "no candidates"
            throw VisionProviderError.decodeFailed("response contains no text (\(reason))")
        }
        return joined
    }

    /// Defensive: strips a surrounding ```/```json fence if the model added one anyway.
    private static func stripCodeFence(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        if let firstNewline = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
        }
        if let closing = trimmed.range(of: "```", options: .backwards) {
            trimmed = String(trimmed[..<closing.lowerBound])
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strict wire-price parse: plain decimal number only (commas stripped).
    /// Anything else (ranges, 時価, units) returns nil so it lands in `priceNote` instead —
    /// `Decimal(string:)` alone would silently accept "600〜" as 600.
    private static func wirePriceDecimal(_ raw: String) -> Decimal? {
        let cleaned = raw.replacingOccurrences(of: ",", with: "")
        guard cleaned.range(of: #"^-?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil else {
            return nil
        }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Compact, English description of a decode error — it is echoed back to the model
    /// in the corrective retry prompt (the user-facing wrapper text lives in VisionProviderError).
    private static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return String(describing: error) }
        func path(_ codingPath: [CodingKey]) -> String {
            codingPath.isEmpty ? "root" : codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(path(context.codingPath))"
        case .typeMismatch(_, let context):
            return "type mismatch at \(path(context.codingPath)): \(context.debugDescription)"
        case .valueNotFound(_, let context):
            return "unexpected null at \(path(context.codingPath))"
        case .dataCorrupted(let context):
            return "invalid JSON: \(context.debugDescription)"
        @unknown default:
            return String(describing: decodingError)
        }
    }

    // MARK: - Transport

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw VisionProviderError.network(error.localizedDescription)
        } catch {
            throw VisionProviderError.network(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw VisionProviderError.network("非 HTTP 回應")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 429:
            throw VisionProviderError.rateLimited
        default:
            throw VisionProviderError.http(http.statusCode)
        }
    }
}
