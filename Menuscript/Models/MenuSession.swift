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
    @Attribute(.externalStorage) var photos: [Data]
    var peopleCount: Int
    var surchargePercent: Double

    @Relationship(deleteRule: .cascade, inverse: \MenuItem.session)
    var items: [MenuItem]

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
        photos: [Data] = [],
        peopleCount: Int = 2,
        surchargePercent: Double = 0,
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
        self.photos = photos
        self.peopleCount = peopleCount
        self.surchargePercent = surchargePercent
        self.items = items
    }
}
