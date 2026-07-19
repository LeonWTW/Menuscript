import Foundation
import Testing
import UIKit
@testable import Menuscript

@MainActor
@Suite("History photo gallery model")
struct HistoryPhotoGalleryModelTests {
    private func validPNGData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            UIColor.systemOrange.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return try #require(image.pngData())
    }

    @Test("Zero photos has no pages and no decodable image")
    func zeroPhotos() {
        let model = HistoryPhotoGalleryModel(photos: [])
        #expect(model.isEmpty)
        #expect(model.pageCount == 0)
        #expect(model.data(at: 0) == nil)
        #expect(model.image(at: 0) == nil)
    }

    @Test("One photo decodes lazily at its only valid index")
    func onePhoto() throws {
        let photo = try validPNGData()
        let model = HistoryPhotoGalleryModel(photos: [photo])
        #expect(model.isEmpty == false)
        #expect(model.pageCount == 1)
        #expect(model.data(at: 0) == photo)
        #expect(model.image(at: 0) != nil)
        #expect(model.data(at: 1) == nil)
    }

    @Test("Six pages preserve capture order")
    func sixPhotosPreserveOrder() {
        let photos = (0..<6).map { Data([$0]) }
        let model = HistoryPhotoGalleryModel(photos: photos)

        #expect(model.pageCount == 6)
        #expect((0..<6).compactMap { model.data(at: $0) } == photos)
        #expect(model.data(at: -1) == nil)
        #expect(model.data(at: 6) == nil)
    }

    @Test("Corrupt bytes keep their page but produce a placeholder signal")
    func corruptPhoto() {
        let corrupt = Data("not an image".utf8)
        let model = HistoryPhotoGalleryModel(photos: [corrupt])

        #expect(model.pageCount == 1)
        #expect(model.data(at: 0) == corrupt)
        #expect(model.image(at: 0) == nil)
    }
}
