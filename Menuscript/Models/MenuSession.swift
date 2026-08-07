// Defines a saved menu session and turns fields kept compatible with older app
// versions into clear lifecycle, provider, photo, and completed-bill states.

import Foundation
import SwiftData

/// Describes whether a session is editable, finalized, or from an older data format.
enum SessionLifecycleStatus: Equatable, Sendable {
    case draft
    case completed
    case legacyUnfinalized
}

/// Explains why a completed session's permanent bill cannot be displayed safely.
enum SessionBillUnavailableReason: Equatable, Sendable {
    case missing
    case unreadable
    case unsupportedVersion(Int)
}

/// A safe bill state for screens to display. If a completed receipt cannot be
/// read, the app reports why instead of rebuilding it from later editable values.
enum SessionBillState: Equatable, Sendable {
    case draft
    case completed(BillSnapshot)
    case unavailable(SessionBillUnavailableReason)
}

/// A saved menu-recognition visit, including photos, dishes, currency context,
/// order choices, and the immutable bill created when the visit is completed.
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
    /// The exchange market's official date in ISO format. It stays optional so
    /// older saved sessions still open; `fxRateDate` is only a legacy fallback.
    var fxQuoteDate: String?
    /// The exact time the quote was obtained, used to show its origin and age.
    var fxFetchedAt: Date?
    /// Saves whether recognition used the mock or live provider; `nil` means an older session.
    var providerModeRaw: String?
    @Attribute(.externalStorage) var photos: [Data]
    var peopleCount: Int
    var surchargePercent: Double
    var allergenProfile: [String] = []
    /// Stores `"draft"` or `"completed"`. Missing or unknown values from older
    /// versions remain unfinished so they are never mistaken for finalized bills.
    var lifecycleStatusRaw: String?
    /// Stores the permanent completed bill as encoded data. It is optional so
    /// older sessions still open, and only finalization should write it.
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

    /// Converts the migration-friendly stored string into the runtime provider mode.
    /// Unknown or legacy values remain `nil` instead of being guessed.
    var providerMode: RuntimeMode? {
        guard let providerModeRaw else { return nil }
        return RuntimeMode(rawValue: providerModeRaw)
    }

    /// Interprets the optional stored lifecycle value. Missing or unknown values
    /// are treated as legacy and never accidentally marked as completed.
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

    /// Provides the simple completion check used to split history and lock final bills.
    var isCompleted: Bool {
        lifecycleStatus == .completed
    }

    /// Returns the decoded permanent bill only when it is both finalized and readable.
    var billSnapshot: BillSnapshot? {
        guard case .completed(let snapshot) = billState else { return nil }
        return snapshot
    }

    /// Safely classifies the bill for presentation, distinguishing a draft from
    /// missing, corrupt, or newer-version snapshot data.
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

    /// Reports whether at least one original menu photo is available.
    var hasPhotos: Bool {
        !photos.isEmpty
    }

    /// Creates a draft by default while allowing tests and older-data handling
    /// to supply every saved value explicitly when needed.
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
