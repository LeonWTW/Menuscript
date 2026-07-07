import UIKit

/// Downscales menu photos before they are sent to the vision API, to keep
/// upload size and token usage down.
enum ImagePrep {
    static func jpegData(from image: UIImage, maxLongEdge: CGFloat = 1600, quality: CGFloat = 0.7) -> Data? {
        let size = image.size
        let longEdge = max(size.width, size.height)

        guard longEdge > maxLongEdge else {
            return image.jpegData(compressionQuality: quality)
        }

        let scale = maxLongEdge / longEdge
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        return resized.jpegData(compressionQuality: quality)
    }
}
