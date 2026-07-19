import Foundation

struct ExtractedMenu: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        var original: String
        var translated: String
        var price: Decimal?
        var priceNote: String?
        var category: String
        var lowConfidence: Bool
        var summary: String? = nil
        var possibleAllergens: [String] = []
    }
    var detectedLanguage: String   // human-readable, e.g. "日文"
    var menuCurrency: String       // ISO 4217, e.g. "JPY"
    var restaurantName: String?
    var items: [Item]
}

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

    /// Lets Wave 2 route only credential failures to Settings. Permission,
    /// billing, model and network failures must not be presented as a bad key.
    var requiresAPIKeyUpdate: Bool {
        self == .missingAPIKey || self == .invalidAPIKey
    }

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

extension VisionProviderError {
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

protocol MenuVisionProvider: Sendable {
    func extractMenu(images: [Data], targetLanguage: String, allergens: [String]) async throws -> ExtractedMenu
    func explainDish(original: String, language: String, targetLanguage: String) async throws -> String
}
