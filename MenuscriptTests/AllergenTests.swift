// Verifies the stable allergen vocabulary shared by Settings, local storage, AI prompts, and menu results.
// The tests protect both predefined choices and free-text input without contacting an AI service.

import Foundation
import Testing
@testable import Menuscript

/// Covers the `Allergen` enum's stable contract: the slugs stored in
/// `@AppStorage`, the English `promptLabel`s sent to the AI, and `allCases`
/// order (which `serialize` relies on for a deterministic string).
@Suite("Allergen contract")
struct AllergenContractTests {
    @Test("allCases has all 11 allergens with the expected slugs in a stable order")
    /// Confirms every supported allergen has a permanent storage key in a predictable order.
    func allCasesSlugs() {
        #expect(Allergen.allCases.count == 11)
        #expect(Allergen.allCases.map(\.rawValue) == [
            "peanut", "treeNuts", "milk", "egg", "fish",
            "crustacean", "soy", "wheat", "sesame", "gluten", "molluscs",
        ])
    }

    @Test("id equals rawValue")
    /// Confirms SwiftUI can use the same stable slug to identify each allergen choice.
    func idEqualsRawValue() {
        for allergen in Allergen.allCases {
            #expect(allergen.id == allergen.rawValue)
        }
    }

    @Test("promptLabel returns the stable English AI-contract label")
    /// Confirms the AI always receives the agreed English term for each preset.
    func promptLabelsMatchContract() {
        #expect(Allergen.peanut.promptLabel == "peanut")
        #expect(Allergen.treeNuts.promptLabel == "tree nuts")
        #expect(Allergen.milk.promptLabel == "milk")
        #expect(Allergen.egg.promptLabel == "egg")
        #expect(Allergen.fish.promptLabel == "fish")
        #expect(Allergen.crustacean.promptLabel == "crustacean shellfish")
        #expect(Allergen.soy.promptLabel == "soy")
        #expect(Allergen.wheat.promptLabel == "wheat")
        #expect(Allergen.sesame.promptLabel == "sesame")
        #expect(Allergen.gluten.promptLabel == "gluten")
        #expect(Allergen.molluscs.promptLabel == "molluscs")
    }
}

/// Covers `Allergen.parse`: the pure function that folds stored preset slugs
/// plus free-text custom input into the label list sent to the AI.
@Suite("Allergen.parse")
struct AllergenParseTests {
    @Test("Preset slugs map to promptLabels, unknown slugs are dropped")
    /// Confirms saved preset keys become AI labels while obsolete or corrupt keys are ignored.
    func presetSlugsMapAndDropUnknown() {
        #expect(Allergen.parse(presets: "peanut,soy", custom: "") == ["peanut", "soy"])
        #expect(Allergen.parse(presets: "peanut,unknownslug,soy", custom: "") == ["peanut", "soy"])
    }

    @Test("Dedupes case-insensitively across presets and custom, preserving first occurrence")
    /// Confirms repeated entries are sent once, preserving the user's first spelling.
    func dedupesCaseInsensitivelyAcrossPresetsAndCustom() {
        #expect(
            Allergen.parse(presets: "peanut,soy", custom: "Soy, PEANUT, Sesame")
                == ["peanut", "soy", "Sesame"]
        )
    }

    @Test("Custom splits on comma, ideographic comma, and newline")
    /// Confirms users can separate custom allergens with punctuation common in English or Chinese text.
    func customSplitsOnCommaIdeographicCommaAndNewline() {
        #expect(
            Allergen.parse(presets: "", custom: "香菜、九層塔\n芫茜,羅勒")
                == ["香菜", "九層塔", "芫茜", "羅勒"]
        )
    }

    @Test("Custom entries are trimmed and empty entries dropped")
    /// Confirms extra spaces and empty separators do not become meaningless AI prompt entries.
    func customEntriesTrimmedAndEmptiesDropped() {
        #expect(
            Allergen.parse(presets: "", custom: "  香菜  ,, 、\n  , 九層塔 ")
                == ["香菜", "九層塔"]
        )
    }

    @Test("Empty inputs yield an empty list")
    /// Confirms a user with no allergen profile sends no allergen instruction.
    func emptyInputsYieldEmpty() {
        #expect(Allergen.parse(presets: "", custom: "").isEmpty)
        #expect(Allergen.parse(presets: "   ", custom: "  \n 、 ,").isEmpty)
    }

    @Test("200-char cap skips entries that would overflow but keeps later ones that fit")
    /// Confirms the prompt-length limit keeps complete entries and still considers shorter later entries.
    func capKeepsWholeEntries() {
        let a = String(repeating: "a", count: 60)
        let b = String(repeating: "b", count: 60)
        let c = String(repeating: "c", count: 60)
        let d = String(repeating: "d", count: 60)
        let result = Allergen.parse(presets: "", custom: "\(a),\(b),\(c),\(d),peanut")
        // a+b+c joined with ", " is 184 chars (<=200); adding d would reach 246,
        // so d is skipped — but the shorter "peanut" after it still fits (192).
        #expect(result == [a, b, c, "peanut"])
        #expect(result.joined(separator: ", ").count <= 200)
    }

    @Test("An entry longer than the cap is skipped whole — never truncated, never starving later entries")
    /// Confirms an oversized entry is dropped intact without hiding valid entries that follow it.
    func overlongEntrySkippedWhole() {
        let long = String(repeating: "x", count: 250)
        #expect(Allergen.parse(presets: "", custom: long).isEmpty)
        // A runaway first entry must not silently drop allergens listed after it.
        #expect(Allergen.parse(presets: "", custom: "\(long)、花生") == ["花生"])
    }
}

/// Covers `Allergen.selectedSlugs` / `Allergen.serialize`: the pair backing
/// the Settings toggle binding. `serialize` emits `allCases` order and drops
/// unknown slugs; the two round-trip.
@Suite("Allergen slug serialization")
struct AllergenSlugSerializationTests {
    @Test("selectedSlugs parses a comma-joined string into a slug set")
    /// Confirms the compact saved string restores the user's selected preset set.
    func selectedSlugsParses() {
        #expect(Allergen.selectedSlugs("peanut,soy,wheat") == ["peanut", "soy", "wheat"])
        #expect(Allergen.selectedSlugs("").isEmpty)
        #expect(Allergen.selectedSlugs(" peanut , soy ") == ["peanut", "soy"])
    }

    @Test("serialize emits allCases order and drops unknown slugs")
    /// Confirms preset selections are stored deterministically and invalid keys are removed.
    func serializeEmitsStableOrderAndDropsUnknown() {
        #expect(Allergen.serialize(["soy", "peanut", "wheat"]) == "peanut,soy,wheat")
        #expect(Allergen.serialize(["peanut", "bogus"]) == "peanut")
        #expect(Allergen.serialize([]).isEmpty)
    }

    @Test("selectedSlugs and serialize round-trip")
    /// Confirms saving and loading a valid selection preserves the same allergens.
    func selectedSlugsAndSerializeRoundTrip() {
        #expect(Allergen.serialize(Allergen.selectedSlugs("wheat,peanut")) == "peanut,wheat")
        #expect(Allergen.selectedSlugs(Allergen.serialize(["soy", "peanut"])) == ["peanut", "soy"])
    }
}

/// Covers `Allergen.displayLabel`: mapping an AI-returned allergen string back
/// to a localized name (case-insensitive, trimmed), falling through to the
/// verbatim hit when nothing matches. Assertions compare against the matched
/// allergen's own `displayName` rather than a hardcoded localized literal so
/// the test does not couple to the running locale or catalog `en` values.
@Suite("Allergen.displayLabel")
struct AllergenDisplayLabelTests {
    @Test("Matches a promptLabel case-insensitively to its localized displayName")
    /// Confirms known AI-returned terms map back to localized labels regardless of letter case.
    func matchesCaseInsensitively() {
        #expect(Allergen.displayLabel(for: "Tree Nuts") == Allergen.treeNuts.displayName)
        #expect(Allergen.displayLabel(for: "TREE NUTS") == Allergen.treeNuts.displayName)
        #expect(Allergen.displayLabel(for: "crustacean shellfish") == Allergen.crustacean.displayName)
    }

    @Test("Trims surrounding whitespace before matching")
    /// Confirms harmless spaces around an AI result do not prevent localization.
    func trimsBeforeMatching() {
        #expect(Allergen.displayLabel(for: "  peanut  ") == Allergen.peanut.displayName)
    }

    @Test("Passes an unmatched hit through verbatim (trimmed)")
    /// Confirms custom allergen terms remain readable when they are not predefined presets.
    func passesUnmatchedThroughVerbatim() {
        #expect(Allergen.displayLabel(for: "香菜") == "香菜")
        #expect(Allergen.displayLabel(for: "  九層塔 ") == "九層塔")
    }
}
