// Verifies that saved menu photos are exposed to the history gallery safely and in capture order.
// The model is tested separately from SwiftUI so corrupt image data cannot crash the screen.

import Foundation
import Testing
import UIKit
@testable import Menuscript

@MainActor
@Suite("History photo gallery model")
/// Covers empty, valid, ordered, and corrupt-photo states shown by the history gallery.
struct HistoryPhotoGalleryModelTests {
    /// Creates a tiny valid image in memory so tests do not depend on bundled or external files.
    private func validPNGData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            UIColor.systemOrange.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return try #require(image.pngData())
    }

    @Test("Zero photos has no pages and no decodable image")
    /// Confirms an empty session produces no gallery page and handles index requests safely.
    func zeroPhotos() {
        let model = HistoryPhotoGalleryModel(photos: [])
        #expect(model.isEmpty)
        #expect(model.pageCount == 0)
        #expect(model.data(at: 0) == nil)
        #expect(model.image(at: 0) == nil)
    }

    @Test("One photo decodes lazily at its only valid index")
    /// Confirms one valid photo is available at index zero and nowhere else.
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
    /// Confirms multiple photos stay in the same order in which the user captured them.
    func sixPhotosPreserveOrder() {
        let photos = (0..<6).map { Data([$0]) }
        let model = HistoryPhotoGalleryModel(photos: photos)

        #expect(model.pageCount == 6)
        #expect((0..<6).compactMap { model.data(at: $0) } == photos)
        #expect(model.data(at: -1) == nil)
        #expect(model.data(at: 6) == nil)
    }

    @Test("Corrupt bytes keep their page but produce a placeholder signal")
    /// Confirms unreadable data remains represented as a page while image decoding fails safely.
    func corruptPhoto() {
        let corrupt = Data("not an image".utf8)
        let model = HistoryPhotoGalleryModel(photos: [corrupt])

        #expect(model.pageCount == 1)
        #expect(model.data(at: 0) == corrupt)
        #expect(model.image(at: 0) == nil)
    }
}
