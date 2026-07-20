import Foundation

struct MenuCartTotals: Equatable, Sendable {
    let kinds: Int
    let count: Int
    let subtotal: Decimal
    let hasUnpriced: Bool
}

/// A valid menu/order presentation. No instance is produced for an unavailable
/// completed snapshot, which prevents the menu from rebuilding an order from
/// mutable `MenuItem` values.
struct MenuOrderPresentation: Equatable, Sendable {
    let isReadOnly: Bool
    let snapshot: BillSnapshot?
    let menuCurrency: String
    let homeCurrency: String
    let fxRate: Double?
    let convertedSubtotal: Decimal?
    let cartTotals: MenuCartTotals

    static func draft(_ session: MenuSession) -> MenuOrderPresentation {
        let totals = MenuLogic.totals(items: session.items)
        let fxRate = session.effectiveFXRate
        return MenuOrderPresentation(
            isReadOnly: false,
            snapshot: nil,
            menuCurrency: session.menuCurrency,
            homeCurrency: session.homeCurrency,
            fxRate: fxRate,
            convertedSubtotal: fxRate.map {
                BillMath.converted(totals.subtotal, rate: $0)
            },
            cartTotals: MenuCartTotals(
                kinds: totals.kinds,
                count: totals.count,
                subtotal: totals.subtotal,
                hasUnpriced: totals.hasUnpriced
            )
        )
    }

    static func completed(_ snapshot: BillSnapshot) -> MenuOrderPresentation {
        MenuOrderPresentation(
            isReadOnly: true,
            snapshot: snapshot,
            menuCurrency: snapshot.menuCurrency,
            homeCurrency: snapshot.homeCurrency,
            fxRate: snapshot.fxRate,
            convertedSubtotal: snapshot.convertedSubtotal,
            cartTotals: MenuCartTotals(
                kinds: snapshot.lines.count,
                count: snapshot.lines.reduce(0) { $0 + $1.quantity },
                subtotal: snapshot.subtotal,
                hasUnpriced: snapshot.hasUnpricedItems
            )
        )
    }
}

enum MenuPresentationState: Equatable, Sendable {
    case content(MenuOrderPresentation)
    case unavailable(SessionBillUnavailableReason)

    static func resolve(for session: MenuSession) -> MenuPresentationState {
        switch session.billState {
        case .draft:
            return .content(.draft(session))
        case .completed(let snapshot):
            return .content(.completed(snapshot))
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }

    var orderPresentation: MenuOrderPresentation? {
        guard case .content(let presentation) = self else { return nil }
        return presentation
    }
}

struct MenuItemCardPresentation: Equatable, Sendable {
    let originalName: String
    let translatedName: String
    let unitPrice: Decimal?
    let priceNote: String?
    let quantity: Int
    let isQuantityReadOnly: Bool
    /// Nil for a draft, true for a frozen selected line, false for descriptive
    /// live menu content that was not part of the completed order.
    let isInCompletedOrder: Bool?

    static func live(
        _ item: MenuItem,
        isQuantityReadOnly: Bool = false
    ) -> MenuItemCardPresentation {
        MenuItemCardPresentation(
            originalName: item.originalName,
            translatedName: item.translatedName,
            unitPrice: item.priceValue,
            priceNote: item.priceNote,
            quantity: item.quantity,
            isQuantityReadOnly: isQuantityReadOnly,
            isInCompletedOrder: nil
        )
    }

    static func completed(
        _ item: MenuItem,
        snapshot: BillSnapshot
    ) -> MenuItemCardPresentation {
        guard let line = snapshot.lines.first(where: { $0.sortOrder == item.sortOrder }) else {
            return MenuItemCardPresentation(
                originalName: item.originalName,
                translatedName: item.translatedName,
                unitPrice: item.priceValue,
                priceNote: item.priceNote,
                quantity: 0,
                isQuantityReadOnly: true,
                isInCompletedOrder: false
            )
        }
        return MenuItemCardPresentation(
            originalName: line.originalName,
            translatedName: line.translatedName,
            unitPrice: line.unitPrice,
            priceNote: line.priceNote,
            quantity: line.quantity,
            isQuantityReadOnly: true,
            isInCompletedOrder: true
        )
    }
}

/// Immutable inputs for actions launched from a menu card. Completed-card
/// values are captured from the bill snapshot/card presentation, while the
/// mutable `MenuItem` remains outside this value and is used only as the cache
/// owner for a generated explanation.
struct MenuItemActionContext: Equatable, Sendable {
    let originalName: String
    let translatedName: String
    let detectedLanguage: String
    let targetLanguage: String
    let lowConfidence: Bool
    /// Nil is meaningful for a legacy snapshot: runtime selection must follow
    /// current preferences instead of falling through to a mutable session.
    let providerMode: RuntimeMode?

    var photoSearchQuery: String {
        let trimmed = originalName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? translatedName : trimmed
    }

    static func make(
        cardPresentation: MenuItemCardPresentation,
        lowConfidence: Bool,
        session: MenuSession,
        snapshot: BillSnapshot?
    ) -> MenuItemActionContext {
        let providerMode: RuntimeMode?
        if let snapshot {
            providerMode = snapshot.providerModeRaw.flatMap(RuntimeMode.init(rawValue:))
        } else {
            providerMode = session.providerMode
        }

        return MenuItemActionContext(
            originalName: cardPresentation.originalName,
            translatedName: cardPresentation.translatedName,
            detectedLanguage: session.detectedLanguage,
            targetLanguage: session.targetLanguage,
            lowConfidence: lowConfidence,
            providerMode: providerMode
        )
    }

    /// Compatibility path for direct card/sheet construction and previews.
    /// Production `MenuView` supplies `make(...)` so completed values are
    /// snapshot-backed even when the underlying model changes later.
    static func live(
        _ item: MenuItem,
        defaults: UserDefaults = .standard
    ) -> MenuItemActionContext {
        MenuItemActionContext(
            originalName: item.originalName,
            translatedName: item.translatedName,
            detectedLanguage: item.session?.detectedLanguage ?? "",
            targetLanguage: item.session?.targetLanguage
                ?? SettingsKeys.nonEmptyString(
                    SettingsKeys.targetLanguage,
                    from: defaults,
                    default: "繁體中文"
                ),
            lowConfidence: item.lowConfidence,
            providerMode: item.session?.providerMode
        )
    }
}
