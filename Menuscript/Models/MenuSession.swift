import Foundation
import SwiftData

enum SessionLifecycleStatus: Equatable, Sendable {
    case draft
    case completed
    case legacyUnfinalized
}

enum SessionBillUnavailableReason: Equatable, Sendable {
    case missing
    case unreadable
    case unsupportedVersion(Int)
}

/// Presentation-safe bill state. A completed session never falls back to its
/// mutable live fields when its immutable snapshot cannot be decoded.
enum SessionBillState: Equatable, Sendable {
    case draft
    case completed(BillSnapshot)
    case unavailable(SessionBillUnavailableReason)
}

@Model
final class MenuSession {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var title: String?
    var detectedLanguage: String
    var targetLanguage: String
    var menuCurrency: String
    var homeCurrency: String
    var fxRate: Double?
    var fxRateDate: Date?
    var fxSource: String?
    /// Canonical ISO market date. Optional keeps existing stores lightweight-
    /// migration compatible; fxRateDate remains a legacy fallback only.
    var fxQuoteDate: String?
    /// Wall-clock time when the quote was obtained, used for provenance/TTL.
    var fxFetchedAt: Date?
    /// Runtime provider provenance: "mock" or "live". Nil means legacy.
    var providerModeRaw: String?
    @Attribute(.externalStorage) var photos: [Data]
    var peopleCount: Int
    var surchargePercent: Double
    var allergenProfile: [String] = []
    /// Optional for additive SwiftData migration. New sessions persist
    /// `"draft"`; a migrated row with nil/unknown state is deliberately treated
    /// as legacy-unfinalized rather than being mistaken for a completed order.
    var lifecycleStatusRaw: String?
    /// Codable `BillSnapshot` bytes. Optional keeps old stores lightweight-
    /// migration compatible; only `SessionStore.finalize` writes this field.
    var billSnapshotData: Data?

    @Relationship(deleteRule: .cascade, inverse: \MenuItem.session)
    var items: [MenuItem]

    /// `fxRate` filtered for same-currency sessions, where any stored value —
    /// including legacy rows that persisted 1.0 before this field existed —
    /// is meaningless to show as a conversion.
    var effectiveFXRate: Double? {
        let normalizedMenu = menuCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedHome = homeCurrency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalizedMenu != normalizedHome else { return nil }
        return fxRate
    }

    var providerMode: RuntimeMode? {
        guard let providerModeRaw else { return nil }
        return RuntimeMode(rawValue: providerModeRaw)
    }

    var lifecycleStatus: SessionLifecycleStatus {
        switch lifecycleStatusRaw {
        case "draft":
            return .draft
        case "completed":
            return .completed
        default:
            return .legacyUnfinalized
        }
    }

    var isCompleted: Bool {
        lifecycleStatus == .completed
    }

    var billSnapshot: BillSnapshot? {
        guard case .completed(let snapshot) = billState else { return nil }
        return snapshot
    }

    var billState: SessionBillState {
        guard lifecycleStatus == .completed else {
            return .draft
        }
        guard let billSnapshotData else {
            return .unavailable(.missing)
        }
        do {
            return .completed(try BillSnapshotCodec.decode(billSnapshotData))
        } catch BillSnapshotError.unsupportedVersion(let version) {
            return .unavailable(.unsupportedVersion(version))
        } catch {
            return .unavailable(.unreadable)
        }
    }

    var hasPhotos: Bool {
        !photos.isEmpty
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        title: String? = nil,
        detectedLanguage: String,
        targetLanguage: String,
        menuCurrency: String,
        homeCurrency: String,
        fxRate: Double? = nil,
        fxRateDate: Date? = nil,
        fxSource: String? = nil,
        fxQuoteDate: String? = nil,
        fxFetchedAt: Date? = nil,
        providerModeRaw: String? = nil,
        photos: [Data] = [],
        peopleCount: Int = 2,
        surchargePercent: Double = 0,
        allergenProfile: [String] = [],
        lifecycleStatusRaw: String? = "draft",
        billSnapshotData: Data? = nil,
        items: [MenuItem] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.detectedLanguage = detectedLanguage
        self.targetLanguage = targetLanguage
        self.menuCurrency = menuCurrency
        self.homeCurrency = homeCurrency
        self.fxRate = fxRate
        self.fxRateDate = fxRateDate
        self.fxSource = fxSource
        self.fxQuoteDate = fxQuoteDate
        self.fxFetchedAt = fxFetchedAt
        self.providerModeRaw = providerModeRaw
        self.photos = photos
        self.peopleCount = peopleCount
        self.surchargePercent = surchargePercent
        self.allergenProfile = allergenProfile
        self.lifecycleStatusRaw = lifecycleStatusRaw
        self.billSnapshotData = billSnapshotData
        self.items = items
    }
}
