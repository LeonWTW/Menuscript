import Foundation

struct ExtractedMenu: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        var original: String
        var translated: String
        var price: Decimal?
        var priceNote: String?
        var category: String
        var lowConfidence: Bool
    }
    var detectedLanguage: String   // human-readable, e.g. "日文"
    var menuCurrency: String       // ISO 4217, e.g. "JPY"
    var restaurantName: String?
    var items: [Item]
}

enum VisionProviderError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case invalidImage
    case http(Int)
    case rateLimited
    case emptyMenu
    case decodeFailed(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return L10n.string("未設定 API Key，請先喺設定入面填返 Gemini API Key。")
        case .invalidImage:
            return L10n.string("呢張相讀取唔到，請重新影過或者揀第二張。")
        case .http(let code):
            return L10n.string("伺服器回應錯誤（HTTP %lld），請遲啲再試。", code)
        case .rateLimited:
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

protocol MenuVisionProvider: Sendable {
    func extractMenu(images: [Data], targetLanguage: String) async throws -> ExtractedMenu
    func explainDish(original: String, language: String, targetLanguage: String) async throws -> String
}
