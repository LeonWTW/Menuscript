// Defines the allergen vocabulary shared by settings, AI prompts, saved values,
// and the interface, keeping those representations stable but independently editable.

import Foundation

/// A supported food allergen. Its stored slug, AI-facing label, and localized
/// display name are deliberately separate so wording changes do not corrupt data.
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

    /// Uses the stored slug as the stable identity shown in settings lists.
    var id: String { rawValue }

    /// Returns the fixed English label exchanged with the AI. These exact values
    /// form a contract with `possibleAllergens` and must not follow the UI language.
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

    /// Returns the allergen name in the language selected inside the app.
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

    /// Combines saved presets and free text into a clean AI prompt list. It drops
    /// unknown presets, removes duplicates, and skips entries that would exceed
    /// the 200-character limit without cutting a warning in half.
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

    /// Turns the comma-separated setting into a trimmed set used by preset toggles.
    static func selectedSlugs(_ presets: String) -> Set<String> {
        Set(
            presets
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    /// Writes selected slugs in a predictable order and ignores values the app
    /// does not recognize, producing the compact setting stored in `UserDefaults`.
    static func serialize(_ slugs: Set<String>) -> String {
        allCases
            .filter { slugs.contains($0.rawValue) }
            .map(\.rawValue)
            .joined(separator: ",")
    }

    /// Converts one AI-returned label to a localized known allergen. Unknown
    /// labels stay visible after trimming so a possible warning is never hidden.
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
