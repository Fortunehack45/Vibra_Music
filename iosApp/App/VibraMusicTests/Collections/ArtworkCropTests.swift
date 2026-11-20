import VibraMusicCore
import SwiftUI
import XCTest
@testable import VibraMusic

/// The shared artwork box against a widescreen source (Android's ContentScale.Crop on every
/// AsyncImage: Common.kt's SongRowContent, MiniPlayer.kt, the sheets and the shelf cards). A
/// 16:9 video thumbnail must fill its fixed square box and be centre-cropped — never letterbox
/// onto the plate, and never widen the box past the frame its caller gave it.
@MainActor
final class ArtworkCropTests: XCTestCase {
    /// A 160×90 picture, solid red — a colour nothing else in the view draws.
    private func widePicture() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 90))
        return renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        }
    }

    /// The box stays exactly the size its caller fixed, whatever the picture's shape.
    func testAWidescreenPictureStaysInsideTheFixedSquare() throws {
        let view = ArtworkImage(image: widePicture(), cornerRadius: 0)
            .frame(width: 52, height: 52)
        let rendered = ImageRenderer(content: view)
        let image = try XCTUnwrap(rendered.uiImage, "render failed")
        XCTAssertEqual(Double(image.size.width * image.scale), 52, accuracy: 2)
        XCTAssertEqual(Double(image.size.height * image.scale), 52, accuracy: 2)
    }

    /// The picture fills the box edge to edge (cropped), instead of letterboxing onto the plate:
    /// the top-centre of a red 16:9 cover is red, not the placeholder's grey.
    func testAWidescreenPictureIsCroppedNotLetterboxed() throws {
        let view = ArtworkImage(image: widePicture(), cornerRadius: 0)
            .frame(width: 52, height: 52)
        let rendered = ImageRenderer(content: view)
        let image = try XCTUnwrap(rendered.uiImage, "render failed")
        let pixel = Self.pixel(of: image, at: CGPoint(x: 26, y: 3))
        XCTAssertEqual(pixel.red, 1.0, accuracy: 0.15, "top edge is not the picture: \(pixel)")
        XCTAssertLessThan(pixel.green, 0.35, "top edge is not the picture: \(pixel)")
        XCTAssertLessThan(pixel.blue, 0.35, "top edge is not the picture: \(pixel)")
    }

    /// The shared view's default is Compose's ContentScale.Crop (Coil's AsyncImage default), so a
    /// caller that forgets contentMode still crops rather than letterboxes.
    func testTheDefaultContentModeIsCrop() {
        XCTAssertEqual(ArtworkImage("https://example.com/a=w120-h120", pixels: 160).contentMode, .fill)
    }

    /// A cover already in memory is on the row's first frame: no placeholder and no fade (Coil
    /// serves a memory hit synchronously too). ImageRenderer draws one frame and never runs the
    /// view's task, so only the body's own lookup can put the cover there.
    func testACoverInMemoryIsDrawnOnTheFirstFrame() async throws {
        let file = makeTemporaryDirectory(self).appending(path: "cover.png")
        try XCTUnwrap(widePicture().pngData()).write(to: file)
        let warmed = await ArtworkImageCache.shared.image(for: file, pixels: ArtworkSize.row)
        XCTAssertNotNil(warmed, "the cover loads into memory")

        let row = ArtworkImage(file.absoluteString, pixels: ArtworkSize.row, cornerRadius: 0)
            .frame(width: 48, height: 48)
        let image = try XCTUnwrap(ImageRenderer(content: row).uiImage, "render failed")

        let pixel = Self.pixel(of: image, at: CGPoint(x: 24, y: 24))
        XCTAssertEqual(pixel.red, 1.0, accuracy: 0.15, "the first frame is the placeholder: \(pixel)")
        XCTAssertLessThan(pixel.green, 0.35, "the first frame is the placeholder: \(pixel)")
        let host = UIHostingController(rootView: row)
        host.safeAreaRegions = [] // a 48 pt window would otherwise sit the row under the status bar
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        uiSnapshot(host, "artwork-memory-hit-first-frame")
        window.isHidden = true
    }

    // MARK: Pixel helper

    static func pixel(of image: UIImage, at point: CGPoint) -> (red: Double, green: Double, blue: Double) {
        let cg = image.cgImage!
        let scale = CGFloat(cg.width) / image.size.width
        let x = max(0, min(cg.width - 1, Int(point.x * scale)))
        let y = max(0, min(cg.height - 1, Int(point.y * scale)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: -CGFloat(x), y: -CGFloat(y), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }
}
