import Foundation

/// Immutable, versioned copy of the order and every value used to present the
/// final bill. Completed sessions render this value instead of recomputing from
/// mutable `MenuItem` / `MenuSession` fields.
struct BillSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    struct Line: Codable, Equatable, Sendable {
        let originalName: String
        let translatedName: String
        let unitPrice: Decimal?
        let priceNote: String?
        let quantity: Int
        let sortOrder: Int

        var lineTotal: Decimal? {
            unitPrice.map { $0 * Decimal(quantity) }
        }
    }

    let version: Int
    let lines: [Line]
    let menuCurrency: String
    let homeCurrency: String
    let fxRate: Double?
    let fxRateDate: Date?
    let fxSource: String?
    let fxQuoteDate: String?
    let fxFetchedAt: Date?
    let providerModeRaw: String?
    let subtotal: Decimal
    let surchargePercent: Double
    let surchargeAmount: Decimal
    let total: Decimal
    let peopleCount: Int
    let perPersonOriginal: Decimal
    let convertedSubtotal: Decimal?
    let convertedSurchargeAmount: Decimal?
    let convertedTotal: Decimal?
    let perPersonConverted: Decimal?
    let hasUnpricedItems: Bool
    let completedAt: Date

    static func capture(from session: MenuSession, completedAt: Date) throws -> BillSnapshot {
        let lines = session.items
            .filter { $0.quantity > 0 }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map {
                Line(
                    originalName: $0.originalName,
                    translatedName: $0.translatedName,
                    unitPrice: $0.priceValue,
                    priceNote: $0.priceNote,
                    quantity: $0.quantity,
                    sortOrder: $0.sortOrder
                )
            }
        guard !lines.isEmpty else {
            throw BillSnapshotError.emptyOrder
        }

        let subtotal = lines.reduce(Decimal.zero) { runningTotal, line in
            runningTotal + (line.lineTotal ?? .zero)
        }
        let total = BillMath.total(subtotal: subtotal, surchargePercent: session.surchargePercent)
        let surchargeAmount = total - subtotal
        let peopleCount = max(session.peopleCount, 1)
        let perPersonOriginal = BillMath.perPerson(
            total: total,
            people: peopleCount,
            fractionDigits: BillMath.fractionDigits(forCurrency: session.menuCurrency)
        )

        let fxRate = session.effectiveFXRate
        let convertedSubtotal = fxRate.map { BillMath.converted(subtotal, rate: $0) }
        let convertedSurchargeAmount = fxRate.map { BillMath.converted(surchargeAmount, rate: $0) }
        let convertedTotal = fxRate.map { BillMath.converted(total, rate: $0) }
        let perPersonConverted = convertedTotal.map {
            BillMath.perPerson(
                total: $0,
                people: peopleCount,
                fractionDigits: BillMath.fractionDigits(forCurrency: session.homeCurrency)
            )
        }

        return BillSnapshot(
            version: currentVersion,
            lines: lines,
            menuCurrency: session.menuCurrency,
            homeCurrency: session.homeCurrency,
            fxRate: fxRate,
            fxRateDate: session.fxRateDate,
            fxSource: session.fxSource,
            fxQuoteDate: session.fxQuoteDate,
            fxFetchedAt: session.fxFetchedAt,
            providerModeRaw: session.providerModeRaw,
            subtotal: subtotal,
            surchargePercent: session.surchargePercent,
            surchargeAmount: surchargeAmount,
            total: total,
            peopleCount: peopleCount,
            perPersonOriginal: perPersonOriginal,
            convertedSubtotal: convertedSubtotal,
            convertedSurchargeAmount: convertedSurchargeAmount,
            convertedTotal: convertedTotal,
            perPersonConverted: perPersonConverted,
            hasUnpricedItems: lines.contains { $0.unitPrice == nil },
            completedAt: completedAt
        )
    }
}

enum BillSnapshotError: Error, LocalizedError, Equatable {
    case emptyOrder
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .emptyOrder:
            return L10n.string("請先揀至少一款菜式先完成帳單。")
        case .unsupportedVersion(let version):
            return L10n.string("帳單記錄版本（%lld）未能讀取。", version)
        }
    }
}

enum BillSnapshotCodec {
    private struct VersionEnvelope: Decodable {
        let version: Int
    }

    static func encode(_ snapshot: BillSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    static func decode(_ data: Data) throws -> BillSnapshot {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(VersionEnvelope.self, from: data)
        guard envelope.version == BillSnapshot.currentVersion else {
            throw BillSnapshotError.unsupportedVersion(envelope.version)
        }
        return try decoder.decode(BillSnapshot.self, from: data)
    }
}
