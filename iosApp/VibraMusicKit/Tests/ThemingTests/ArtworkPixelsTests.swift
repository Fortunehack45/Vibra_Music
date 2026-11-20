import CoreGraphics
import ImageIO
import XCTest
@testable import Theming

/// Reading `CGImage`s and encoded bytes into the pixel layout the colour code
/// expects, and the pixel-level helpers (black-frame test, box blur).
final class ArtworkPixelsTests: XCTestCase {
    func testReadsTopRowFirstInSRGB() throws {
        let image = makeCGImage(width: 4, height: 2) { context in
            // Bottom row (CG origin) green, top row red.
            context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 1))
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 1, width: 4, height: 1))
        }
        let pixels = try XCTUnwrap(ArtworkPixels(image: image))
        XCTAssertEqual([pixels.width, pixels.height], [4, 2])
        XCTAssertEqual(pixels.argb, Array(repeating: argb(255, 0, 0), count: 4) + Array(repeating: argb(0, 255, 0), count: 4))
    }

    func testFitsTheLongerSideUpOrDown() throws {
        let image = makeCGImage(width: 200, height: 100) { context in
            context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }
        let down = try XCTUnwrap(ArtworkPixels(image: image, fittingLongestSide: 50))
        XCTAssertEqual([down.width, down.height], [50, 25])
        // Like Coil's exact-precision request, a small source is scaled up.
        let up = try XCTUnwrap(ArtworkPixels(image: image, fittingLongestSide: 400))
        XCTAssertEqual([up.width, up.height], [400, 200])
        XCTAssertEqual(Set(up.argb), [argb(128, 128, 128)])
    }

    func testTranslucentPixelsComeBackStraightAlpha() throws {
        let image = makeCGImage(width: 2, height: 2) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let pixel = try XCTUnwrap(ArtworkPixels(image: image)).argb[0]
        XCTAssertEqual(Double(pixel >> 24), 128, accuracy: 1)
        XCTAssertEqual(Double((pixel >> 16) & 0xFF), 255, accuracy: 1)
        XCTAssertEqual(pixel & 0xFFFF, 0)
        let clear = makeCGImage(width: 1, height: 1) { _ in }
        XCTAssertEqual(try XCTUnwrap(ArtworkPixels(image: clear)).argb, [0])
    }

    func testWideGamutArtworkIsColourMatchedToSRGB() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let image = makeCGImage(width: 2, height: 2, space: p3) { context in
            context.setFillColor(CGColor(colorSpace: p3, components: [0.8, 0.3, 0.3, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let pixel = try XCTUnwrap(ArtworkPixels(image: image)).argb[0]
        // P3 (0.8, 0.3, 0.3) is a more saturated red than sRGB (0.8, 0.3, 0.3).
        XCTAssertGreaterThan(Int((pixel >> 16) & 0xFF), 204)
        XCTAssertLessThan(Int((pixel >> 8) & 0xFF), 77)
    }

    func testDecodesEncodedBytesStraightToAThumbnail() throws {
        let image = makeCGImage(width: 300, height: 150) { context in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 150))
        }
        let pixels = try XCTUnwrap(ArtworkPixels(imageData: pngData(image), fittingLongestSide: 120))
        XCTAssertEqual([pixels.width, pixels.height], [120, 60])
        XCTAssertEqual(Set(pixels.argb), [argb(0, 0, 255)])
        XCTAssertNil(ArtworkPixels(imageData: Data("not an image".utf8), fittingLongestSide: 120))
        XCTAssertNil(ArtworkPixels(imageData: pngData(image), fittingLongestSide: 0))
    }

    func testRealJPEGFixtureDecodes() throws {
        let pixels = try ThemingFixtures.pixels(ThemingFixtures.randomAccessMemories, side: 128)
        XCTAssertEqual([pixels.width, pixels.height], [128, 128])
        XCTAssertTrue(pixels.argb.allSatisfy { $0 >> 24 == 0xFF }, "JPEGs are opaque")
    }

    func testMakeCGImageRoundTrips() throws {
        let source = makePixels(width: 5, height: 3) { x, y in argb(x * 50, y * 100, 7, alpha: 255) }
        let image = try XCTUnwrap(source.makeCGImage())
        XCTAssertEqual(try XCTUnwrap(ArtworkPixels(image: image)), source)
        XCTAssertNil(ArtworkPixels(width: 0, height: 0, argb: []).makeCGImage())
    }

    // MARK: Black frames (FrameHeuristics.kt)

    func testBlackFrameHeuristic() {
        XCTAssertTrue(solidPixels(width: 64, height: 36, argb(0, 0, 0)).isLikelyBlackFrame)
        // Mean luma 11 is still "black"; 12 is a real (dark) frame.
        XCTAssertTrue(solidPixels(argb(11, 11, 11)).isLikelyBlackFrame)
        XCTAssertFalse(solidPixels(argb(12, 12, 12)).isLikelyBlackFrame)
        // BT.601 weights: pure blue at 100 is luma 11.
        XCTAssertTrue(solidPixels(argb(0, 0, 100)).isLikelyBlackFrame)
        XCTAssertFalse(solidPixels(argb(0, 30, 0)).isLikelyBlackFrame)
        XCTAssertTrue(ArtworkPixels(width: 0, height: 0, argb: []).isLikelyBlackFrame)
        // A dark sleeve with a bright element is not black.
        let darkSleeve = makePixels(width: 64, height: 64) { x, y in (20..<44).contains(x) && (20..<44).contains(y) ? argb(200, 180, 60) : argb(3, 3, 3) }
        XCTAssertFalse(darkSleeve.isLikelyBlackFrame)
    }

    // MARK: Box blur

    func testBoxBlurLeavesAFlatImageFlatAndSoftensEdges() {
        let flat = solidPixels(width: 128, height: 128, argb(40, 80, 120))
        XCTAssertEqual(flat.boxBlurred(), flat)

        let edge = makePixels(width: 128, height: 128) { x, _ in x < 64 ? argb(0, 0, 0) : argb(240, 240, 240) }
        let blurred = edge.boxBlurred()
        let row = (0..<128).map { Int(blurred.pixel(x: $0, y: 64) & 0xFF) }
        XCTAssertEqual(row[0], 0)
        XCTAssertEqual(row[127], 240)
        XCTAssertEqual(row, row.sorted(), "a blurred step is monotonic")
        XCTAssertTrue((100...140).contains(row[63]) || (100...140).contains(row[64]), "the edge is softened: \(row[60...67])")
        XCTAssertGreaterThan(row.filter { $0 > 0 && $0 < 240 }.count, 20)
    }

    func testBoxBlurDropsAlphaAndSkipsDegenerateImages() {
        let translucent = solidPixels(width: 8, height: 8, argb(10, 20, 30, alpha: 40))
        XCTAssertEqual(Set(translucent.boxBlurred().argb), [argb(10, 20, 30)])
        let line = solidPixels(width: 1, height: 20, argb(10, 20, 30, alpha: 40))
        XCTAssertEqual(line.boxBlurred(), line)
    }
}
