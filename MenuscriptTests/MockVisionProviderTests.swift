// Verifies the offline sample menu behaves like a predictable substitute for Gemini recognition.
// Deterministic outputs let developers exercise the full app without an API key or user photos.

import Foundation
import Testing
@testable import Menuscript

@Suite("MockVisionProvider")
/// Protects demo translations, allergen filtering, language fallback, explanations, and repeatability.
struct MockVisionProviderTests {
    private let provider = MockVisionProvider()

    @Test("English and Traditional Chinese projections localize every field")
    /// Confirms supported target languages receive complete, internally consistent demo menus.
    func targetLanguageProjection() async throws {
        let english = try await provider.extractMenu(
            images: [Data([1])],
            targetLanguage: "English",
            allergens: []
        )
        let chinese = try await provider.extractMenu(
            images: [Data([9, 9])],
            targetLanguage: "繁體中文",
            allergens: []
        )
        let englishAbbreviation = try await provider.extractMenu(
            images: [],
            targetLanguage: " en ",
            allergens: []
        )

        #expect(english.detectedLanguage == "Japanese")
        #expect(englishAbbreviation.detectedLanguage == "Japanese")
        #expect(chinese.detectedLanguage == "日文")
        #expect(english.items.count == chinese.items.count)
        #expect(english.items[0].translated == "Grilled eggplant")
        #expect(englishAbbreviation.items[0].translated == "Grilled eggplant")
        #expect(chinese.items[0].translated == "烤茄子")
        #expect(english.items.allSatisfy { !$0.category.isEmpty })
        #expect(english.items.allSatisfy { !($0.summary ?? "").isEmpty })
        #expect(english.items[7].priceNote == "Market price")
        #expect(chinese.items[7].priceNote == "時價")
    }

    @Test("Allergen hits are an exact, case-insensitive subset of the request")
    /// Confirms demo warnings can only contain allergen text the user actually requested.
    func allergenSubset() async throws {
        let requested = ["SOY", "Peanut", "egg", "soy", "GLUTEN"]
        let menu = try await provider.extractMenu(
            images: [],
            targetLanguage: "en",
            allergens: requested
        )

        let karaage = try #require(menu.items.first { $0.original == "唐揚げ" })
        #expect(karaage.possibleAllergens == ["SOY", "egg"])

        let yakitori = try #require(
            menu.items.first { $0.original == "焼き鳥盛り合わせ" }
        )
        #expect(yakitori.possibleAllergens == ["SOY"])

        let beer = try #require(menu.items.first { $0.original == "生ビール(小)" })
        #expect(beer.possibleAllergens == ["GLUTEN"])

        let exactRequestValues = Set(requested)
        for hit in menu.items.flatMap(\.possibleAllergens) {
            #expect(exactRequestValues.contains(hit))
        }
        #expect(menu.items.flatMap(\.possibleAllergens).contains("Peanut") == false)
    }

    @Test("Empty allergen request means every item has no hits")
    /// Confirms no allergen profile produces no warnings in the demo result.
    func emptyAllergens() async throws {
        let menu = try await provider.extractMenu(
            images: [],
            targetLanguage: "Traditional Chinese",
            allergens: []
        )
        #expect(menu.items.allSatisfy { $0.possibleAllergens.isEmpty })
    }

    @Test(
        "Arbitrary target-language input falls back to the Traditional Chinese demo projection",
        arguments: [
            "Chinese", "廣東話", "简体中文", "日本語", "Français", "亂打xyz", "zh-CN", "   ",
        ]
    )
    /// Confirms unrecognized language text uses Traditional Chinese as the safe demo fallback.
    func arbitraryTargetLanguageFallsBackToTraditionalChinese(
        targetLanguage: String
    ) async throws {
        let menu = try await provider.extractMenu(
            images: [],
            targetLanguage: targetLanguage,
            allergens: []
        )
        let explanation = try await provider.explainDish(
            original: "唐揚げ",
            language: "Japanese",
            targetLanguage: targetLanguage
        )

        #expect(menu.detectedLanguage == "日文")
        #expect(menu.restaurantName == "鷹の目")
        #expect(menu.items.count == 10)
        #expect(menu.items.first?.translated == "烤茄子")
        #expect(explanation.contains("人氣菜式"))
    }

    @Test(
        "Free-text values containing an English token use the English demo projection",
        arguments: ["British English", "English (UK)"]
    )
    /// Confirms free-text settings containing “English” select the English sample menu.
    func englishTokenUsesEnglishProjection(targetLanguage: String) async throws {
        let menu = try await provider.extractMenu(
            images: [],
            targetLanguage: targetLanguage,
            allergens: []
        )
        let explanation = try await provider.explainDish(
            original: "唐揚げ",
            language: "Japanese",
            targetLanguage: targetLanguage
        )

        #expect(menu.detectedLanguage == "Japanese")
        #expect(menu.items.first?.translated == "Grilled eggplant")
        #expect(explanation.contains("popular izakaya dish"))
    }

    @Test("Dish explanation follows the requested target language")
    /// Confirms demo dish explanations use the same language choice as menu translation.
    func explanationLanguage() async throws {
        let english = try await provider.explainDish(
            original: "唐揚げ",
            language: "Japanese",
            targetLanguage: "English"
        )
        let chinese = try await provider.explainDish(
            original: "唐揚げ",
            language: "日文",
            targetLanguage: "zh-Hant"
        )
        #expect(english.contains("popular izakaya dish"))
        #expect(chinese.contains("人氣菜式"))
    }

    @Test("Fixture is deterministic regardless of image bytes")
    /// Confirms Demo Mode always returns the same menu and never interprets photo contents.
    func deterministicFixture() async throws {
        let first = try await provider.extractMenu(
            images: [],
            targetLanguage: "English",
            allergens: ["soy"]
        )
        let second = try await provider.extractMenu(
            images: [Data(repeating: 0xFF, count: 100)],
            targetLanguage: "English",
            allergens: ["soy"]
        )
        #expect(first == second)
    }
}
