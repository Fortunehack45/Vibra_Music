import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// The pictures a widget draws, baked once per track (ports widget/MediaWidgetArt.kt).
///
/// A widget can't blur at run time: WidgetKit renders the view once into an archived snapshot, and
/// materials there don't sample what is under them. So, as on Android, the soft foot the transport
/// sits on and the 4×1's body are drawn here on the CPU, from the cover the app copied into the App
/// Group, and handed to the views as plain images.
struct WidgetArt {
    /// The cover, downscaled to what a widget can show.
    var cover: UIImage
    /// The cover blurred for the band at the foot of the 2×2 / 4×2 (masked in by the view so the
    /// blur ramps in over a region taller than the band, rather than starting at a hard edge).
    var softened: UIImage
    /// The cover blurred to colour and darkened: the 4×1's body.
    var body: UIImage

    /// Longest side kept. The widget archive holds these images for as long as it is on screen, and
    /// a medium widget is at most ~364 pt wide at 3×.
    static let maxPixels: CGFloat = 720

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Loads and bakes the art for a snapshot; nil without a saved cover (the view draws the
    /// placeholder gradient then).
    static func load(for snapshot: NowPlayingSnapshot?) -> WidgetArt? {
        guard let url = snapshot?.artworkFileURL, let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            return nil
        }
        return make(from: image)
    }

    static func make(from image: UIImage) -> WidgetArt? {
        guard let cover = downscaled(image), let input = CIImage(image: cover) else { return nil }
        let extent = input.extent
        // Radii relative to the picture, so a small cover and a large one blur alike.
        let side = max(extent.width, extent.height)
        guard let softened = blurred(input, radius: side * 0.035, darken: 0),
              let body = blurred(input, radius: side * 0.12, darken: 0.18) else { return nil }
        return WidgetArt(cover: cover, softened: softened, body: body)
    }

    private static func downscaled(_ image: UIImage) -> UIImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxPixels / max(size.width * image.scale, size.height * image.scale))
        let target = CGSize(width: (size.width * image.scale * scale).rounded(), height: (size.height * image.scale * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// A Gaussian blur that doesn't darken at the edges: the input is clamped to extent first, so
    /// the blur samples the border's own colour past the edge instead of transparent black
    /// (the "nothing to sample past the edge" problem MediaWidgetArt describes).
    private static func blurred(_ input: CIImage, radius: CGFloat, darken: CGFloat) -> UIImage? {
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input.clampedToExtent()
        blur.radius = Float(radius)
        guard var output = blur.outputImage?.cropped(to: input.extent) else { return nil }
        if darken > 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = output
            exposure.ev = Float(-darken * 3)
            output = exposure.outputImage ?? output
        }
        guard let cg = context.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
