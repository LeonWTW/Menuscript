// Produces a realistic fixed menu and dish explanations without reading photos or contacting Gemini.
// The predictable sample menu lets Demo Mode, previews, and tests work reliably offline.

import Foundation

/// Fully offline, deterministic menu provider used by demo mode.
///
/// The sample has a language-neutral core and explicit English/Traditional
/// Chinese projections. Demo input is intentionally permissive: unsupported
/// target text falls back to Traditional Chinese instead of failing a demo.
struct MockVisionProvider: MenuVisionProvider {
    /// Presents the shared sample in English or Traditional Chinese and reports requested allergen matches.
    /// Photo bytes are intentionally ignored because demo mode must remain deterministic and fully offline.
    func extractMenu(
        images: [Data],
        targetLanguage: String,
        allergens: [String]
    ) async throws -> ExtractedMenu {
        let target = MockTargetLanguage(targetLanguage)
        let requestedAllergens = Self.normalizedRequestedAllergens(allergens)

        return ExtractedMenu(
            detectedLanguage: target.detectedLanguage,
            menuCurrency: "JPY",
            restaurantName: "鷹の目",
            items: Self.fixtures.map { fixture in
                let copy = fixture.copy(for: target)
                let canonicalHits = Set(fixture.canonicalAllergens.map { $0.lowercased() })
                let hits = requestedAllergens.filter {
                    canonicalHits.contains($0.lowercased())
                }
                return ExtractedMenu.Item(
                    original: fixture.original,
                    translated: copy.translated,
                    price: fixture.price,
                    priceNote: copy.priceNote,
                    category: copy.category,
                    lowConfidence: fixture.lowConfidence,
                    summary: copy.summary,
                    possibleAllergens: hits
                )
            }
        )
    }

    /// Returns a fixed-style explanation translated for the demo's supported target language.
    func explainDish(
        original: String,
        language: String,
        targetLanguage: String
    ) async throws -> String {
        switch MockTargetLanguage(targetLanguage) {
        case .traditionalChinese:
            return "「\(original)」係呢間居酒屋嘅人氣菜式之一，選料新鮮，做法保留咗傳統日式風味。呢道菜好啱配一杯清酒或者生啤酒一齊享用，係好多熟客必點嘅選擇。"
        case .english:
            return "\"\(original)\" is a popular izakaya dish prepared with fresh ingredients in a traditional Japanese style. It is commonly enjoyed with sake or draft beer."
        }
    }

    /// Keeps only non-empty request values and deduplicates case-insensitively
    /// while preserving the exact spelling/case of the first requested value.
    private static func normalizedRequestedAllergens(_ allergens: [String]) -> [String] {
        var seen = Set<String>()
        return allergens.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  seen.insert(value.lowercased()).inserted else {
                return nil
            }
            return value
        }
    }

    private static let fixtures: [Fixture] = [
        Fixture(
            original: "焼きなす",
            price: 500,
            lowConfidence: false,
            canonicalAllergens: [],
            zh: .init(translated: "烤茄子", priceNote: nil, category: "燒烤", summary: "炭烤茄子淋薑蓉醬油，清爽開胃"),
            en: .init(translated: "Grilled eggplant", priceNote: nil, category: "Grilled", summary: "Charred eggplant with ginger soy sauce.")
        ),
        Fixture(
            original: "唐揚げ",
            price: 650,
            lowConfidence: true,
            canonicalAllergens: ["wheat", "soy", "egg"],
            zh: .init(translated: "日式炸雞", priceNote: nil, category: "燒烤", summary: "外脆內嫩嘅日式炸雞塊"),
            en: .init(translated: "Japanese fried chicken", priceNote: nil, category: "Grilled", summary: "Crisp, juicy Japanese fried chicken.")
        ),
        Fixture(
            original: "手羽先の塩焼き",
            price: 480,
            lowConfidence: false,
            canonicalAllergens: [],
            zh: .init(translated: "鹽烤雞翅", priceNote: nil, category: "燒烤", summary: "鹽燒雞翼，皮脆肉嫩"),
            en: .init(translated: "Salt-grilled chicken wings", priceNote: nil, category: "Grilled", summary: "Crisp chicken wings seasoned with salt.")
        ),
        Fixture(
            original: "焼き鳥盛り合わせ",
            price: 900,
            lowConfidence: false,
            canonicalAllergens: ["soy"],
            zh: .init(translated: "串燒拼盤", priceNote: nil, category: "燒烤", summary: "多款炭燒雞肉串拼盤"),
            en: .init(translated: "Assorted yakitori", priceNote: nil, category: "Grilled", summary: "A selection of charcoal-grilled chicken skewers.")
        ),
        Fixture(
            original: "炒飯",
            price: 750,
            lowConfidence: false,
            canonicalAllergens: [],
            zh: .init(translated: "日式炒飯", priceNote: nil, category: "主食", summary: "鑊氣十足嘅日式炒飯"),
            en: .init(translated: "Japanese fried rice", priceNote: nil, category: "Mains", summary: "Wok-fried rice in a Japanese style.")
        ),
        Fixture(
            original: "焼きおにぎり",
            price: 350,
            lowConfidence: false,
            canonicalAllergens: [],
            zh: .init(translated: "烤飯糰", priceNote: nil, category: "主食", summary: "香烤醬油飯糰，外脆內軟"),
            en: .init(translated: "Grilled rice ball", priceNote: nil, category: "Mains", summary: "A crisp soy-glazed rice ball.")
        ),
        Fixture(
            original: "生ビール(小)",
            price: 480,
            lowConfidence: false,
            canonicalAllergens: ["gluten", "wheat"],
            zh: .init(translated: "生啤酒（小杯）", priceNote: nil, category: "飲品", summary: "冰凍生啤，小杯裝"),
            en: .init(translated: "Draft beer (small)", priceNote: nil, category: "Drinks", summary: "A small glass of chilled draft beer.")
        ),
        Fixture(
            original: "日本酒",
            price: nil,
            lowConfidence: false,
            canonicalAllergens: [],
            zh: .init(translated: "日本清酒", priceNote: "時價", category: "飲品", summary: "傳統日本米酒，時價供應"),
            en: .init(translated: "Japanese sake", priceNote: "Market price", category: "Drinks", summary: "Traditional Japanese rice wine.")
        ),
        Fixture(
            original: "ウーロン茶",
            price: 300,
            lowConfidence: false,
            canonicalAllergens: [],
            zh: .init(translated: "烏龍茶", priceNote: nil, category: "飲品", summary: "解膩烏龍茶，冷熱皆宜"),
            en: .init(translated: "Oolong tea", priceNote: nil, category: "Drinks", summary: "Refreshing oolong tea served hot or cold.")
        ),
        Fixture(
            original: "豚汁",
            price: 420,
            lowConfidence: false,
            canonicalAllergens: ["soy"],
            zh: .init(translated: "豬肉味噌湯", priceNote: nil, category: "湯品", summary: "豬肉蔬菜味噌湯，暖胃管飽"),
            en: .init(translated: "Pork miso soup", priceNote: nil, category: "Soup", summary: "A hearty miso soup with pork and vegetables.")
        ),
    ]
}

/// Reduces free-form language settings to the two translations included in the demo sample.
private enum MockTargetLanguage {
    case traditionalChinese
    case english

    /// Recognizes English labels and codes; every other value safely falls back to Traditional Chinese.
    init(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()

        if normalized == "en" || normalized.contains("english") {
            self = .english
        } else {
            // Chinese locales and every unknown value intentionally share the
            // only non-English sample, so demo input never fails.
            self = .traditionalChinese
        }
    }

    /// Names the sample menu's Japanese source language in the selected display language.
    var detectedLanguage: String {
        switch self {
        case .traditionalChinese: return "日文"
        case .english: return "Japanese"
        }
    }
}

/// Language-neutral facts for one demo dish plus its translated display copies.
private struct Fixture {
    /// Text fields that change with the selected display language.
    struct Copy {
        let translated: String
        let priceNote: String?
        let category: String
        let summary: String
    }

    let original: String
    let price: Decimal?
    let lowConfidence: Bool
    let canonicalAllergens: [String]
    let zh: Copy
    let en: Copy

    /// Chooses the translated fields while leaving price, confidence, and allergen facts shared.
    func copy(for target: MockTargetLanguage) -> Copy {
        switch target {
        case .traditionalChinese: return zh
        case .english: return en
        }
    }
}
