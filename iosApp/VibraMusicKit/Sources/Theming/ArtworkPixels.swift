import CoreGraphics
import Foundation
import ImageIO

/// A decoded image as the Android colour code reads one: `width × height`
/// packed `0xAARRGGBB` values, sRGB, straight alpha, rows top to bottom —
/// exactly what `Bitmap.getPixels` hands back.
///
/// Everything in this module that looks at artwork (the swatch quantiser, the
/// page tint's edge and top-band reads, the mesh backdrop, the full-cover blur)
/// works off one of these, so the platform image types stay at the edge:
/// ``init(image:fittingLongestSide:)`` for a `CGImage` (a canvas frame, an
/// embedded cover), ``init(imageData:fittingLongestSide:)`` for bytes off the
/// network or disk.
public struct ArtworkPixels: Hashable, Sendable {
    public let width: Int
    public let height: Int
    /// Row-major, `width * height` entries.
    public let argb: [UInt32]

    public init(width: Int, height: Int, argb: [UInt32]) {
        precondition(width >= 0 && height >= 0, "negative size")
        precondition(argb.count == width * height, "pixel count \(argb.count) != \(width)x\(height)")
        self.width = width
        self.height = height
        self.argb = argb
    }

    /// Reads `image` into sRGB, colour-matching whatever space it was encoded in
    /// (a Display P3 cover comes out as the sRGB values Android's decoder would
    /// have produced).
    ///
    /// - Parameter side: When set, the image is scaled — up or down — so its
    ///   longer side is exactly `side` pixels, keeping the aspect ratio. That is
    ///   what Coil's `ImageRequest.size(side)` does with its default exact
    ///   precision, and the Android code relies on the result's size: the mesh
    ///   backdrop decodes at 120 so every one of its 6×6 cells is the same whole
    ///   number of source pixels. Nil reads the image at its own size.
    public init?(image: CGImage, fittingLongestSide side: Int? = nil) {
        var width = image.width
        var height = image.height
        guard width > 0, height > 0 else { return nil }
        if let side, side > 0 {
            let scale = Double(side) / Double(max(width, height))
            width = max(1, Int((Double(width) * scale).rounded()))
            height = max(1, Int((Double(height) * scale).rounded()))
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        // Premultiplied BGRA in memory, which on a little-endian machine reads
        // back as `0xAARRGGBB` words — Core Graphics can't draw into straight
        // alpha, so it is undone below.
        var buffer = [UInt32](repeating: 0, count: width * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        for index in buffer.indices {
            let pixel = buffer[index]
            let alpha = pixel >> 24
            if alpha == 0xFF { continue }
            if alpha == 0 {
                buffer[index] = 0
                continue
            }
            func straight(_ channel: UInt32) -> UInt32 {
                min(255, (channel * 255 + alpha / 2) / alpha)
            }
            buffer[index] = (alpha << 24)
                | (straight((pixel >> 16) & 0xFF) << 16)
                | (straight((pixel >> 8) & 0xFF) << 8)
                | straight(pixel & 0xFF)
        }
        self.init(width: width, height: height, argb: buffer)
    }

    /// Decodes encoded image bytes (JPEG, PNG, WebP, HEIC — whatever ImageIO
    /// reads) straight to a thumbnail whose longer side is `side`, without ever
    /// holding the full-size bitmap. EXIF orientation is applied.
    public init?(imageData: Data, fittingLongestSide side: Int) {
        guard side > 0,
              let source = CGImageSourceCreateWithData(imageData as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        self.init(image: image, fittingLongestSide: side)
    }

    /// The pixels as an sRGB `CGImage` (straight alpha), for drawing a mesh
    /// texture or the pre-blurred backdrop.
    public func makeCGImage() -> CGImage? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let data = argb.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    @inline(__always)
    func pixel(x: Int, y: Int) -> UInt32 {
        argb[y * width + x]
    }

    /// `Bitmap.createScaledBitmap(bitmap, width, height, filter = false)`:
    /// nearest-neighbour, each target pixel taking the source pixel under its centre.
    func scaledNearestNeighbor(width newWidth: Int, height newHeight: Int) -> ArtworkPixels {
        if newWidth == width && newHeight == height { return self }
        var out = [UInt32](repeating: 0, count: newWidth * newHeight)
        for y in 0..<newHeight {
            let sy = min(height - 1, Int((Double(y) + 0.5) * Double(height) / Double(newHeight)))
            for x in 0..<newWidth {
                let sx = min(width - 1, Int((Double(x) + 0.5) * Double(width) / Double(newWidth)))
                out[y * newWidth + x] = argb[sy * width + sx]
            }
        }
        return ArtworkPixels(width: newWidth, height: newHeight, argb: out)
    }

    // MARK: - Frame heuristics (FrameHeuristics.kt)

    /// Whether this is almost certainly the first read after the video surface
    /// was recreated — the player hasn't decoded real content yet, so the buffer
    /// is black or near-black.
    ///
    /// Mean luma below 12 on a 0–255 scale (about 4.7%) is the threshold: a
    /// genuinely dark cover frame almost always clears it, because even black
    /// sleeves carry noise and compression artefacts that lift the average.
    /// Sampled on a sparse grid, since it runs every few seconds while a clip plays.
    public var isLikelyBlackFrame: Bool {
        guard width > 0, height > 0 else { return true }
        let stride = max(1, min(width, height) / 32)
        var sumLuma = 0
        var count = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let p = pixel(x: x, y: y)
                // ITU-R BT.601 luma weights
                sumLuma += (redOf(p) * 30 + greenOf(p) * 59 + blueOf(p) * 11) / 100
                count += 1
                x += stride
            }
            y += stride
        }
        return sumLuma / count < 12
    }

    // MARK: - Full-cover blur (ArtworkMeshBackdrop.kt)

    /// Three small box passes approximate a broad Gaussian at thumbnail scale.
    ///
    /// The full-cover backdrop (lyrics, queue, tablet player) is this, computed
    /// once per cover off the main thread and then only ever drawn — a live
    /// screen-sized blur would be paid for on the very frame the player is
    /// animating in. The result is opaque; alpha is dropped as Android's is.
    public func boxBlurred(passes: Int = ArtworkBlur.passes) -> ArtworkPixels {
        if width < 2 || height < 2 { return self }
        var source = argb
        var target = [UInt32](repeating: 0, count: argb.count)
        let radius = max(min(width, height) / 12, 2)
        for _ in 0..<passes {
            Self.boxBlurPass(source: source, target: &target, width: width, height: height, radius: radius, horizontal: true)
            Self.boxBlurPass(source: target, target: &source, width: width, height: height, radius: radius, horizontal: false)
        }
        return ArtworkPixels(width: width, height: height, argb: source)
    }

    private static func boxBlurPass(
        source: [UInt32],
        target: inout [UInt32],
        width: Int,
        height: Int,
        radius: Int,
        horizontal: Bool
    ) {
        let major = horizontal ? width : height
        let minor = horizontal ? height : width
        let window = radius * 2 + 1
        for fixed in 0..<minor {
            var red = 0
            var green = 0
            var blue = 0
            func pixel(_ at: Int) -> UInt32 {
                let position = constrain(at, 0, major - 1)
                return horizontal ? source[fixed * width + position] : source[position * width + fixed]
            }
            for offset in -radius...radius {
                let color = pixel(offset)
                red += redOf(color)
                green += greenOf(color)
                blue += blueOf(color)
            }
            for moving in 0..<major {
                let index = horizontal ? fixed * width + moving : moving * width + fixed
                target[index] = opaqueARGB(red: red / window, green: green / window, blue: blue / window)
                let leaving = pixel(moving - radius)
                let entering = pixel(moving + radius + 1)
                red += redOf(entering) - redOf(leaving)
                green += greenOf(entering) - greenOf(leaving)
                blue += blueOf(entering) - blueOf(leaving)
            }
        }
    }
}

/// The full-cover blurred backdrop's constants (`FullArtworkBlurBackdrop`).
public enum ArtworkBlur {
    /// A screen cannot recover detail discarded here; small is the performance feature.
    public static let sourcePixels = 128
    public static let passes = 3
    /// A handful of recent covers; each entry is only 64 KiB at 128×128.
    static let cacheEntries = 8
    /// How long the prepared image takes to fade in over the fallback surface.
    public static let imageFadeDuration: TimeInterval = 0.32
    /// Lyrics and queue are dense white foregrounds: the cover's colour and
    /// layout are kept, but a bright sleeve mustn't lower their contrast.
    /// Black at these opacities, top to bottom.
    public static let scrimStops: [ThemeGradientStop] = [
        ThemeGradientStop(location: 0, color: ThemeColor.black.withAlpha(0.34)),
        ThemeGradientStop(location: 0.55, color: ThemeColor.black.withAlpha(0.48)),
        ThemeGradientStop(location: 1, color: ThemeColor.black.withAlpha(0.64)),
    ]
}
