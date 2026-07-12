import Foundation

/// Stub `MenuVisionProvider` that ignores its inputs and returns a fixed,
/// realistic 居酒屋 (izakaya) menu after a short simulated delay. Useful for
/// UI development and previews without calling a real vision API.
struct MockVisionProvider: MenuVisionProvider {
    func extractMenu(images: [Data], targetLanguage: String, allergens: [String]) async throws -> ExtractedMenu {
        try await Task.sleep(for: .milliseconds(500))
        return Self.sampleMenu
    }

    func explainDish(original: String, language: String, targetLanguage: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(300))
        return "「\(original)」係呢間居酒屋嘅人氣菜式之一，選料新鮮，做法保留咗傳統日式風味。呢道菜好啱配一杯清酒或者生啤酒一齊享用，係好多熟客必點嘅選擇。"
    }

    private static let sampleMenu = ExtractedMenu(
        detectedLanguage: "日文",
        menuCurrency: "JPY",
        restaurantName: "鷹の目",
        items: [
            ExtractedMenu.Item(original: "焼きなす", translated: "烤茄子", price: 500, priceNote: nil, category: "燒烤", lowConfidence: false, summary: "炭烤茄子淋薑蓉醬油，清爽開胃", possibleAllergens: []),
            ExtractedMenu.Item(original: "唐揚げ", translated: "日式炸雞", price: 650, priceNote: nil, category: "燒烤", lowConfidence: true, summary: "外脆內嫩嘅日式炸雞塊", possibleAllergens: ["wheat", "soy", "egg"]),
            ExtractedMenu.Item(original: "手羽先の塩焼き", translated: "鹽烤雞翅", price: 480, priceNote: nil, category: "燒烤", lowConfidence: false, summary: "鹽燒雞翼，皮脆肉嫩", possibleAllergens: []),
            ExtractedMenu.Item(original: "焼き鳥盛り合わせ", translated: "串燒拼盤", price: 900, priceNote: nil, category: "燒烤", lowConfidence: false, summary: "多款炭燒雞肉串拼盤", possibleAllergens: ["soy"]),
            ExtractedMenu.Item(original: "炒飯", translated: "日式炒飯", price: 750, priceNote: nil, category: "主食", lowConfidence: false, summary: "鑊氣十足嘅日式炒飯", possibleAllergens: []),
            ExtractedMenu.Item(original: "焼きおにぎり", translated: "烤飯糰", price: 350, priceNote: nil, category: "主食", lowConfidence: false, summary: "香烤醬油飯糰，外脆內軟", possibleAllergens: []),
            ExtractedMenu.Item(original: "生ビール(小)", translated: "生啤酒（小杯）", price: 480, priceNote: nil, category: "飲品", lowConfidence: false, summary: "冰凍生啤，小杯裝", possibleAllergens: ["gluten", "wheat"]),
            ExtractedMenu.Item(original: "日本酒", translated: "日本清酒", price: nil, priceNote: "時價", category: "飲品", lowConfidence: false, summary: "傳統日本米酒，時價供應", possibleAllergens: []),
            ExtractedMenu.Item(original: "ウーロン茶", translated: "烏龍茶", price: 300, priceNote: nil, category: "飲品", lowConfidence: false, summary: "解膩烏龍茶，冷熱皆宜", possibleAllergens: []),
            ExtractedMenu.Item(original: "豚汁", translated: "豬肉味噌湯", price: 420, priceNote: nil, category: "湯品", lowConfidence: false, summary: "豬肉蔬菜味噌湯，暖胃管飽", possibleAllergens: ["soy"])
        ]
    )
}
