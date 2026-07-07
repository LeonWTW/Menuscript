import Foundation
import SwiftUI

/// The Bill screen (WF-5): order lines, a surcharge/tax control, subtotal
/// through total, and an AA (even-split) section. Presentation only — all
/// arithmetic goes through `BillMath`; this view formats and lays it out.
/// Consumes only `Theme.swift` tokens.
struct BillView: View {
    @Bindable var session: MenuSession

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    @State private var isRefreshingRate = false

    private let surchargePresets: [Double] = [0, 8, 10]
    private let surchargeBounds: ClosedRange<Double> = 0...30
    private let peopleBounds: ClosedRange<Int> = 1...20

    private static let fxDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                orderLinesSection
                surchargeSection
                totalsSection
                aaSection
            }
            .padding(MTSpacing.screenMargin)
        }
        .background { Color.mtBackground.ignoresSafeArea() }
    }

    // MARK: - Derived data

    private var orderLines: [MenuItem] {
        session.items
            .filter { $0.quantity > 0 }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private var hasUnpricedLines: Bool {
        orderLines.contains { $0.priceValue == nil }
    }

    private var subtotal: Decimal {
        let lines: [(price: Decimal, qty: Int)] = orderLines.compactMap { item in
            guard let price = item.priceValue else { return nil }
            return (price: price, qty: item.quantity)
        }
        return BillMath.subtotal(lines: lines)
    }

    private var total: Decimal {
        BillMath.total(subtotal: subtotal, surchargePercent: session.surchargePercent)
    }

    private var surchargeAmount: Decimal {
        total - subtotal
    }

    private var menuFractionDigits: Int {
        BillMath.fractionDigits(forCurrency: session.menuCurrency)
    }

    private var homeFractionDigits: Int {
        BillMath.fractionDigits(forCurrency: session.homeCurrency)
    }

    /// Total converted to home currency, when an FX rate is available.
    private var convertedTotal: Decimal? {
        guard let fxRate = session.fxRate else { return nil }
        return BillMath.converted(total, rate: fxRate)
    }

    private var perPersonOriginal: Decimal {
        BillMath.perPerson(total: total, people: session.peopleCount, fractionDigits: menuFractionDigits)
    }

    /// Per-person share of the converted total (convert first, then split),
    /// rounded up at the home currency's fraction digits.
    private var perPersonConverted: Decimal? {
        guard let convertedTotal else { return nil }
        return BillMath.perPerson(total: convertedTotal, people: session.peopleCount, fractionDigits: homeFractionDigits)
    }

    // MARK: - Order lines

    private var orderLinesSection: some View {
        VStack(alignment: .leading, spacing: MTSpacing.cardGap) {
            ForEach(orderLines, id: \.persistentModelID) { item in
                orderLineRow(item)
            }
            if hasUnpricedLines {
                Text("＊ 未有標價嘅品項未計入總數")
                    .font(.footnote)
                    .foregroundStyle(Color.mtTextSecondary)
            }
        }
        .padding(MTSpacing.cardPadding)
        .background(sectionBackground)
    }

    private func orderLineRow(_ item: MenuItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(item.translatedName) ×\(item.quantity)")
                .font(.mtDishName)
                .foregroundStyle(Color.mtTextPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let priceValue = item.priceValue {
                Text(CurrencyFormat.format(priceValue * Decimal(item.quantity), code: session.menuCurrency))
                    .font(.mtPriceSecondary)
                    .foregroundStyle(Color.mtTextPrimary)
            } else {
                Text(item.priceNote ?? "時價")
                    .font(.mtPriceSecondary)
                    .foregroundStyle(Color.mtTextSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(orderLineAccessibilityLabel(item))
    }

    private func orderLineAccessibilityLabel(_ item: MenuItem) -> String {
        if let priceValue = item.priceValue {
            let lineTotal = CurrencyFormat.format(priceValue * Decimal(item.quantity), code: session.menuCurrency)
            return "\(item.translatedName)，\(item.quantity) 件，小計 \(lineTotal)"
        }
        return "\(item.translatedName)，\(item.quantity) 件，\(item.priceNote ?? "時價")，未計入總數"
    }

    // MARK: - Surcharge

    private var surchargeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("附加費／稅")
                .font(.mtChip)
                .foregroundStyle(Color.mtTextSecondary)
            surchargeControls
            if session.menuCurrency.uppercased() == "JPY" {
                Text("日本消費稅通常 10%（堂食）／8%（外賣）")
                    .font(.footnote)
                    .foregroundStyle(Color.mtTextSecondary)
            }
        }
        .padding(MTSpacing.cardPadding)
        .background(sectionBackground)
    }

    @ViewBuilder
    private var surchargeControls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                surchargePresetChips
                customSurchargeStepper
            }
        } else {
            HStack(spacing: 12) {
                surchargePresetChips
                Spacer(minLength: 8)
                customSurchargeStepper
            }
        }
    }

    private var surchargePresetChips: some View {
        HStack(spacing: 8) {
            ForEach(surchargePresets, id: \.self) { preset in
                surchargeChip(preset)
            }
        }
    }

    private func surchargeChip(_ preset: Double) -> some View {
        let isSelected = session.surchargePercent == preset
        return Button {
            session.surchargePercent = preset
        } label: {
            Text("\(Int(preset))%")
                .font(.mtChip)
                .fixedSize()
                .foregroundStyle(isSelected ? .white : Color.mtTextSecondary)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(surchargeChipBackground(isSelected: isSelected))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func surchargeChipBackground(isSelected: Bool) -> some View {
        let shape = Capsule()
        if isSelected {
            shape.fill(Color.mtAccent)
        } else if colorScheme == .light {
            shape
                .fill(Color.mtSurfaceElevated)
                .overlay(shape.strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
        } else {
            shape.fill(Color.mtSurfaceElevated)
        }
    }

    private var customSurchargeStepper: some View {
        Stepper(value: $session.surchargePercent, in: surchargeBounds, step: 1) {
            Text("自訂 \(Int(session.surchargePercent))%")
                .font(.mtChip)
                .foregroundStyle(Color.mtTextPrimary)
        }
        .tint(Color.mtAccent)
        .fixedSize()
    }

    // MARK: - Totals

    private var totalsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryRow(label: "小計", value: CurrencyFormat.format(subtotal, code: session.menuCurrency))
            summaryRow(label: "附加費", value: CurrencyFormat.format(surchargeAmount, code: session.menuCurrency))
            Divider()
            totalHero
            if session.menuCurrency.uppercased() != session.homeCurrency.uppercased() {
                fxStatusLine
            }
        }
        .padding(MTSpacing.cardPadding)
        .background(sectionBackground)
    }

    // MARK: - FX status

    /// Surfaces the rate actually used for this session's conversions (with
    /// its date) so a changed override/live rate is never silently at odds
    /// with what the user sees on screen, and explains the gap when no rate
    /// could be resolved at all instead of just omitting the conversion.
    private var fxStatusLine: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(fxStatusText)
                .font(.footnote)
                .foregroundStyle(Color.mtTextSecondary)
            Spacer(minLength: 8)
            refreshRateButton
        }
    }

    private var fxStatusText: String {
        guard let fxRate = session.fxRate else {
            return "攞唔到 \(session.menuCurrency)→\(session.homeCurrency) 匯率，可以喺設定入面手動輸入"
        }
        let rateText = String(format: "%.4f", fxRate)
        let dateText = session.fxRateDate.map { Self.fxDateFormatter.string(from: $0) }
        let rateDescription = "匯率 1 \(session.menuCurrency) ≈ \(rateText) \(session.homeCurrency)"
        return dateText.map { "\(rateDescription)（\($0)）" } ?? rateDescription
    }

    private var refreshRateButton: some View {
        Button {
            Task { await refreshFXRate() }
        } label: {
            if isRefreshingRate {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(Color.mtAccent)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .disabled(isRefreshingRate)
        .accessibilityLabel("更新匯率")
    }

    private func refreshFXRate() async {
        isRefreshingRate = true
        defer { isRefreshingRate = false }
        guard let fresh = await FXService().rate(from: session.menuCurrency, to: session.homeCurrency) else { return }
        session.fxRate = fresh.rate
        session.fxRateDate = fresh.date
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.footnote)
                .foregroundStyle(Color.mtTextSecondary)
            Spacer()
            Text(value)
                .font(.mtPriceSecondary)
                .foregroundStyle(Color.mtTextPrimary)
        }
    }

    @ViewBuilder
    private var totalHero: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    heroLabel("總數")
                    totalAmountStack(alignment: .leading)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    heroLabel("總數")
                    Spacer(minLength: 8)
                    totalAmountStack(alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("總數 \(totalAccessibilityValue)")
    }

    private func totalAmountStack(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if let convertedTotal {
                Text("≈ " + CurrencyFormat.format(convertedTotal, code: session.homeCurrency))
                    .font(.mtCartTotal)
                    .foregroundStyle(Color.mtPriceConverted)
                Text(CurrencyFormat.format(total, code: session.menuCurrency))
                    .font(.mtPriceSecondary)
                    .foregroundStyle(Color.mtPriceOriginal)
            } else {
                Text(CurrencyFormat.format(total, code: session.menuCurrency))
                    .font(.mtCartTotal)
                    .foregroundStyle(Color.mtPriceConverted)
            }
        }
    }

    private var totalAccessibilityValue: String {
        if let convertedTotal {
            let converted = CurrencyFormat.format(convertedTotal, code: session.homeCurrency)
            let original = CurrencyFormat.format(total, code: session.menuCurrency)
            return "約 \(converted)，原幣 \(original)"
        }
        return CurrencyFormat.format(total, code: session.menuCurrency)
    }

    // MARK: - AA (even split)

    private var aaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AA 埋單")
                .font(.mtChip)
                .foregroundStyle(Color.mtTextSecondary)
            peopleRow
            perPersonHero
            Text("每人銀碼向上取整，總收可能多出少許")
                .font(.footnote)
                .foregroundStyle(Color.mtTextSecondary)
        }
        .padding(MTSpacing.cardPadding)
        .background(sectionBackground)
    }

    private var peopleRow: some View {
        HStack {
            Text("人數")
                .font(.footnote)
                .foregroundStyle(Color.mtTextSecondary)
            Spacer()
            PeopleCountStepper(value: $session.peopleCount, bounds: peopleBounds)
        }
    }

    @ViewBuilder
    private var perPersonHero: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    heroLabel("每人應付")
                    perPersonAmountStack(alignment: .leading)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    heroLabel("每人應付")
                    Spacer(minLength: 8)
                    perPersonAmountStack(alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("每人應付 \(perPersonAccessibilityValue)")
    }

    private func perPersonAmountStack(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if let perPersonConverted {
                Text("≈ " + CurrencyFormat.format(perPersonConverted, code: session.homeCurrency))
                    .font(.mtCartTotal)
                    .foregroundStyle(Color.mtPriceConverted)
                Text(CurrencyFormat.format(perPersonOriginal, code: session.menuCurrency))
                    .font(.mtPriceSecondary)
                    .foregroundStyle(Color.mtPriceOriginal)
            } else {
                Text(CurrencyFormat.format(perPersonOriginal, code: session.menuCurrency))
                    .font(.mtCartTotal)
                    .foregroundStyle(Color.mtPriceConverted)
            }
        }
    }

    private var perPersonAccessibilityValue: String {
        if let perPersonConverted {
            let converted = CurrencyFormat.format(perPersonConverted, code: session.homeCurrency)
            let original = CurrencyFormat.format(perPersonOriginal, code: session.menuCurrency)
            return "約 \(converted)，原幣 \(original)"
        }
        return CurrencyFormat.format(perPersonOriginal, code: session.menuCurrency)
    }

    private func heroLabel(_ text: String) -> some View {
        Text(text)
            .font(.mtDishName)
            .foregroundStyle(Color.mtTextPrimary)
    }

    // MARK: - Chrome

    @ViewBuilder
    private var sectionBackground: some View {
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

/// Minus/count/plus stepper for the AA people count. Mirrors
/// `QuantityStepper`'s visual language but with a configurable range, since
/// people count needs 1...20 rather than the quantity stepper's fixed 0...99.
private struct PeopleCountStepper: View {
    @Binding var value: Int
    let bounds: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 0) {
            minusButton
            countText
            plusButton
        }
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("人數")
        .accessibilityValue("\(value) 人")
        .accessibilityAdjustableAction(handleAdjustment)
    }

    private var minusButton: some View {
        Button(action: decrement) {
            Image(systemName: "minus")
                .font(.subheadline.bold())
                .foregroundStyle(Color.mtAccent)
                .frame(width: 32, height: 32)
                .background(Circle().strokeBorder(Color.mtAccent, lineWidth: 1.5))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(value <= bounds.lowerBound)
        .opacity(value <= bounds.lowerBound ? 0.35 : 1)
        .accessibilityLabel("減少人數")
    }

    private var plusButton: some View {
        Button(action: increment) {
            Image(systemName: "plus")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.mtAccent))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(value >= bounds.upperBound)
        .opacity(value >= bounds.upperBound ? 0.35 : 1)
        .accessibilityLabel("增加人數")
    }

    private var countText: some View {
        Text("\(value) 人")
            .font(Font.mtDishName.monospacedDigit())
            .foregroundStyle(Color.mtTextPrimary)
            .frame(minWidth: 44)
            .multilineTextAlignment(.center)
    }

    private func increment() {
        value = min(bounds.upperBound, value + 1)
    }

    private func decrement() {
        value = max(bounds.lowerBound, value - 1)
    }

    private func handleAdjustment(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment:
            increment()
        case .decrement:
            decrement()
        @unknown default:
            break
        }
    }
}

#Preview {
    let session = MenuSession(
        detectedLanguage: "日文",
        targetLanguage: "繁體中文",
        menuCurrency: "JPY",
        homeCurrency: "HKD",
        fxRate: 0.052,
        peopleCount: 3,
        surchargePercent: 10
    )
    session.items = [
        MenuItem(originalName: "鷹の目", translatedName: "鷹眼壽司", priceValue: 1280, category: "壽司", quantity: 2, sortOrder: 0),
        MenuItem(originalName: "本日鮮魚", translatedName: "本日鮮魚", priceNote: "時價", category: "刺身", quantity: 1, sortOrder: 1),
        MenuItem(originalName: "生ビール", translatedName: "生啤", priceValue: 550, category: "飲品", quantity: 3, sortOrder: 2),
    ]
    return NavigationStack {
        BillView(session: session)
            .navigationTitle("帳單")
            .navigationBarTitleDisplayMode(.inline)
    }
}
