import Foundation

/// 食物敏感原。rawValue 係穩定 slug，用嚟落 `@AppStorage`（comma-joined）
/// 同做 `Identifiable` id；`promptLabel` 係送俾 AI 嘅穩定英文合約字串；
/// `displayName` 先跟 app 內語言設定顯示。三者刻意分開，改 UI 名唔會影響
/// 儲存值同 prompt 合約。
enum Allergen: String, CaseIterable, Identifiable, Sendable {
    case peanut = "peanut"
    case treeNuts = "treeNuts"
    case milk = "milk"
    case egg = "egg"
    case fish = "fish"
    case crustacean = "crustacean"
    case soy = "soy"
    case wheat = "wheat"
    case sesame = "sesame"
    case gluten = "gluten"
    case molluscs = "molluscs"

    var id: String { rawValue }

    /// 送俾 AI 嘅穩定英文標籤，唔跟 UI 語言變。prompt 送呢啲字串入去，
    /// AI 回傳嘅 `possibleAllergens` 亦要 verbatim 用返呢啲字串——係兩邊嘅合約，
    /// 唔可以改。
    var promptLabel: String {
        switch self {
        case .peanut: return "peanut"
        case .treeNuts: return "tree nuts"
        case .milk: return "milk"
        case .egg: return "egg"
        case .fish: return "fish"
        case .crustacean: return "crustacean shellfish"
        case .soy: return "soy"
        case .wheat: return "wheat"
        case .sesame: return "sesame"
        case .gluten: return "gluten"
        case .molluscs: return "molluscs"
        }
    }

    /// 跟 app 內語言設定顯示嘅名（經 `L10n`）。
    var displayName: String {
        switch self {
        case .peanut: return L10n.string("花生")
        case .treeNuts: return L10n.string("樹果仁")
        case .milk: return L10n.string("奶")
        case .egg: return L10n.string("蛋")
        case .fish: return L10n.string("魚")
        case .crustacean: return L10n.string("甲殼類海鮮")
        case .soy: return L10n.string("大豆")
        case .wheat: return L10n.string("小麥")
        case .sesame: return L10n.string("芝麻")
        case .gluten: return L10n.string("麩質")
        case .molluscs: return L10n.string("軟體動物")
        }
    }

    /// 將 Settings 儲存嘅 preset slug 同自訂自由文字，砌成送俾 AI 嘅 label 清單。
    /// 純函數：`presets` 按 "," 拆、slug→`promptLabel`（唔識嘅 slug 掉咗）；
    /// `custom` 按 `,`／`、`／換行拆、trim、去空。preset 行先，之後 case-insensitive
    /// dedupe（保留首次出現），最後 cap：會令 joined 總長超 200 字元嘅項跳過（唔截半條），
    /// 後面啱長度嘅照保留——一條過長嘅自訂項唔會餓死之後嘅敏感原。
    static func parse(presets: String, custom: String) -> [String] {
        let presetLabels = presets
            .split(separator: ",", omittingEmptySubsequences: true)
            .compactMap { slug -> String? in
                let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
                return Allergen(rawValue: trimmed)?.promptLabel
            }

        let customLabels = custom
            .split(omittingEmptySubsequences: true) { $0 == "," || $0 == "、" || $0 == "\n" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let combined = presetLabels + customLabels

        var seen = Set<String>()
        var deduped: [String] = []
        for entry in combined {
            let key = entry.lowercased()
            guard seen.insert(key).inserted else { continue }
            deduped.append(entry)
        }

        var kept: [String] = []
        for entry in deduped {
            let projectedLength = (kept + [entry]).joined(separator: ", ").count
            guard projectedLength <= 200 else { continue }
            kept.append(entry)
        }
        return kept
    }

    /// 由 comma-joined 嘅 preset 字串攞返已揀 slug 集合（trim、去空）。
    /// Settings toggle binding 用嚟判斷邊個係開。
    static func selectedSlugs(_ presets: String) -> Set<String> {
        Set(
            presets
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    /// 將已揀 slug 集合寫返做 comma-joined 字串，次序固定跟 `allCases`，
    /// 順手隔走唔識嘅 slug。Settings toggle binding 用嚟寫返 `@AppStorage`。
    static func serialize(_ slugs: Set<String>) -> String {
        allCases
            .filter { slugs.contains($0.rawValue) }
            .map(\.rawValue)
            .joined(separator: ",")
    }

    /// 將 AI 回傳嘅一個 allergen 字串轉成顯示名：trim 後 case-insensitive 對返
    /// `promptLabel`，對中就用嗰個 allergen 嘅 `displayName`；對唔中就原樣（trim 後）
    /// 顯示，唔會靜靜跌咗個警示。
    static func displayLabel(for hit: String) -> String {
        let trimmed = hit.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = allCases.first(where: {
            $0.promptLabel.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return match.displayName
        }
        return trimmed
    }
}
