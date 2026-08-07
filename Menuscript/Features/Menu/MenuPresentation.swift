// Converts editable menu/session data and frozen bill snapshots into small,
// read-only values that SwiftUI can render without mixing data sources.

import Foundation

/// Summarizes selected dishes for the cart bar, including whether any selected
/// dish lacks a price and therefore cannot contribute to the subtotal.
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

    /// Builds editable menu values from the current session and calculates the
    /// optional converted subtotal using the session's effective FX rate.
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

    /// Recreates a completed order only from its immutable bill snapshot so
    /// later edits or migration gaps cannot rewrite historical totals.
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

/// Represents either safe menu content or the reason completed history cannot
/// be displayed, forcing callers to handle corrupt/missing snapshots explicitly.
enum MenuPresentationState: Equatable, Sendable {
    case content(MenuOrderPresentation)
    case unavailable(SessionBillUnavailableReason)

    /// Selects live or snapshot-backed presentation based on the session's
    /// bill state and preserves unavailable history as an explicit state.
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

    /// Returns renderable order values when available, otherwise nil for callers
    /// that only need a convenient optional rather than a full state switch.
    var orderPresentation: MenuOrderPresentation? {
        guard case .content(let presentation) = self else { return nil }
        return presentation
    }
}

/// The price, names, and quantity shown by one card, separated from its mutable
/// model so completed orders can display frozen snapshot values safely.
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

    /// Reflects the current mutable item for an active order.
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

    /// Uses the matching frozen line for a completed order; an unmatched item
    /// remains descriptive menu content and is clearly marked as not ordered.
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

    /// Prefers the original dish name for image search and falls back to the
    /// translation when recognition produced no usable original text.
    var photoSearchQuery: String {
        let trimmed = originalName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? translatedName : trimmed
    }

    /// Captures action inputs from the same presentation shown on screen and
    /// uses the provider mode saved in the snapshot when one exists.
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
