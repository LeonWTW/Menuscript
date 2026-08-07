// Builds Gemini menu-reading requests, validates responses, and converts provider failures into safe app errors.
// Request construction and response parsing are separate from transport so the
// important logic can be tested without networking.

import Foundation

/// Gemini implementation of `MenuVisionProvider`.
///
/// Networking is a thin shell around pairs of pure, unit-testable functions:
/// `buildExtractRequest` / `parseExtractResponse` and `buildExplainRequest` / `parseExplainResponse`.
/// The API key travels ONLY in the `x-goog-api-key` header — never in the URL, never logged.
struct GeminiProvider: MenuVisionProvider {
    /// Sets the app's final serialized request limit after photos expand through JSON and base64 encoding.
    static let maximumRequestBodyBytes = 18_000_000
    /// Caps the portion of an error body sent to the JSON decoder so unexpected responses receive bounded processing.
    private static let maximumErrorEnvelopeBytes = 64_000

    private let apiKey: @Sendable () -> String?
    private let model: String
    private let session: URLSession

    /// Creates a provider with a lazily supplied key, configurable model, and injectable network session.
    /// Resolving the key only when building a request keeps secret access out of offline composition paths.
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

    /// Sends all menu photos for one structured extraction and retries once when Gemini returns malformed JSON.
    /// The retry includes the parse problem and the same allergen rules, so correction
    /// cannot silently change the request.
    func extractMenu(images: [Data], targetLanguage: String, allergens: [String]) async throws -> ExtractedMenu {
        let request = try buildExtractRequest(images: images, targetLanguage: targetLanguage, allergens: allergens)
        let data = try await send(request)
        do {
            return try Self.parseExtractResponse(data)
        } catch VisionProviderError.decodeFailed(let reason) {
            // One corrective retry: identical request, prompt suffixed with the parse error.
            // A second parse failure propagates as .decodeFailed.
            // `allergens` must ride the rebuild too, or the retry silently downgrades to the
            // no-allergen prompt/schema.
            let retryRequest = try buildExtractRequest(
                images: images,
                targetLanguage: targetLanguage,
                allergens: allergens,
                correctiveSuffix: "Your previous output failed to parse: \(reason). Return ONLY valid JSON matching the schema."
            )
            let retryData = try await send(retryRequest)
            return try Self.parseExtractResponse(retryData)
        }
    }

    /// Requests and parses a short plain-language explanation for one recognized dish.
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
        allergens: [String] = [],
        correctiveSuffix: String? = nil
    ) throws -> URLRequest {
        let key = try requireAPIKey()
        guard !images.isEmpty else { throw VisionProviderError.invalidImage }

        var prompt = Self.extractPrompt(targetLanguage: targetLanguage, allergens: allergens)
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
                "responseSchema": Self.extractResponseSchema(includeAllergens: !allergens.isEmpty),
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

    /// Resolves and trims the API key immediately before use, treating nil and whitespace-only values identically.
    private func requireAPIKey() throws -> String {
        guard let rawKey = apiKey() else {
            throw VisionProviderError.missingAPIKey
        }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw VisionProviderError.missingAPIKey }
        return key
    }

    /// Serializes a Gemini POST request, placing the secret only in its dedicated header and enforcing the body limit.
    private func makeRequest(body: [String: Any], key: String) throws -> URLRequest {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw VisionProviderError.network(L10n.string("無效嘅 API endpoint（model: %@）", model))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Key goes in this header only. Never append it to the URL query.
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = try Self.validateSerializedRequestBody(bodyData)
        return request
    }

    /// Applies the transport limit to the final serialized bytes, after JSON
    /// and base64 overhead have been added. Kept internal as a cheap boundary
    /// helper so tests do not need to construct multi-megabyte sample images.
    static func validateSerializedRequestBody(_ bodyData: Data) throws -> Data {
        guard bodyData.count <= Self.maximumRequestBodyBytes else {
            throw VisionProviderError.payloadTooLarge
        }
        return bodyData
    }

    // MARK: - Prompt

    /// The extraction prompt. Design goals: maximise handwriting recall (best guess +
    /// `lowConfidence`, never skip), merge/dedupe multi-photo menus, and keep prices machine-safe
    /// (single plain number → `price`; anything else verbatim into `priceNote`). Always asks for a
    /// short `summary`; when `allergens` is non-empty, adds an advisory `possibleAllergens` rule
    /// constrained to exactly that list (entries verbatim, never invented).
    private static func extractPrompt(targetLanguage: String, allergens: [String]) -> String {
        var extraRules = """
        11. "summary": one short sentence in \(targetLanguage) — aim for at most about 20 characters for CJK \
        languages, or 8 words otherwise — saying what kind of dish this is. Do NOT repeat the translated name. \
        Every item must have a "summary".
        """
        if !allergens.isEmpty {
            let avoided = allergens.joined(separator: ", ")
            extraRules += "\n" + """
            12. The traveller avoids: \(avoided). For "possibleAllergens", return the subset of EXACTLY those \
            strings that are likely present in a typical recipe of the dish; when an ingredient is plausibly \
            present, include it (err toward flagging). Menu-printed allergen information (footnotes, ingredient \
            marks such as ※えび・かに) is authoritative for this field — rule 10's instruction to ignore allergy \
            footnotes applies only to what counts as a menu item, NOT to this field. Output each entry verbatim \
            as it was given, NEVER add anything not in that list, and use an empty array when none apply. This is \
            advisory guidance to help the traveller ask the restaurant — it is NOT a safety guarantee.
            """
        }
        return """
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
        \(extraRules)

        Target language: \(targetLanguage).
        Respond with ONLY the JSON object matching the response schema — no markdown, no code fences, no commentary.
        """
    }

    // MARK: - Wire schema

    /// Gemini structured-output schema mirroring `ExtractedMenu`
    /// (Gemini dialect: OBJECT/ARRAY/STRING/BOOLEAN + nullable/propertyOrdering).
    /// `price` is deliberately STRING on the wire: JSON numbers are decoded as binary floats,
    /// so "12.5" as a number could lose precision; we parse the string into `Decimal` ourselves.
    private static func extractResponseSchema(includeAllergens: Bool) -> [String: Any] {
        var itemProperties: [String: Any] = [
            "original": ["type": "STRING", "description": "Item name exactly as written on the menu, original script"],
            "translated": ["type": "STRING", "description": "Item name translated into the target language"],
            "summary": ["type": "STRING", "description": "One short sentence in the target language describing what kind of dish this is; never repeats the translated name"],
            "price": ["type": "STRING", "nullable": true, "description": "Single plain price as a decimal number string, e.g. \"600\" or \"12.5\"; null if none or not a single number"],
            "priceNote": ["type": "STRING", "nullable": true, "description": "Verbatim price text when price is null (range, market price, set prices)"],
            "category": ["type": "STRING", "description": "Short category in the target language"],
            "lowConfidence": ["type": "BOOLEAN", "description": "True when the reading is a guess (handwriting, blur, occlusion)"],
        ]
        var required = ["original", "translated", "summary", "category", "lowConfidence"]
        var propertyOrdering = ["original", "translated", "summary", "price", "priceNote", "category", "lowConfidence"]

        if includeAllergens {
            let allergenSchema: [String: Any] = [
                "type": "ARRAY",
                "items": ["type": "STRING"],
                "description": "Subset of the traveller's avoided-ingredient list likely present in a typical recipe; each entry verbatim from that list; empty array when none apply; advisory only",
            ]
            itemProperties["possibleAllergens"] = allergenSchema
            required.append("possibleAllergens")
            propertyOrdering.append("possibleAllergens")
        }

        let itemSchema: [String: Any] = [
            "type": "OBJECT",
            "properties": itemProperties,
            "required": required,
            "propertyOrdering": propertyOrdering,
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
                    // The model put text such as "market price" or a price range in `price`; keep it as a note.
                    priceNote = rawPrice
                }
            }
            return ExtractedMenu.Item(
                original: raw.original.trimmingCharacters(in: .whitespacesAndNewlines),
                translated: raw.translated.trimmingCharacters(in: .whitespacesAndNewlines),
                price: price,
                priceNote: priceNote,
                category: normalized(raw.category) ?? "其他",
                lowConfidence: raw.lowConfidence ?? false,
                summary: normalized(raw.summary),
                possibleAllergens: dedupedAllergens(raw.possibleAllergens)
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

    /// Minimal outer response shape needed to collect Gemini's generated text and finish reason.
    private struct GeminiEnvelope: Decodable {
        /// One possible model response; the provider intentionally uses the first candidate.
        struct Candidate: Decodable {
            /// Groups the text parts returned for a candidate.
            struct Content: Decodable {
                /// A generated response fragment; non-text fragments decode with a nil value.
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
        /// The model-facing version of an item, with optional fields tolerated for defensive parsing.
        struct WireItem: Decodable {
            var original: String
            var translated: String
            var price: StringOrNumber?
            var priceNote: String?
            var category: String?
            var lowConfidence: Bool?
            var summary: String?
            var possibleAllergens: [String]?
        }
        var detectedLanguage: String
        var menuCurrency: String
        var restaurantName: String?
        var items: [WireItem]
    }

    /// Accepts a JSON string or number, preserving its textual form for exact Decimal parsing.
    private struct StringOrNumber: Decodable {
        var raw: String

        /// Decodes either representation into text so later Decimal parsing follows one strict path.
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

    /// Decodes Gemini's outer envelope and joins all text fragments from its first candidate.
    /// Missing text becomes a meaningful decode failure that includes the provider's finish reason when available.
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
    /// Anything else (ranges, market-price text, or units) returns nil so it lands in `priceNote` instead.
    /// `Decimal(string:)` alone could silently accept a range beginning with 600 as the exact value 600.
    private static func wirePriceDecimal(_ raw: String) -> Decimal? {
        let cleaned = raw.replacingOccurrences(of: ",", with: "")
        guard cleaned.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil else {
            return nil
        }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Trims optional model text and turns blank strings into nil so the UI never displays empty metadata.
    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Trim, drop empties, then case-insensitively dedupe (first occurrence wins) —
    /// the model occasionally repeats an entry despite the verbatim instruction,
    /// and a duplicate would render twice in the allergen alert.
    private static func dedupedAllergens(_ raw: [String]?) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in raw ?? [] {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// Compact, English description of a decode error — it is echoed back to the model
    /// in the corrective retry prompt (the user-facing wrapper text lives in VisionProviderError).
    private static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return "unexpected decoding error"
        }
        /// Converts a nested JSON coding path into a short readable location.
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
            return "unexpected decoding error"
        }
    }

    // MARK: - Transport

    /// Bounded subset of Google's error JSON used only to classify failures without retaining provider text.
    private struct GoogleErrorEnvelope: Decodable {
        /// The server's status category and optional structured reasons.
        struct Payload: Decodable {
            /// One machine-readable reason supplied in Google's detail list.
            struct Detail: Decodable {
                let reason: String?
            }

            let code: Int?
            let message: String?
            let status: String?
            let details: [Detail]?
        }

        let error: Payload?
    }

    /// Executes one request, returning successful bytes and translating transport or
    /// HTTP failures into safe error categories.
    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Transport errors can carry arbitrary provider/userInfo text. In
            // particular a custom URLProtocol error may echo request headers,
            // so never retain localizedDescription or String(describing:).
            let code = (error as? URLError)?.code
            throw VisionProviderError.network(Self.safeNetworkMessage(for: code))
        }
        guard let http = response as? HTTPURLResponse else {
            throw VisionProviderError.network(L10n.string("非 HTTP 回應"))
        }
        switch http.statusCode {
        case 200..<300:
            return data
        default:
            throw Self.transportError(
                statusCode: http.statusCode,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After"),
                data: data
            )
        }
    }

    /// Maps only the finite URL error code to fixed text. No source error or
    /// userInfo crosses this boundary, preventing secrets from being retained
    /// in an Equatable error that can later reach UI, diagnostics, or logs.
    static func safeNetworkMessage(for code: URLError.Code?) -> String {
        switch code {
        case .notConnectedToInternet:
            return "offline"
        case .timedOut:
            return "request timed out"
        case .networkConnectionLost:
            return "connection lost"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "service unreachable"
        case .cancelled:
            return "request cancelled"
        default:
            return "network request failed"
        }
    }

    /// Maps only bounded, known fields from Google's error envelope. The
    /// service message is used for classification but is never retained in the
    /// thrown error, which prevents an echoed key/request fragment leaking into
    /// logs or UI.
    static func transportError(
        statusCode: Int,
        retryAfterHeader: String?,
        data: Data,
        now: Date = Date()
    ) -> VisionProviderError {
        let bounded = Data(data.prefix(Self.maximumErrorEnvelopeBytes))
        let payload = (try? JSONDecoder().decode(
            GoogleErrorEnvelope.self,
            from: bounded
        ))?.error

        let status = payload?.status?.uppercased() ?? ""
        let message = payload?.message?.lowercased() ?? ""
        let reasons = payload?.details?
            .compactMap(\.reason)
            .map { $0.uppercased() } ?? []
        let reasonText = reasons.joined(separator: " ")
        let retryAfter = parsedRetryAfter(retryAfterHeader, now: now)

        if statusCode == 413 {
            return .payloadTooLarge
        }
        if (500...599).contains(statusCode) {
            return .serviceUnavailable
        }

        let invalidKeyReason = reasonText.contains("API_KEY_INVALID")
            || reasonText.contains("API_KEY_EXPIRED")
        let invalidKeyMessage = message.contains("api key not valid")
            || message.contains("invalid api key")
            || message.contains("api key is invalid")
        if statusCode == 401
            || status == "UNAUTHENTICATED"
            || invalidKeyReason
            || invalidKeyMessage {
            return .invalidAPIKey
        }

        if reasonText.contains("BILLING")
            || status == "FAILED_PRECONDITION" && message.contains("billing")
            || message.contains("billing account")
            || message.contains("billing is not enabled") {
            return .billingRequired
        }

        let isQuota = status == "RESOURCE_EXHAUSTED"
            || reasonText.contains("QUOTA")
            || message.contains("quota exceeded")
            || message.contains("quota has been exhausted")
        if isQuota {
            return .quotaExceeded(retryAfter: retryAfter)
        }

        let isModelFailure = statusCode == 404
            || status == "NOT_FOUND"
            || message.contains("model") && (
                message.contains("not found")
                    || message.contains("not supported")
                    || message.contains("not available")
            )
        if isModelFailure {
            return .modelUnavailable
        }

        if statusCode == 403 || status == "PERMISSION_DENIED" {
            return .permissionDenied
        }

        if statusCode == 400 || status == "INVALID_ARGUMENT" {
            return .invalidRequest
        }

        if statusCode == 429 {
            if let retryAfter {
                return .rateLimitedWithRetryAfter(retryAfter)
            }
            return .rateLimited
        }

        return .http(statusCode)
    }

    /// Reads `Retry-After` as either non-negative seconds or an HTTP date and converts it to a delay.
    /// Invalid values return nil so callers never wait based on malformed server input.
    private static func parsedRetryAfter(
        _ header: String?,
        now: Date
    ) -> TimeInterval? {
        guard let value = header?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
