import Foundation
import SwiftUI

struct BillFXProviderSelection: Sendable {
    let provider: any FXRateProviding
    let mode: RuntimeMode
}

private struct MenuItemExplainSelection: Identifiable {
    let id = UUID()
    /// Mutable model ownership is limited to explanation cache persistence.
    let cacheOwner: MenuItem
    let context: MenuItemActionContext
}

private struct MenuItemPhotoSelection: Identifiable {
    let id = UUID()
    let context: MenuItemActionContext
}

/// The Menu screen (WF-4): category-filtered dish list with a floating cart
/// bar. Presentation only — screen data flows exclusively through
/// `MenuLogic`; explain (`ExplainSheet`) and checkout (`BillView`) are
/// presented as sheets.
struct MenuView: View {
    let session: MenuSession
    var onSessionCompleted: () -> Void = {}

    private let liveFXFactory: RuntimeServiceResolver.LiveFXFactory
    private let defaults: UserDefaults

    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedCategory: String?
    @State private var explainSelection: MenuItemExplainSelection?
    @State private var photoSearchSelection: MenuItemPhotoSelection?
    @State private var showBill = false
    @State private var showHistoryPhotos = false

    init(
        session: MenuSession,
        defaults: UserDefaults = .standard,
        onSessionCompleted: @escaping () -> Void = {}
    ) {
        self.session = session
        self.liveFXFactory = { FXService() }
        self.defaults = defaults
        self.onSessionCompleted = onSessionCompleted
    }

    init(
        session: MenuSession,
        liveFXProvider: any FXRateProviding,
        defaults: UserDefaults = .standard,
        onSessionCompleted: @escaping () -> Void = {}
    ) {
        self.session = session
        self.liveFXFactory = { liveFXProvider }
        self.defaults = defaults
        self.onSessionCompleted = onSessionCompleted
    }

    static func billFXSelection(
        for session: MenuSession,
        defaults: UserDefaults = .standard,
        liveFXFactory: RuntimeServiceResolver.LiveFXFactory
    ) -> BillFXProviderSelection {
        let mode = RuntimeServiceResolver.effectiveMode(
            persistedMode: session.providerMode,
            defaults: defaults
        )
        if mode == .mock {
            return BillFXProviderSelection(
                provider: MockFXService(),
                mode: .mock
            )
        }
        return BillFXProviderSelection(
            provider: liveFXFactory(),
            mode: .live
        )
    }

    private var billFXSelection: BillFXProviderSelection {
        Self.billFXSelection(
            for: session,
            defaults: defaults,
            liveFXFactory: liveFXFactory
        )
    }

    private var categories: [String] {
        MenuLogic.categories(items: session.items)
    }

    private var filteredItems: [MenuItem] {
        MenuLogic.filtered(items: session.items, category: selectedCategory)
    }


    private var hairlineColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.08)
    }

    var body: some View {
        sessionContent
            .background { Color.mtBackground.ignoresSafeArea() }
            .navigationTitle(session.title ?? L10n.string("菜單"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if session.hasPhotos {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showHistoryPhotos = true
                        } label: {
                            Label("菜單相片", systemImage: "photo.stack")
                        }
                    }
                }
            }
            .toolbarBackground(Color.mtBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(item: $explainSelection) { selection in
                explainSheet(for: selection)
            }
            .sheet(item: $photoSearchSelection) { selection in
                photoSearchSheet(for: selection.context)
            }
            .sheet(isPresented: $showBill) {
                NavigationStack {
                    BillView(
                        session: session,
                        fxProvider: billFXSelection.provider,
                        onCompleted: onSessionCompleted
                    )
                        .navigationTitle("帳單")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.large])
            }
            .sheet(isPresented: $showHistoryPhotos) {
                HistoryPhotoGalleryView(photos: session.photos)
            }
            #if DEBUG
            .task {
                applyAutoDemoScreenIfNeeded()
            }
            #endif
    }

    @ViewBuilder
    private var sessionContent: some View {
        switch MenuPresentationState.resolve(for: session) {
        case .content(let presentation):
            menuContent(presentation)
        case .unavailable(let reason):
            ContentUnavailableView(
                "帳單未能安全顯示",
                systemImage: "doc.text.magnifyingglass",
                description: Text(reason.localizedMessage)
            )
        }
    }

    private func menuContent(_ presentation: MenuOrderPresentation) -> some View {
        ScrollView {
            if filteredItems.isEmpty {
                emptyCategoryState
            } else {
                VStack(spacing: MTSpacing.cardGap) {
                    LazyVStack(spacing: MTSpacing.cardGap) {
                        ForEach(filteredItems, id: \.persistentModelID) { item in
                            let cardPresentation = presentation.snapshot.map {
                                MenuItemCardPresentation.completed(item, snapshot: $0)
                            } ?? MenuItemCardPresentation.live(item)
                            let actionContext = MenuItemActionContext.make(
                                cardPresentation: cardPresentation,
                                lowConfidence: item.lowConfidence,
                                session: session,
                                snapshot: presentation.snapshot
                            )
                            MenuItemCard(
                                item: item,
                                menuCurrency: presentation.menuCurrency,
                                homeCurrency: presentation.homeCurrency,
                                fxRate: presentation.fxRate,
                                presentation: cardPresentation,
                                actionContext: actionContext,
                                onExplain: {
                                    explainSelection = MenuItemExplainSelection(
                                        cacheOwner: item,
                                        context: $0
                                    )
                                },
                                onPhotoSearch: {
                                    photoSearchSelection = MenuItemPhotoSelection(context: $0)
                                }
                            )
                        }
                    }
                    if !session.allergenProfile.isEmpty {
                        allergenFootnote
                    }
                }
                .padding(.horizontal, MTSpacing.screenMargin)
            }
        }
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
            if presentation.cartTotals.count > 0 {
                CartBar(
                    kindCount: presentation.cartTotals.kinds,
                    totalQuantity: presentation.cartTotals.count,
                    totalOriginalText: CurrencyFormat.format(
                        presentation.cartTotals.subtotal,
                        code: presentation.menuCurrency
                    ),
                    totalConvertedText: presentation.convertedSubtotal.map {
                        "≈ " + CurrencyFormat.format($0, code: presentation.homeCurrency)
                    },
                    hasUnpriced: presentation.cartTotals.hasUnpriced,
                    isCompleted: presentation.isReadOnly,
                    onCheckout: { showBill = true }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: presentation.cartTotals.count > 0)
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

    private func explainSheet(for selection: MenuItemExplainSelection) -> some View {
        ExplainSheet(
            item: selection.cacheOwner,
            actionContext: selection.context,
            onDeleteAllSucceeded: onSessionCompleted
        )
    }

    @ViewBuilder
    private func photoSearchSheet(for context: MenuItemActionContext) -> some View {
        if let url = PhotoSearch.imagesURL(query: context.photoSearchQuery) {
            SafariView(url: url)
                .ignoresSafeArea()
        } else {
            Text("無法建立搜尋連結")
        }
    }

    private var allergenFootnote: some View {
        Text("敏感原警示根據辨識當時嘅設定，僅供參考，落單前請同餐廳確認。")
            .font(.footnote)
            .foregroundStyle(Color.mtTextSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 12)
    }

    #if DEBUG
    /// Deep link for automated screenshots/demos: jumps straight into a
    /// sheet based on the "autoDemoScreen" UserDefaults string.
    private func applyAutoDemoScreenIfNeeded() {
        switch UserDefaults.standard.string(forKey: "autoDemoScreen") {
        case "bill":
            showBill = true
        case "explain":
            guard case .content(let presentation) = MenuPresentationState.resolve(for: session),
                  let item = MenuLogic.filtered(items: session.items, category: nil).first else {
                return
            }
            let cardPresentation = presentation.snapshot.map {
                MenuItemCardPresentation.completed(item, snapshot: $0)
            } ?? MenuItemCardPresentation.live(item)
            explainSelection = MenuItemExplainSelection(
                cacheOwner: item,
                context: MenuItemActionContext.make(
                    cardPresentation: cardPresentation,
                    lowConfidence: item.lowConfidence,
                    session: session,
                    snapshot: presentation.snapshot
                )
            )
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
