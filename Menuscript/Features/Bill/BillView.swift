import Foundation
import SwiftUI

enum BillFXPresentation {
    /// Returns the localized source key for an unavailable FX refresh. Demo
    /// fixtures have finite coverage, while live mode failures may be network
    /// related, so the two cases must not surface the same explanation.
    static func unavailableMessageKey(for providerMode: RuntimeMode?) -> String {
        providerMode == .mock
            ? "示範模式暫時唔支援呢個貨幣組合，請喺設定揀另一隻貨幣。"
            : "暫時攞唔到最新匯率，請檢查網絡或稍後再試。"
    }

    static func quoteDate(
        quoteDate: String?,
        legacyDate: Date?
    ) -> String? {
        if let quoteDate,
           FXQuoteDate.isCanonical(quoteDate) {
            return quoteDate
        }
        guard let legacyDate else {
            return nil
        }
        return FXQuoteDate.string(from: legacyDate)
    }
}

@MainActor
enum BillFXRefresh {
    static func fetch(
        for session: MenuSession,
        provider: any FXRateProviding
    ) async -> FXRate? {
        guard !session.isCompleted,
              session.menuCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                != session.homeCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              let fresh = await provider.rate(
                from: session.menuCurrency,
                to: session.homeCurrency
              ) else {
            return nil
        }
        return fresh
    }
}

/// The Bill screen (WF-5): order lines, a surcharge/tax control, subtotal
/// through total, and an AA (even-split) section. Presentation only — all
/// arithmetic goes through `BillMath`; this view formats and lays it out.
/// Consumes only `Theme.swift` tokens.
struct BillView: View {
    @Bindable var session: MenuSession
    var onCompleted: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    @State private var isRefreshingRate = false
    @State private var isFinalizing = false
    @State private var finalizeErrorMessage: String?
    @State private var fxRefreshErrorMessage: String?

    private let fxProvider: any FXRateProviding
    private let fxProviderMode: RuntimeMode

    private let surchargePresets: [Double] = [0, 8, 10]
    private let surchargeBounds: ClosedRange<Double> = 0...30
    private let peopleBounds: ClosedRange<Int> = 1...20

    init(
        session: MenuSession,
        fxProvider: any FXRateProviding,
        fxProviderMode: RuntimeMode,
        onCompleted: @escaping () -> Void = {}
    ) {
        self.session = session
        self.fxProvider = fxProvider
        self.fxProviderMode = fxProviderMode
        self.onCompleted = onCompleted
    }

    var body: some View {
        Group {
            switch BillPresentationState.resolve(for: session) {
            case .content(let display):
                billContent(display)
            case .unavailable(let reason):
                ContentUnavailableView(
                    "帳單未能安全顯示",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(reason.localizedMessage)
                )
            }
        }
        .background { Color.mtBackground.ignoresSafeArea() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    completeOrDismiss()
                }
                .disabled(isFinalizing)
            }
        }
        .alert("帳單", isPresented: finalizeErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(finalizeErrorMessage ?? "")
        }
        .alert("更新匯率失敗", isPresented: fxRefreshErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(fxRefreshErrorMessage ?? "")
        }
    }

    private func billContent(_ display: BillDisplayModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                orderLinesSection(display)
                surchargeSection(display)
                totalsSection(display)
                aaSection(display)
            }
            .padding(MTSpacing.screenMargin)
        }
    }

    // MARK: - Order lines

    private func orderLinesSection(_ display: BillDisplayModel) -> some View {
        VStack(alignment: .leading, spacing: MTSpacing.cardGap) {
            ForEach(display.lines) { line in
                orderLineRow(line, display: display)
            }
            if display.hasUnpricedLines {
                Text("＊ 未有標價嘅品項未計入總數")
                    .font(.footnote)
                    .foregroundStyle(Color.mtTextSecondary)
            }
        }
        .padding(MTSpacing.cardPadding)
        .background(sectionBackground)
    }

    private func orderLineRow(
        _ line: BillDisplayLine,
        display: BillDisplayModel
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(line.translatedName) ×\(line.quantity)")
                .font(.mtDishName)
                .foregroundStyle(Color.mtTextPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let unitPrice = line.unitPrice {
                Text(CurrencyFormat.format(
                    unitPrice * Decimal(line.quantity),
                    code: display.menuCurrency
                ))
                    .font(.mtPriceSecondary)
                    .foregroundStyle(Color.mtTextPrimary)
            } else {
                Text(line.priceNote ?? L10n.string("時價"))
                    .font(.mtPriceSecondary)
                    .foregroundStyle(Color.mtTextSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(orderLineAccessibilityLabel(line, display: display))
    }

    private func orderLineAccessibilityLabel(
        _ line: BillDisplayLine,
        display: BillDisplayModel
    ) -> String {
        if let unitPrice = line.unitPrice {
            let lineTotal = CurrencyFormat.format(
                unitPrice * Decimal(line.quantity),
                code: display.menuCurrency
            )
            return L10n.string("%@，%lld 件，小計 %@", line.translatedName, line.quantity, lineTotal)
        }
        return L10n.string(
            "%@，%lld 件，%@，未計入總數",
            line.translatedName,
            line.quantity,
            line.priceNote ?? L10n.string("時價")
        )
    }

    // MARK: - Surcharge

    private func surchargeSection(_ display: BillDisplayModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("附加費／稅")
                .font(.mtChip)
                .foregroundStyle(Color.mtTextSecondary)
            if display.isReadOnly {
                Text(verbatim: "\(display.surchargePercent.formatted())%")
                    .font(.mtDishName)
                    .foregroundStyle(Color.mtTextPrimary)
                    .accessibilityLabel("附加費／稅 \(display.surchargePercent.formatted())%")
            } else {
                surchargeControls
            }
            if display.menuCurrency.uppercased() == "JPY" {
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

    private func totalsSection(_ display: BillDisplayModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryRow(
                label: "小計",
                value: CurrencyFormat.format(display.subtotal, code: display.menuCurrency)
            )
            summaryRow(
                label: "附加費",
                value: CurrencyFormat.format(display.surchargeAmount, code: display.menuCurrency)
            )
            Divider()
            totalHero(display)
            if display.menuCurrency.uppercased() != display.homeCurrency.uppercased() {
                fxStatusLine(display)
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
    private func fxStatusLine(_ display: BillDisplayModel) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(fxStatusText(display))
                .font(.footnote)
                .foregroundStyle(Color.mtTextSecondary)
            Spacer(minLength: 8)
            if !display.isReadOnly {
                refreshRateButton
            }
        }
    }

    private func fxStatusText(_ display: BillDisplayModel) -> String {
        guard let fxRate = display.fxRate else {
            return L10n.string(
                "攞唔到 %@→%@ 匯率，可以喺設定入面手動輸入",
                display.menuCurrency,
                display.homeCurrency
            )
        }
        let rateText = String(format: "%.4f", fxRate)
        let dateText = BillFXPresentation.quoteDate(
            quoteDate: display.fxQuoteDate,
            legacyDate: display.fxRateDate
        )
        let rateDescription = L10n.string(
            "匯率 1 %@ ≈ %@ %@",
            display.menuCurrency,
            rateText,
            display.homeCurrency
        )
        if display.fxSource == "manual" {
            return dateText.map { L10n.string("%@（手動設定於 %@）", rateDescription, $0) } ?? L10n.string("%@（手動設定）", rateDescription)
        }
        if display.fxSource == "mock" {
            return dateText.map { L10n.string("%@（示範匯率，%@）", rateDescription, $0) }
                ?? L10n.string("%@（示範匯率）", rateDescription)
        }
        return dateText.map { L10n.string("%@（%@）", rateDescription, $0) } ?? rateDescription
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
        guard !session.isCompleted,
              session.menuCurrency.uppercased() != session.homeCurrency.uppercased() else { return }
        fxRefreshErrorMessage = nil
        isRefreshingRate = true
        defer { isRefreshingRate = false }
        guard let fresh = await BillFXRefresh.fetch(
            for: session,
            provider: fxProvider
        ) else {
            fxRefreshErrorMessage = L10n.string(
                BillFXPresentation.unavailableMessageKey(for: fxProviderMode)
            )
            return
        }
        do {
            try SessionStore(context: modelContext).updateFXRate(fresh, for: session)
        } catch {
            fxRefreshErrorMessage = L10n.string(
                "最新匯率未能儲存，請稍後再試。"
            )
        }
    }

    private var fxRefreshErrorBinding: Binding<Bool> {
        Binding(
            get: { fxRefreshErrorMessage != nil },
            set: { if !$0 { fxRefreshErrorMessage = nil } }
        )
    }

    private func summaryRow(label: LocalizedStringKey, value: String) -> some View {
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
    private func totalHero(_ display: BillDisplayModel) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    heroLabel("總數")
                    totalAmountStack(display, alignment: .leading)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    heroLabel("總數")
                    Spacer(minLength: 8)
                    totalAmountStack(display, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("總數 \(totalAccessibilityValue(display))")
    }

    private func totalAmountStack(
        _ display: BillDisplayModel,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if let convertedTotal = display.convertedTotal {
                Text("≈ " + CurrencyFormat.format(convertedTotal, code: display.homeCurrency))
                    .font(.mtCartTotal)
                    .foregroundStyle(Color.mtPriceConverted)
                Text(CurrencyFormat.format(display.total, code: display.menuCurrency))
                    .font(.mtPriceSecondary)
                    .foregroundStyle(Color.mtPriceOriginal)
            } else {
                Text(CurrencyFormat.format(display.total, code: display.menuCurrency))
                    .font(.mtCartTotal)
                    .foregroundStyle(Color.mtPriceConverted)
            }
        }
    }

    private func totalAccessibilityValue(_ display: BillDisplayModel) -> String {
        if let convertedTotal = display.convertedTotal {
            let converted = CurrencyFormat.format(convertedTotal, code: display.homeCurrency)
            let original = CurrencyFormat.format(display.total, code: display.menuCurrency)
            return L10n.string("約 %@，原幣 %@", converted, original)
        }
        return CurrencyFormat.format(display.total, code: display.menuCurrency)
    }

    // MARK: - AA (even split)

    private func aaSection(_ display: BillDisplayModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AA 埋單")
                .font(.mtChip)
                .foregroundStyle(Color.mtTextSecondary)
            peopleRow(display)
            perPersonHero(display)
            Text("每人銀碼向上取整，總收可能多出少許")
                .font(.footnote)
                .foregroundStyle(Color.mtTextSecondary)
        }
        .padding(MTSpacing.cardPadding)
        .background(sectionBackground)
    }

    private func peopleRow(_ display: BillDisplayModel) -> some View {
        HStack {
            Text("人數")
                .font(.footnote)
                .foregroundStyle(Color.mtTextSecondary)
            Spacer()
            if display.isReadOnly {
                Text("\(display.peopleCount) 人")
                    .font(Font.mtDishName.monospacedDigit())
                    .foregroundStyle(Color.mtTextPrimary)
            } else {
                PeopleCountStepper(value: $session.peopleCount, bounds: peopleBounds)
            }
        }
    }

    @ViewBuilder
    private func perPersonHero(_ display: BillDisplayModel) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    heroLabel("每人應付")
                    perPersonAmountStack(display, alignment: .leading)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    heroLabel("每人應付")
                    Spacer(minLength: 8)
                    perPersonAmountStack(display, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("每人應付 \(perPersonAccessibilityValue(display))")
    }

    private func perPersonAmountStack(
        _ display: BillDisplayModel,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if let perPersonConverted = display.perPersonConverted {
                Text("≈ " + CurrencyFormat.format(perPersonConverted, code: display.homeCurrency))
                    .font(.mtCartTotal)
                    .foregroundStyle(Color.mtPriceConverted)
                Text(CurrencyFormat.format(display.perPersonOriginal, code: display.menuCurrency))
                    .font(.mtPriceSecondary)
                    .foregroundStyle(Color.mtPriceOriginal)
            } else {
                Text(CurrencyFormat.format(display.perPersonOriginal, code: display.menuCurrency))
                    .font(.mtCartTotal)
                    .foregroundStyle(Color.mtPriceConverted)
            }
        }
    }

    private func perPersonAccessibilityValue(_ display: BillDisplayModel) -> String {
        if let perPersonConverted = display.perPersonConverted {
            let converted = CurrencyFormat.format(perPersonConverted, code: display.homeCurrency)
            let original = CurrencyFormat.format(display.perPersonOriginal, code: display.menuCurrency)
            return L10n.string("約 %@，原幣 %@", converted, original)
        }
        return CurrencyFormat.format(display.perPersonOriginal, code: display.menuCurrency)
    }

    private func heroLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.mtDishName)
            .foregroundStyle(Color.mtTextPrimary)
    }

    // MARK: - Completion

    private var finalizeErrorBinding: Binding<Bool> {
        Binding(
            get: { finalizeErrorMessage != nil },
            set: { if !$0 { finalizeErrorMessage = nil } }
        )
    }

    private func completeOrDismiss() {
        if session.isCompleted {
            dismiss()
            return
        }

        isFinalizing = true
        defer { isFinalizing = false }
        do {
            _ = try SessionStore(context: modelContext).finalize(session)
            dismiss()
            onCompleted()
        } catch {
            finalizeErrorMessage = error.localizedDescription
        }
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
        homeCurrency: "USD",
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
        BillView(
            session: session,
            fxProvider: MockFXService(),
            fxProviderMode: .mock
        )
            .navigationTitle("帳單")
            .navigationBarTitleDisplayMode(.inline)
    }
}
