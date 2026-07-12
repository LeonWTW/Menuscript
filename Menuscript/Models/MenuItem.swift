import Foundation
import SwiftData

@Model
final class MenuItem {
    var originalName: String
    var translatedName: String
    var priceValue: Decimal?
    var priceNote: String?
    var category: String
    var lowConfidence: Bool
    var explanation: String?
    var quantity: Int
    var sortOrder: Int
    var session: MenuSession?

    init(
        originalName: String,
        translatedName: String,
        priceValue: Decimal? = nil,
        priceNote: String? = nil,
        category: String,
        lowConfidence: Bool = false,
        explanation: String? = nil,
        quantity: Int = 0,
        sortOrder: Int,
        session: MenuSession? = nil
    ) {
        self.originalName = originalName
        self.translatedName = translatedName
        self.priceValue = priceValue
        self.priceNote = priceNote
        self.category = category
        self.lowConfidence = lowConfidence
        self.explanation = explanation
        self.quantity = quantity
        self.sortOrder = sortOrder
        self.session = session
    }
}
