// Freezes a completed bill, stores it as versioned JSON data, and safely reopens
// that permanent record without recalculating it from later menu edits.

import Foundation

/// Immutable, versioned copy of the order and every value used to present the
/// final bill. Completed sessions render this value instead of recomputing from
/// mutable `MenuItem` / `MenuSession` fields.
struct BillSnapshot: Codable, Equatable, Sendable {
    /// Identifies the data shape understood by this app version before full decoding.
    static let currentVersion = 1

    /// An immutable copy of one ordered dish included in the completed bill.
    struct Line: Codable, Equatable, Sendable {
        let originalName: String
        let translatedName: String
        let unitPrice: Decimal?
        let priceNote: String?
        let quantity: Int
        let sortOrder: Int

        /// Multiplies unit price by quantity, or stays unavailable when no price was recognized.
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

    /// Creates the permanent bill record from the session's currently selected
    /// dishes. All totals are calculated now so later menu edits cannot rewrite history.
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

/// Expected failures while creating or opening a completed-bill snapshot.
enum BillSnapshotError: Error, LocalizedError, Equatable {
    case emptyOrder
    case unsupportedVersion(Int)

    /// Gives each snapshot failure a message in the language selected inside the app.
    var errorDescription: String? {
        switch self {
        case .emptyOrder:
            return L10n.string("請先揀至少一款菜式先完成帳單。")
        case .unsupportedVersion(let version):
            return L10n.string("帳單記錄版本（%lld）未能讀取。", version)
        }
    }
}

/// Encodes snapshots for SwiftData storage and rejects versions this app cannot understand.
enum BillSnapshotCodec {
    /// Reads only the version first so an unknown data shape is not mistaken for the current one.
    private struct VersionEnvelope: Decodable {
        let version: Int
    }

    /// Serializes a snapshot as stable, sorted-key JSON for storage and repeatable tests.
    static func encode(_ snapshot: BillSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    /// Checks the stored version before decoding the complete snapshot, returning
    /// a clear compatibility error instead of presenting potentially incorrect totals.
    static func decode(_ data: Data) throws -> BillSnapshot {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(VersionEnvelope.self, from: data)
        guard envelope.version == BillSnapshot.currentVersion else {
            throw BillSnapshotError.unsupportedVersion(envelope.version)
        }
        return try decoder.decode(BillSnapshot.self, from: data)
    }
}
