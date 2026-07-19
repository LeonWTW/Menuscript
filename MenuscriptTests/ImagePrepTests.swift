import Testing
import UIKit
@testable import Menuscript

@Suite
struct ImagePrepTests {
    @Test("Large image is downscaled to the max long edge, aspect preserved")
    func downscalesLargeImage() throws {
        let image = Self.solidImage(size: CGSize(width: 4000, height: 3000))

        let data = try #require(ImagePrep.jpegData(from: image))
        #expect(!data.isEmpty)

        let decoded = try #require(UIImage(data: data))
        let longEdge = max(decoded.size.width, decoded.size.height)
        #expect(longEdge <= 1600)

        let originalRatio = 4000.0 / 3000.0
        let decodedRatio = decoded.size.width / decoded.size.height
        #expect(abs(decodedRatio - originalRatio) < 0.01)
    }

    @Test("Large picked-photo data downsamples through the pixel cap, aspect preserved")
    func downsamplesThroughPixelCap() throws {
        let image = Self.solidImage(size: CGSize(width: 5000, height: 4000))
        let data = try #require(image.jpegData(compressionQuality: 0.9))

        let maxPixelSize = ImagePrep.captureMaxPixelSize
        let decoded = try #require(ImagePrep.downsampledImage(from: data, maxPixelSize: maxPixelSize))

        let longEdge = max(decoded.size.width, decoded.size.height)
        #expect(longEdge <= maxPixelSize)

        let originalRatio = 5000.0 / 4000.0
        let decodedRatio = decoded.size.width / decoded.size.height
        #expect(abs(decodedRatio - originalRatio) < 0.01)
    }

    @Test("Small image is left un-upscaled")
    func doesNotUpscaleSmallImage() throws {
        let image = Self.solidImage(size: CGSize(width: 800, height: 600))

        let data = try #require(ImagePrep.jpegData(from: image))
        #expect(!data.isEmpty)

        let decoded = try #require(UIImage(data: data))
        #expect(decoded.size.width == 800)
        #expect(decoded.size.height == 600)
    }

    @Test("Prepared photo keeps one exact JPEG for preview, upload, and persistence")
    func preparedPhotoUsesExactJPEG() throws {
        let image = Self.solidImage(size: CGSize(width: 2200, height: 1600))

        let prepared = try #require(ImagePrep.preparedPhoto(from: image))

        #expect(!prepared.jpegData.isEmpty)
        let decoded = try #require(UIImage(data: prepared.jpegData))
        #expect(prepared.preview.size == decoded.size)
        #expect(max(decoded.size.width, decoded.size.height) <= 1600)
    }

    @Test("JPEG encoder failure returns nil instead of a partial prepared photo")
    func preparedPhotoFailsAtomicallyWhenEncoderFails() {
        let image = Self.solidImage(size: CGSize(width: 100, height: 100))

        let prepared = ImagePrep.preparedPhoto(from: image) { _ in nil }

        #expect(prepared == nil)
    }

    @Test("Invalid source data cannot create a prepared photo")
    func invalidSourceDataFailsPreparation() {
        #expect(ImagePrep.preparedPhoto(from: Data([0x00, 0x01, 0x02])) == nil)
    }

    private static func solidImage(size: CGSize, color: UIColor = .systemRed) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
