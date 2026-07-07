import Testing
import UIKit
@testable import MenuTranslate

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

    @Test("Small image is left un-upscaled")
    func doesNotUpscaleSmallImage() throws {
        let image = Self.solidImage(size: CGSize(width: 800, height: 600))

        let data = try #require(ImagePrep.jpegData(from: image))
        #expect(!data.isEmpty)

        let decoded = try #require(UIImage(data: data))
        #expect(decoded.size.width == 800)
        #expect(decoded.size.height == 600)
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
