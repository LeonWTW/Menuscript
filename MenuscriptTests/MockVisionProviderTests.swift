import Foundation
import Testing
@testable import Menuscript

@Suite("MockVisionProvider")
struct MockVisionProviderTests {
    private let provider = MockVisionProvider()

    @Test("English and Traditional Chinese projections localize every field")
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

        #expect(english.detectedLanguage == "Japanese")
        #expect(chinese.detectedLanguage == "日文")
        #expect(english.items.count == chinese.items.count)
        #expect(english.items[0].translated == "Grilled eggplant")
        #expect(chinese.items[0].translated == "烤茄子")
        #expect(english.items.allSatisfy { !$0.category.isEmpty })
        #expect(english.items.allSatisfy { !($0.summary ?? "").isEmpty })
        #expect(english.items[7].priceNote == "Market price")
        #expect(chinese.items[7].priceNote == "時價")
    }

    @Test("Allergen hits are an exact, case-insensitive subset of the request")
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
    func emptyAllergens() async throws {
        let menu = try await provider.extractMenu(
            images: [],
            targetLanguage: "Traditional Chinese",
            allergens: []
        )
        #expect(menu.items.allSatisfy { $0.possibleAllergens.isEmpty })
    }

    @Test("Unsupported targets fail with a typed error for extract and explain")
    func unsupportedLanguage() async {
        await #expect(throws: VisionProviderError.unsupportedTargetLanguage("Français")) {
            try await provider.extractMenu(
                images: [],
                targetLanguage: "Français",
                allergens: []
            )
        }
        await #expect(throws: VisionProviderError.unsupportedTargetLanguage("日本語")) {
            try await provider.explainDish(
                original: "唐揚げ",
                language: "Japanese",
                targetLanguage: "日本語"
            )
        }
    }

    @Test("Dish explanation follows the requested target language")
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
