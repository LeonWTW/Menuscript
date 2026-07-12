import Foundation
import SwiftUI

/// The Menu screen (WF-4): category-filtered dish list with a floating cart
/// bar. Presentation only — screen data flows exclusively through
/// `MenuLogic`; explain (`ExplainSheet`) and checkout (`BillView`) are
/// presented as sheets.
struct MenuView: View {
    let session: MenuSession

    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedCategory: String?
    @State private var explainItem: MenuItem?
    @State private var showBill = false

    private var categories: [String] {
        MenuLogic.categories(items: session.items)
    }

    private var filteredItems: [MenuItem] {
        MenuLogic.filtered(items: session.items, category: selectedCategory)
    }

    private var cartTotals: (kinds: Int, count: Int, subtotal: Decimal, hasUnpriced: Bool) {
        MenuLogic.totals(items: session.items)
    }

    private var isCartVisible: Bool {
        cartTotals.count > 0
    }

    private var originalSubtotalText: String {
        CurrencyFormat.format(cartTotals.subtotal, code: session.menuCurrency)
    }

    private var convertedSubtotalText: String? {
        guard let fxRate = session.effectiveFXRate else { return nil }
        let converted = BillMath.converted(cartTotals.subtotal, rate: fxRate)
        return "≈ " + CurrencyFormat.format(converted, code: session.homeCurrency)
    }

    private var hairlineColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.08)
    }

    var body: some View {
        ScrollView {
            if filteredItems.isEmpty {
                emptyCategoryState
            } else {
                LazyVStack(spacing: MTSpacing.cardGap) {
                    ForEach(filteredItems, id: \.persistentModelID) { item in
                        MenuItemCard(
                            item: item,
                            menuCurrency: session.menuCurrency,
                            homeCurrency: session.homeCurrency,
                            fxRate: session.effectiveFXRate,
                            onExplain: { explainItem = $0 }
                        )
                    }
                }
                .padding(.horizontal, MTSpacing.screenMargin)
            }
        }
        .background { Color.mtBackground.ignoresSafeArea() }
        .navigationTitle(session.title ?? L10n.string("菜單"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.mtBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            CategoryChipsBar(categories: categories, selection: $selectedCategory)
                .background(Color.mtBackground)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(hairlineColor)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isCartVisible {
                CartBar(
                    kindCount: cartTotals.kinds,
                    totalQuantity: cartTotals.count,
                    totalOriginalText: originalSubtotalText,
                    totalConvertedText: convertedSubtotalText,
                    hasUnpriced: cartTotals.hasUnpriced,
                    onCheckout: { showBill = true }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: isCartVisible)
        .sheet(item: $explainItem) { item in
            explainSheet(for: item)
        }
        .sheet(isPresented: $showBill) {
            NavigationStack {
                BillView(session: session)
                    .navigationTitle("帳單")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showBill = false }
                        }
                    }
            }
            .presentationDetents([.large])
        }
        #if DEBUG
        .task {
            applyAutoDemoScreenIfNeeded()
        }
        #endif
    }

    private var emptyCategoryState: some View {
        VStack(spacing: 8) {
            Image(systemName: "fork.knife")
                .font(.title2)
                .foregroundStyle(Color.mtTextSecondary)
            Text("此分類沒有菜式")
                .font(.footnote)
                .foregroundStyle(Color.mtTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .accessibilityElement(children: .combine)
    }

    private func explainSheet(for item: MenuItem) -> some View {
        ExplainSheet(item: item)
    }

    #if DEBUG
    /// Deep link for automated screenshots/demos: jumps straight into a
    /// sheet based on the "autoDemoScreen" UserDefaults string.
    private func applyAutoDemoScreenIfNeeded() {
        switch UserDefaults.standard.string(forKey: "autoDemoScreen") {
        case "bill":
            showBill = true
        case "explain":
            explainItem = MenuLogic.filtered(items: session.items, category: nil).first
        default:
            break
        }
    }
    #endif
}

#Preview {
    NavigationStack {
        MenuView(session: MenuSession(
            detectedLanguage: "日文",
            targetLanguage: "繁體中文",
            menuCurrency: "JPY",
            homeCurrency: "USD"
        ))
    }
}
