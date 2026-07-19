import Foundation

struct BillDisplayLine: Identifiable, Equatable, Sendable {
    let originalName: String
    let translatedName: String
    let unitPrice: Decimal?
    let priceNote: String?
    let quantity: Int
    let sortOrder: Int

    var id: String {
        "\(sortOrder)|\(originalName)|\(translatedName)"
    }

    init(_ item: MenuItem) {
        originalName = item.originalName
        translatedName = item.translatedName
        unitPrice = item.priceValue
        priceNote = item.priceNote
        quantity = item.quantity
        sortOrder = item.sortOrder
    }

    init(_ line: BillSnapshot.Line) {
        originalName = line.originalName
        translatedName = line.translatedName
        unitPrice = line.unitPrice
        priceNote = line.priceNote
        quantity = line.quantity
        sortOrder = line.sortOrder
    }
}

/// Pure bill values used by the UI. Completed models are built exclusively
/// from a snapshot, including optional nils, so no field can fall through to a
/// later mutable `MenuSession` value.
struct BillDisplayModel: Equatable, Sendable {
    let isReadOnly: Bool
    let lines: [BillDisplayLine]
    let menuCurrency: String
    let homeCurrency: String
    let fxRate: Double?
    let fxRateDate: Date?
    let fxQuoteDate: String?
    let fxSource: String?
    let subtotal: Decimal
    let surchargePercent: Double
    let surchargeAmount: Decimal
    let total: Decimal
    let peopleCount: Int
    let perPersonOriginal: Decimal
    let convertedTotal: Decimal?
    let perPersonConverted: Decimal?
    let hasUnpricedLines: Bool

    static func draft(_ session: MenuSession) -> BillDisplayModel {
        let lines = session.items
            .filter { $0.quantity > 0 }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(BillDisplayLine.init)
        let subtotal = BillMath.subtotal(lines: lines.compactMap { line in
            guard let price = line.unitPrice else { return nil }
            return (price: price, qty: line.quantity)
        })
        let total = BillMath.total(
            subtotal: subtotal,
            surchargePercent: session.surchargePercent
        )
        let fxRate = session.effectiveFXRate
        let convertedTotal = fxRate.map { BillMath.converted(total, rate: $0) }
        let perPersonOriginal = BillMath.perPerson(
            total: total,
            people: session.peopleCount,
            fractionDigits: BillMath.fractionDigits(forCurrency: session.menuCurrency)
        )
        let perPersonConverted = convertedTotal.map {
            BillMath.perPerson(
                total: $0,
                people: session.peopleCount,
                fractionDigits: BillMath.fractionDigits(forCurrency: session.homeCurrency)
            )
        }

        return BillDisplayModel(
            isReadOnly: false,
            lines: lines,
            menuCurrency: session.menuCurrency,
            homeCurrency: session.homeCurrency,
            fxRate: fxRate,
            fxRateDate: session.fxRateDate,
            fxQuoteDate: session.fxQuoteDate,
            fxSource: session.fxSource,
            subtotal: subtotal,
            surchargePercent: session.surchargePercent,
            surchargeAmount: total - subtotal,
            total: total,
            peopleCount: session.peopleCount,
            perPersonOriginal: perPersonOriginal,
            convertedTotal: convertedTotal,
            perPersonConverted: perPersonConverted,
            hasUnpricedLines: lines.contains { $0.unitPrice == nil }
        )
    }

    static func completed(_ snapshot: BillSnapshot) -> BillDisplayModel {
        BillDisplayModel(
            isReadOnly: true,
            lines: snapshot.lines.map(BillDisplayLine.init),
            menuCurrency: snapshot.menuCurrency,
            homeCurrency: snapshot.homeCurrency,
            fxRate: snapshot.fxRate,
            fxRateDate: snapshot.fxRateDate,
            fxQuoteDate: snapshot.fxQuoteDate,
            fxSource: snapshot.fxSource,
            subtotal: snapshot.subtotal,
            surchargePercent: snapshot.surchargePercent,
            surchargeAmount: snapshot.surchargeAmount,
            total: snapshot.total,
            peopleCount: snapshot.peopleCount,
            perPersonOriginal: snapshot.perPersonOriginal,
            convertedTotal: snapshot.convertedTotal,
            perPersonConverted: snapshot.perPersonConverted,
            hasUnpricedLines: snapshot.hasUnpricedItems
        )
    }
}

enum BillPresentationState: Equatable, Sendable {
    case content(BillDisplayModel)
    case unavailable(SessionBillUnavailableReason)

    static func resolve(for session: MenuSession) -> BillPresentationState {
        switch session.billState {
        case .draft:
            return .content(.draft(session))
        case .completed(let snapshot):
            return .content(.completed(snapshot))
        case .unavailable(let reason):
            return .unavailable(reason)
        }
    }

    var displayModel: BillDisplayModel? {
        guard case .content(let model) = self else { return nil }
        return model
    }
}

extension SessionBillUnavailableReason {
    var localizedMessage: String {
        switch self {
        case .missing:
            return L10n.string("已完成帳單缺少可讀取嘅快照，記錄未有再被修改。")
        case .unreadable:
            return L10n.string("已完成帳單資料已損壞，因此未有顯示任何帳單內容。")
        case .unsupportedVersion(let version):
            return L10n.string("帳單記錄版本（%lld）未能讀取。", version)
        }
    }
}
