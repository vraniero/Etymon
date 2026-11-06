import CoreImage
import UIKit

/// The picture a scene was read from (the last carefully read video frame, or the photo)
/// and where each word was in it, so a saved scene shows the network over its picture.
/// Rendering waits until the scene is saved: reads happen every second, saves rarely.
struct ScenePicture {
    enum Source {
        case buffer(CVPixelBuffer, CGImagePropertyOrientation)  // a copy, not the camera's own
        case image(CGImage, CGImagePropertyOrientation)
    }

    let source: Source
    /// Word boxes as read in this picture (normalized, upright, top-left origin).
    let boxes: [String: CGRect]
    /// Upright size.
    let size: CGSize

    private static let context = CIContext()

    /// The upright picture, its longer side at most `maxSide` points.
    func render(maxSide: CGFloat) -> UIImage? {
        var image: CIImage
        switch source {
        case .buffer(let buffer, let orientation):
            image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
        case .image(let cg, let orientation):
            image = CIImage(cgImage: cg).oriented(orientation)
        }
        let scale = min(1, maxSide / max(image.extent.width, image.extent.height))
        if scale < 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cg = Self.context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
