import SwiftUI

/// A single menu line: translated name (hero), original name (what the user
/// points at when ordering), a price block that leads with the home-currency
/// conversion, and a quantity stepper. Consumes only `Theme.swift` tokens.
struct MenuItemCard: View {
    @Bindable var item: MenuItem
    let menuCurrency: String
    let homeCurrency: String
    let fxRate: Double?
    var onExplain: (MenuItem) -> Void
    var onPhotoSearch: (MenuItem) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAllergenAlert = false

    var body: some View {
        cardBody
            .alert(Text("可能含有敏感原"), isPresented: $showAllergenAlert) {
                Button("確定") { }
            } message: {
                Text(allergenAlertMessage)
            }
    }

    /// The card surface plus, when the dish has flagged allergens, a VoiceOver
    /// custom action that opens the same alert as the (a11y-hidden) icon button.
    @ViewBuilder
    private var cardBody: some View {
        let card = VStack(alignment: .leading, spacing: 12) {
            header
            footer
        }
        .padding(MTSpacing.cardPadding)
        .background(cardBackground)
        .accessibilityElement(children: .contain)

        if item.possibleAllergens.isEmpty {
            card
        } else {
            card.accessibilityAction(named: Text("顯示敏感原警告")) {
                showAllergenAlert = true
            }
        }
    }

    // MARK: - Header (name + actions)

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            nameBlock
            Spacer(minLength: 8)
            photoButton
            explainButton
        }
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.translatedName)
                    .font(.mtDishName)
                    .foregroundStyle(Color.mtTextPrimary)
                    .lineLimit(2)
                if item.lowConfidence {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.mtWarning)
                        .accessibilityHidden(true)
                }
                if !item.possibleAllergens.isEmpty {
                    allergenButton
                }
            }
            Text(item.originalName)
                .font(.mtOriginalName)
                .foregroundStyle(Color.mtTextSecondary)
                .lineLimit(2)
                .textSelection(.enabled)
            if let summary = item.summary, !summary.isEmpty {
                Text(verbatim: summary)
                    .font(.footnote)
                    .foregroundStyle(Color.mtTextSecondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// Advisory allergen marker. VoiceOver reaches the alert through the card's
    /// custom action and the spoken summary, so the icon itself is hidden.
    private var allergenButton: some View {
        Button {
            showAllergenAlert = true
        } label: {
            Image(systemName: "allergens")
                .font(.footnote)
                .foregroundStyle(Color.mtWarning)
                // The glyph stays footnote-sized inline with the dish name; the
                // negative inset grows the tap target to ~45pt (HIG minimum)
                // without disturbing the baseline layout.
                .contentShape(Rectangle().inset(by: -14))
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    private var photoButton: some View {
        Button {
            onPhotoSearch(item)
        } label: {
            Image(systemName: "photo")
                .font(.body)
                .foregroundStyle(Color.mtTextSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("搵菜式相片")
    }

    private var explainButton: some View {
        Button {
            onExplain(item)
        } label: {
            Image(systemName: "info.circle")
                .font(.body)
                .foregroundStyle(Color.mtTextSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("解釋菜式")
    }

    // MARK: - Footer (price + stepper)

    @ViewBuilder
    private var footer: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                priceBlock
                QuantityStepper(value: $item.quantity)
            }
        } else {
            HStack(alignment: .center) {
                priceBlock
                Spacer()
                QuantityStepper(value: $item.quantity)
            }
        }
    }

    /// Gold is reserved for numbers the traveller decides with; the 時價
    /// fallback is words, so it stays in the primary text color.
    @ViewBuilder
    private var priceBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let priceValue = item.priceValue {
                if let fxRate {
                    Text("≈ \(CurrencyFormat.format(BillMath.converted(priceValue, rate: fxRate), code: homeCurrency))")
                        .font(.mtPrice)
                        .foregroundStyle(Color.mtPriceConverted)
                    Text(CurrencyFormat.format(priceValue, code: menuCurrency))
                        .font(.mtPriceSecondary)
                        .foregroundStyle(Color.mtPriceOriginal)
                } else {
                    Text(CurrencyFormat.format(priceValue, code: menuCurrency))
                        .font(.mtPrice)
                        .foregroundStyle(Color.mtPriceConverted)
                }
            } else {
                Text(item.priceNote ?? L10n.string("時價"))
                    .font(.mtDishName)
                    .foregroundStyle(Color.mtTextPrimary)
            }
        }
        .accessibilityHidden(true)
    }

    private var accessibilitySummary: String {
        var text = L10n.string("%@，原文 %@", item.translatedName, item.originalName)
        if let priceValue = item.priceValue {
            if let fxRate {
                let converted = CurrencyFormat.format(BillMath.converted(priceValue, rate: fxRate), code: homeCurrency)
                let original = CurrencyFormat.format(priceValue, code: menuCurrency)
                text += L10n.string("，約 %@，原價 %@", converted, original)
            } else {
                text += L10n.string("，%@", CurrencyFormat.format(priceValue, code: menuCurrency))
            }
        } else {
            text += L10n.string("，%@", item.priceNote ?? L10n.string("時價"))
        }
        if let summary = item.summary, !summary.isEmpty {
            text += L10n.string("，%@", summary)
        }
        if item.lowConfidence {
            text += L10n.string("，翻譯可能不準確")
        }
        if !item.possibleAllergens.isEmpty {
            let labels = item.possibleAllergens.map(Allergen.displayLabel)
                .joined(separator: L10n.string("、"))
            text += L10n.string("，可能含有 %@，請與餐廳確認", labels)
        }
        return text
    }

    private var allergenAlertMessage: String {
        let labels = item.possibleAllergens.map(Allergen.displayLabel)
            .joined(separator: L10n.string("、"))
        let disclaimer = L10n.string("AI 推測僅供參考，落單前請務必同餐廳確認。")
        return labels.isEmpty ? disclaimer : labels + "\n\n" + disclaimer
    }

    // MARK: - Card chrome

    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: MTRadius.card, style: .continuous)
        if colorScheme == .dark {
            shape
                .fill(Color.mtSurface)
                .overlay(shape.strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        } else {
            shape
                .fill(Color.mtSurface)
                .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: MTSpacing.cardGap) {
            MenuItemCard(
                item: MenuItem(
                    originalName: "鷹の目",
                    translatedName: "鷹眼壽司",
                    priceValue: 1280,
                    category: "壽司",
                    lowConfidence: true,
                    quantity: 1,
                    sortOrder: 0
                ),
                menuCurrency: "JPY",
                homeCurrency: "USD",
                fxRate: 0.052,
                onExplain: { _ in },
                onPhotoSearch: { _ in }
            )
            MenuItemCard(
                item: MenuItem(
                    originalName: "本日鮮魚",
                    translatedName: "本日鮮魚",
                    category: "刺身",
                    quantity: 0,
                    sortOrder: 1
                ),
                menuCurrency: "JPY",
                homeCurrency: "USD",
                fxRate: 0.052,
                onExplain: { _ in },
                onPhotoSearch: { _ in }
            )
            MenuItemCard(
                item: {
                    let item = MenuItem(
                        originalName: "生ビール",
                        translatedName: "生啤",
                        priceValue: 550,
                        category: "飲品",
                        quantity: 2,
                        sortOrder: 2
                    )
                    item.summary = "日式生啤酒，冰凍暢飲"
                    item.possibleAllergens = ["gluten", "wheat"]
                    return item
                }(),
                menuCurrency: "JPY",
                homeCurrency: "USD",
                fxRate: nil,
                onExplain: { _ in },
                onPhotoSearch: { _ in }
            )
            MenuItemCard(
                item: {
                    let item = MenuItem(
                        originalName: "季節野菜",
                        translatedName: "時令蔬菜",
                        priceValue: 680,
                        category: "前菜",
                        quantity: 0,
                        sortOrder: 3
                    )
                    item.summary = "當造時令蔬菜，清爽開胃"
                    return item
                }(),
                menuCurrency: "JPY",
                homeCurrency: "USD",
                fxRate: 0.052,
                onExplain: { _ in },
                onPhotoSearch: { _ in }
            )
        }
        .padding(MTSpacing.screenMargin)
    }
    .background(Color.mtBackground)
}
