import XCTest
@testable import Theming

/// Reading a page-tint seed (`seedOf`) off synthetic sleeves.
final class ArtworkSeedTests: XCTestCase {
    func testSolidSleeve() throws {
        let seed = try XCTUnwrap(ArtworkSeed(pixels: solidPixels(width: 128, height: 128, argb(50, 100, 200))))
        // Swatches are 5-bit approximations; the edge is a plain mean and isn't.
        assertColor(seed.dominant, argb(48, 96, 200))
        assertColor(seed.vibrant, argb(48, 96, 200))
        assertColor(seed.edge, argb(50, 100, 200))
        XCTAssertEqual(seed.topBandLuminance, StatusBarContrast.relativeLuminance(argb: argb(50, 100, 200)), accuracy: 1e-6)
    }

    func testEdgeIsTheBottomBandsMeanAndTopBandIsTheTop() throws {
        // White top half, black bottom half.
        let pixels = makePixels(width: 100, height: 100) { _, y in y < 50 ? argb(255, 255, 255) : argb(0, 0, 0) }
        let seed = try XCTUnwrap(ArtworkSeed(pixels: pixels))
        assertColor(seed.edge, argb(0, 0, 0))
        XCTAssertEqual(seed.topBandLuminance, 1, accuracy: 1e-6)
    }

    func testBandsAreEighteenAndTenPercent() throws {
        // A stripe of red across rows 80–81 of 100: inside the bottom 18% band
        // (rows 82–99)? No — so the edge is pure blue. Rows 82+ are the band.
        let outside = makePixels(width: 10, height: 100) { _, y in y == 81 ? argb(255, 0, 0) : argb(0, 0, 255) }
        assertColor(try XCTUnwrap(ArtworkSeed(pixels: outside)).edge, argb(0, 0, 255))
        // One red row inside the band shifts the mean by 1/18.
        let inside = makePixels(width: 10, height: 100) { _, y in y == 82 ? argb(255, 0, 0) : argb(0, 0, 255) }
        assertColor(try XCTUnwrap(ArtworkSeed(pixels: inside)).edge, argb(14, 0, 240))
        // Top band: rows 0–9 of 100.
        let top = makePixels(width: 10, height: 100) { _, y in y < 10 ? argb(255, 255, 255) : argb(0, 0, 0) }
        XCTAssertEqual(try XCTUnwrap(ArtworkSeed(pixels: top)).topBandLuminance, 1, accuracy: 1e-6)
    }

    func testMostlyBlackSleeveIsDominatedByBlackButAccentsInItsColour() throws {
        // Nine-tenths black with a red stripe: the page is black (the unfiltered
        // dominant), the accent is the red (black is filtered out of accents).
        let pixels = makePixels(width: 100, height: 100) { _, y in (45..<55).contains(y) ? argb(220, 30, 40) : argb(4, 4, 4) }
        let seed = try XCTUnwrap(ArtworkSeed(pixels: pixels))
        assertColor(seed.dominant, argb(0, 0, 0))
        assertColor(seed.vibrant, argb(216, 24, 40))
        // …and the dark page is near-black grey, not red.
        XCTAssertTrue(seed.palette(dark: true).background.isNeutral)
    }

    func testAccentWeighsSaturationAgainstSquareRootOfPopulation() throws {
        // 64% muted blue-grey, 36% saturated orange: sat·√pop favours the orange
        // even though it is the smaller area (and, fully saturated, it clears the
        // skin-tone filter despite its 34° hue).
        let pixels = makePixels(width: 10, height: 10) { x, _ in x < 6 ? argb(90, 100, 120) : argb(240, 140, 0) }
        let seed = try XCTUnwrap(ArtworkSeed(pixels: pixels))
        assertColor(seed.dominant, argb(88, 96, 120))
        assertColor(seed.vibrant, argb(240, 136, 0))
    }

    func testMonochromeSleeveFallsBackToAllSwatchesForTheAccent() throws {
        // Pure black and white: the default filter leaves no accent candidates,
        // so the accent comes from the unfiltered set (first highest score).
        let pixels = makePixels(width: 10, height: 10) { x, _ in x < 5 ? argb(0, 0, 0) : argb(255, 255, 255) }
        let seed = try XCTUnwrap(ArtworkSeed(pixels: pixels))
        assertColor(seed.dominant, argb(0, 0, 0))
        assertColor(seed.vibrant, argb(0, 0, 0))
        let palette = seed.palette(dark: true)
        XCTAssertTrue(palette.background.isNeutral)
        XCTAssertTrue(palette.accent.isNeutral)
    }

    func testTinyAndEmptySleeves() throws {
        let one = try XCTUnwrap(ArtworkSeed(pixels: solidPixels(width: 1, height: 1, argb(10, 200, 30))))
        assertColor(one.edge, argb(10, 200, 30))
        XCTAssertNil(ArtworkSeed(pixels: ArtworkPixels(width: 0, height: 0, argb: [])))
    }

    func testSeedFromCGImageDecodesAtPaletteSize() throws {
        let image = makeCGImage(width: 300, height: 300) { context in
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        }
        let seed = try XCTUnwrap(ArtworkSeed(image: image))
        assertColor(seed.edge, argb(51, 102, 204), tolerance: 1)
        assertColor(seed.dominant, argb(48, 96, 200))
    }
}
