// Verifies the exact calculations and messages BillView derives from a saved menu session.
// Pure models are used instead of UI automation so money rules remain fast and deterministic.

import Foundation
import Testing
@testable import Menuscript

/// Tests the exact `BillMath` compositions `BillView` uses to derive its
/// numbers: order lines → subtotal → total → per-person, and
/// total → converted → per-person. Pure `BillMath` compositions — no UI
/// testing.
@Suite("BillView derived numbers")
struct BillViewLogicTests {

    @Test("FX rate display preserves usable precision without scientific notation")
    /// Confirms ordinary and very small positive rates retain a clear, fixed-decimal representation.
    func fxRateDisplayPrecision() {
        let cases: [(rate: Double, expected: String)] = [
            (0.05, "0.05"),
            (7.8, "7.8"),
            (0.000065, "0.000065"),
            (0.00000001, "0.00000001"),
            (0.000000001, "<0.00000001"),
            (0.00000002, "0.00000002"),
        ]

        for testCase in cases {
            #expect(BillFXPresentation.rateText(testCase.rate) == testCase.expected)
        }
    }

    @Test("FX refresh failure copy distinguishes Demo Mode coverage from live-network failure")
    /// Confirms Demo Mode and live-network failures give users the appropriate next step.
    func fxRefreshFailureCopyMatchesProviderMode() {
        #expect(
            BillFXPresentation.unavailableMessageKey(for: .mock)
                == "示範模式暫時唔支援呢個貨幣組合，請喺設定揀另一隻貨幣。"
        )
        #expect(
            BillFXPresentation.unavailableMessageKey(for: .live)
                == "暫時攞唔到最新匯率，請檢查網絡或稍後再試。"
        )
        #expect(
            BillFXPresentation.unavailableMessageKey(for: nil)
                == "暫時攞唔到最新匯率，請檢查網絡或稍後再試。"
        )
    }

    /// Builds a minimal dish with the price and quantity needed for bill calculations.
    private func makeItem(priceValue: Decimal?, quantity: Int, sortOrder: Int) -> MenuItem {
        MenuItem(
            originalName: "dish",
            translatedName: "dish",
            priceValue: priceValue,
            category: "測試",
            quantity: quantity,
            sortOrder: sortOrder
        )
    }

    /// Mirrors `BillView.subtotal`: items with quantity>0 and a priced
    /// value are mapped to (price, qty) lines and summed via `BillMath`.
    private func subtotal(of items: [MenuItem]) -> Decimal {
        let lines: [(price: Decimal, qty: Int)] = items
            .filter { $0.quantity > 0 }
            .compactMap { item in
                guard let price = item.priceValue else { return nil }
                return (price: price, qty: item.quantity)
            }
        return BillMath.subtotal(lines: lines)
    }

    @Test("Order lines subtotal sums priced, quantity>0 items and ignores unpriced/zero-qty lines")
    /// Confirms the view subtotal includes only selected dishes with known numeric prices.
    func orderLinesSubtotal() {
        let items = [
            makeItem(priceValue: Decimal(1280), quantity: 2, sortOrder: 0), // 2560
            makeItem(priceValue: nil, quantity: 1, sortOrder: 1),           // excluded: no price
            makeItem(priceValue: Decimal(550), quantity: 0, sortOrder: 2), // excluded: qty 0
            makeItem(priceValue: Decimal(420), quantity: 1, sortOrder: 3), // 420
        ]
        let result = subtotal(of: items)
        #expect(result == Decimal(2980))
    }

    @Test("Total applies a 10% surcharge on top of the order-lines subtotal")
    /// Confirms the displayed total adds the selected service charge after calculating the subtotal.
    func totalWithTenPercentSurcharge() {
        let items = [
            makeItem(priceValue: Decimal(1000), quantity: 2, sortOrder: 0), // subtotal 2000
        ]
        let subtotalValue = subtotal(of: items)
        let result = BillMath.total(subtotal: subtotalValue, surchargePercent: 10)
        #expect(result == Decimal(2200))
    }

    @Test("Per-person JPY split of an evenly-divisible total needs no rounding")
    /// Confirms an exact whole-yen split is left unchanged.
    func perPersonJPYEvenSplit() {
        // 1800 subtotal + 10% surcharge = 1980, split 3 ways = 660 exactly.
        let total = BillMath.total(subtotal: Decimal(1800), surchargePercent: 10)
        #expect(total == Decimal(1980))
        let result = BillMath.perPerson(total: total, people: 3, fractionDigits: 0)
        #expect(result == Decimal(660))
    }

    @Test("Per-person JPY split of an uneven total rounds up so shares never fall short")
    /// Confirms an uneven whole-yen split rounds upward enough to cover the bill.
    func perPersonJPYUnevenSplitRoundsUp() {
        let result = BillMath.perPerson(total: Decimal(1000), people: 3, fractionDigits: 0)
        #expect(result == Decimal(334))
        #expect(result * Decimal(3) >= Decimal(1000))
    }

    @Test("Converted per-person splits the FX-converted total at the home currency's fraction digits, rounding up")
    /// Confirms conversion happens before splitting and uses the home currency's decimal precision.
    func convertedPerPersonTwoFractionDigits() {
        // 1000 JPY converted at 0.0521 -> 52.1 HKD, split 3 ways at 2 digits.
        let convertedTotal = BillMath.converted(Decimal(1000), rate: 0.0521)
        #expect(convertedTotal == Decimal(string: "52.1"))
        let result = BillMath.perPerson(total: convertedTotal, people: 3, fractionDigits: 2)
        #expect(result == Decimal(string: "17.37"))
        #expect(result * Decimal(3) >= convertedTotal)
    }

    @Test("effectiveFXRate suppresses same-currency sessions even when a legacy 1.0 rate is stored")
    /// Confirms same-currency bills hide obsolete conversion data because no conversion is needed.
    func effectiveFXRateNilForSameCurrencyEvenWithStoredRate() {
        let session = MenuSession(
            detectedLanguage: "日文",
            targetLanguage: "繁體中文",
            menuCurrency: "USD",
            homeCurrency: "usd",
            fxRate: 1.0
        )
        #expect(session.effectiveFXRate == nil)
    }

    @Test("effectiveFXRate passes the stored rate through for different currencies")
    /// Confirms different-currency bills expose their saved rate for conversion.
    func effectiveFXRatePassesThroughForDifferentCurrencies() {
        let session = MenuSession(
            detectedLanguage: "日文",
            targetLanguage: "繁體中文",
            menuCurrency: "JPY",
            homeCurrency: "USD",
            fxRate: 0.0067
        )
        #expect(session.effectiveFXRate == 0.0067)
    }
}
