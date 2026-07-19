import ImageIO
import UIKit

/// Downscales menu photos before they are sent to the vision API, to keep
/// upload size and token usage down.
enum ImagePrep {
    /// Immutable result passed from background preparation back to the
    /// MainActor capture state. `UIImage` itself has no Sendable annotation,
    /// but this value is never mutated after construction.
    struct PreparedPhoto: @unchecked Sendable {
        let preview: UIImage
        let jpegData: Data
    }

    /// Comfortably above `jpegData`'s default 1600pt long-edge target, so
    /// decoding a picked/captured photo at this size never becomes the
    /// recognition-quality bottleneck.
    static let captureMaxPixelSize: CGFloat = 2560

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

    /// Produces the exact JPEG that recognition and persistence will use,
    /// together with a preview decoded from that JPEG. Preparing once, before
    /// recognition, removes the old `compactMap` path that could silently drop
    /// one failed page from a multi-page menu.
    static func preparedPhoto(from image: UIImage) -> PreparedPhoto? {
        preparedPhoto(from: image) { candidate in
            jpegData(from: candidate)
        }
    }

    /// Injection seam used by deterministic failure tests.
    static func preparedPhoto(
        from image: UIImage,
        jpegEncoder: (UIImage) -> Data?
    ) -> PreparedPhoto? {
        guard let data = jpegEncoder(image),
              !data.isEmpty,
              let preview = UIImage(data: data) else {
            return nil
        }
        return PreparedPhoto(preview: preview, jpegData: data)
    }

    /// Library-import path: bounded decode followed by the same one-time JPEG
    /// preparation used for camera/direct UIImage inputs.
    static func preparedPhoto(from data: Data) -> PreparedPhoto? {
        guard let image = downsampledImage(from: data, maxPixelSize: captureMaxPixelSize) else {
            return nil
        }
        return preparedPhoto(from: image)
    }

    /// Decodes `data` straight into a bitmap bounded by `maxPixelSize`, via
    /// ImageIO's thumbnail generator, so a 48MP/panorama original is never
    /// fully decoded in memory just to be shown in a grid or re-encoded.
    static func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Caps an already-decoded image's long edge with a renderer resize
    /// (no re-encode round trip) — for camera captures, which arrive as a
    /// `UIImage` rather than `Data`.
    static func resized(_ image: UIImage, maxLongEdge: CGFloat) -> UIImage {
        let size = image.size
        let longEdge = max(size.width, size.height)
        guard longEdge > maxLongEdge else { return image }

        let scale = maxLongEdge / longEdge
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
