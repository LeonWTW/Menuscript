import Foundation
import SwiftData

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
    @Attribute(.externalStorage) var photos: [Data]
    var peopleCount: Int
    var surchargePercent: Double
    var allergenProfile: [String] = []

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
        photos: [Data] = [],
        peopleCount: Int = 2,
        surchargePercent: Double = 0,
        allergenProfile: [String] = [],
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
        self.photos = photos
        self.peopleCount = peopleCount
        self.surchargePercent = surchargePercent
        self.allergenProfile = allergenProfile
        self.items = items
    }
}
