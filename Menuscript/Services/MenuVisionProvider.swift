// Defines the provider-independent menu result, error language, and recognition operations used by the app.
// Both Gemini and offline demo providers conform to this boundary, keeping screens unaware of networking details.

import Foundation

/// A complete, provider-neutral menu produced from one or more photos.
struct ExtractedMenu: Codable, Equatable, Sendable {
    /// One recognized menu entry in both its original and reader-friendly forms.
    struct Item: Codable, Equatable, Sendable {
        /// Text as it appeared on the photographed menu.
        var original: String
        /// Text translated into the user's requested language.
        var translated: String
        /// Numeric price when recognition can identify one safely.
        var price: Decimal?
        /// Non-numeric pricing text such as “market price.”
        var priceNote: String?
        /// Reader-friendly grouping such as mains or drinks.
        var category: String
        /// Warns that the recognized details deserve a manual check.
        var lowConfidence: Bool
        /// Optional short explanation of the dish.
        var summary: String? = nil
        /// Requested allergens that may be present; this is guidance, not a safety guarantee.
        var possibleAllergens: [String] = []
    }
    /// Human-readable source language, for example “Japanese.”
    var detectedLanguage: String
    /// Three-letter menu currency code, for example “JPY.”
    var menuCurrency: String
    /// Restaurant name when it can be read confidently.
    var restaurantName: String?
    /// Recognized dishes in display order.
    var items: [Item]
}

/// Provider failures expressed as user-meaningful categories instead of raw HTTP or decoding errors.
enum VisionProviderError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case invalidAPIKey
    case invalidImage
    case unsupportedTargetLanguage(String)
    case permissionDenied
    case billingRequired
    case quotaExceeded(retryAfter: TimeInterval?)
    case modelUnavailable
    case invalidRequest
    case serviceUnavailable
    case payloadTooLarge
    case http(Int)
    /// Compatibility case for callers/tests that pre-date Retry-After support.
    case rateLimited
    case rateLimitedWithRetryAfter(TimeInterval)
    case emptyMenu
    case decodeFailed(String)
    case network(String)

    /// Delay advertised by the service, when one was supplied and parsed.
    var retryAfter: TimeInterval? {
        switch self {
        case .quotaExceeded(let retryAfter):
            return retryAfter
        case .rateLimitedWithRetryAfter(let retryAfter):
            return retryAfter
        default:
            return nil
        }
    }

    /// Returns true only when changing the saved key can fix the problem.
    /// Permission, billing, model, and network failures need different guidance.
    var requiresAPIKeyUpdate: Bool {
        self == .missingAPIKey || self == .invalidAPIKey
    }

    /// Provides a localized, non-technical explanation suitable for showing directly in the app.
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return L10n.string("未設定 API Key，請先喺設定入面填返 Gemini API Key。")
        case .invalidAPIKey:
            return L10n.string("Gemini API Key 無效或已失效，請去設定更新。")
        case .invalidImage:
            return L10n.string("呢張相讀取唔到，請重新影過或者揀第二張。")
        case .unsupportedTargetLanguage(let language):
            return L10n.string("離線示範模式暫時唔支援「%@」，請選擇繁體中文或 English。", language)
        case .permissionDenied:
            return L10n.string("Gemini 專案無權使用呢個功能，請檢查 API Key 所屬專案權限。")
        case .billingRequired:
            return L10n.string("Gemini 專案嘅計費設定未啟用或有問題，請檢查 Google AI 專案。")
        case .quotaExceeded:
            return L10n.string("Gemini API 用量已達上限，請等限額重置或檢查專案配額。")
        case .modelUnavailable:
            return L10n.string("已選嘅 Gemini model 不存在或者專案無權使用，請檢查 model 設定。")
        case .invalidRequest:
            return L10n.string("Gemini 拒絕咗呢次請求，請檢查 model 設定或重新選擇相片。")
        case .serviceUnavailable:
            return L10n.string("Gemini 服務暫時不可用，請稍後再試。")
        case .payloadTooLarge:
            return L10n.string("相片資料太大，請減少相片或重新影過。")
        case .http(let code):
            return L10n.string("伺服器回應錯誤（HTTP %lld），請遲啲再試。", code)
        case .rateLimited:
            return L10n.string("請求太密，已達到 API 用量上限，請等一陣再試。")
        case .rateLimitedWithRetryAfter:
            return L10n.string("請求太密，已達到 API 用量上限，請等一陣再試。")
        case .emptyMenu:
            return L10n.string("喺相入面搵唔到菜單項目，請影清楚啲再試一次。")
        case .decodeFailed(let detail):
            return L10n.string("菜單辨識結果解析失敗，請再試一次。（%@）", detail)
        case .network(let detail):
            return L10n.string("網絡連線失敗，請檢查網絡之後再試。（%@）", detail)
        }
    }
}

/// A typed recovery route keeps configuration failures separate from
/// transient transport failures. Views can choose an appropriate CTA without
/// parsing localized error text.
enum ProviderRecoveryAction: Equatable, Sendable {
    case openSettings
    case reviewPermissions
    case reviewBilling
    case reviewModel
    case retry
}

/// Adds presentation-friendly recovery guidance without mixing UI decisions into networking code.
extension VisionProviderError {
    /// Maps an error category to a useful next step without making views inspect localized message text.
    var recoveryAction: ProviderRecoveryAction? {
        switch self {
        case .missingAPIKey, .invalidAPIKey, .unsupportedTargetLanguage:
            return .openSettings
        case .permissionDenied:
            return .reviewPermissions
        case .billingRequired:
            return .reviewBilling
        case .modelUnavailable:
            return .reviewModel
        case .quotaExceeded, .rateLimited, .rateLimitedWithRetryAfter,
             .serviceUnavailable, .network, .http, .invalidRequest:
            return .retry
        case .invalidImage, .payloadTooLarge, .emptyMenu, .decodeFailed:
            return nil
        }
    }
}

/// The small recognition boundary implemented by both live Gemini and deterministic offline demo services.
protocol MenuVisionProvider: Sendable {
    /// Reads menu photos, translates the recognized items, and flags only the allergens requested by the user.
    func extractMenu(images: [Data], targetLanguage: String, allergens: [String]) async throws -> ExtractedMenu
    /// Produces a short explanation of one dish in the requested target language.
    func explainDish(original: String, language: String, targetLanguage: String) async throws -> String
}
