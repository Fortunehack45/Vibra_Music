import XCTest
@testable import Theming

/// The AndroidX Palette quantiser (`ColorCutQuantizer`) on synthetic images.
final class SwatchQuantizerTests: XCTestCase {
    func testSolidColourIsOneSwatchOfEveryPixel() {
        let palette = ArtworkSwatchPalette(pixels: solidPixels(width: 16, height: 16, argb(200, 40, 40)), filters: [])
        XCTAssertEqual(palette.swatches, [PaletteSwatch(argb: argb(200, 40, 40), population: 256)])
        XCTAssertEqual(palette.dominantSwatch?.population, 256)
    }

    func testChannelsAreReducedToFiveBits() {
        // 205 → 25 → 200; 47 → 5 → 40; 255 → 31 → 248.
        let palette = ArtworkSwatchPalette(pixels: solidPixels(width: 4, height: 4, argb(205, 47, 255)), filters: [])
        XCTAssertEqual(palette.swatches.first?.argb, argb(200, 40, 248))
    }

    func testAlphaIsIgnored() {
        let palette = ArtworkSwatchPalette(pixels: solidPixels(width: 4, height: 4, argb(200, 40, 40, alpha: 10)), filters: [])
        XCTAssertEqual(palette.swatches.first?.argb, argb(200, 40, 40))
    }

    func testTwoColourSplitCountsEachSide() {
        // 70% blue on the left, 30% yellow on the right.
        let pixels = makePixels(width: 10, height: 10) { x, _ in x < 7 ? argb(32, 64, 200) : argb(240, 200, 40) }
        let palette = ArtworkSwatchPalette(pixels: pixels)
        // Histogram order (ascending 5-5-5 index): blue's red word is lower, so it comes first.
        XCTAssertEqual(palette.swatches, [
            PaletteSwatch(argb: argb(32, 64, 200), population: 70),
            PaletteSwatch(argb: argb(240, 200, 40), population: 30),
        ])
        XCTAssertEqual(palette.dominantSwatch?.argb, argb(32, 64, 200))
    }

    func testDefaultFilterDropsNearBlackNearWhiteAndSkinTones() {
        let pixels = makePixels(width: 4, height: 1) { x, _ in
            [argb(8, 8, 8), argb(248, 248, 248), argb(200, 150, 120), argb(40, 120, 200)][x]
        }
        // Only the blue survives: black (L ≤ 0.05), white (L ≥ 0.95) and the
        // desaturated orange (hue 22°, S ≤ 0.82) are all filtered.
        XCTAssertEqual(ArtworkSwatchPalette(pixels: pixels).swatches.map(\.argb), [argb(40, 120, 200)])
        // `clearFilters()` keeps all four.
        XCTAssertEqual(ArtworkSwatchPalette(pixels: pixels, filters: []).swatches.count, 4)
    }

    func testAllFilteredGivesNoSwatches() {
        let palette = ArtworkSwatchPalette(pixels: solidPixels(width: 8, height: 8, argb(10, 10, 10)))
        XCTAssertTrue(palette.swatches.isEmpty)
        XCTAssertNil(palette.dominantSwatch)
        XCTAssertNil(palette.vibrantSwatch)
    }

    func testMedianCutSplitsAtThePopulationMedianAndOrdersByVolume() {
        // Four reds of equal population along the red axis: 0, 8, 16, 31 (5-bit).
        let reds = [0, 64, 128, 248]
        let pixels = makePixels(width: 4, height: 10) { x, _ in argb(reds[x], 0, 0) }
        let palette = ArtworkSwatchPalette(pixels: pixels, maximumColorCount: 2, filters: [])
        // Split after the second colour (cumulative 20 ≥ 40/2). The upper box
        // (volume 16) sorts ahead of the lower (volume 9) in the heap, and the
        // upper box's mean 23.5 rounds half-up to 24 → 192.
        XCTAssertEqual(palette.swatches, [
            PaletteSwatch(argb: argb(192, 0, 0), population: 20),
            PaletteSwatch(argb: argb(32, 0, 0), population: 20),
        ])
    }

    func testGradientIsCutToTheRequestedCountWithPopulationConserved() {
        // A red→blue gradient with far more than 16 distinct 5-bit colours.
        let pixels = makePixels(width: 128, height: 8) { x, y in argb(255 - x * 2, y * 30, x * 2) }
        let palette = ArtworkSwatchPalette(pixels: pixels, maximumColorCount: 16, resizeArea: nil, filters: [])
        XCTAssertEqual(palette.swatches.count, 16)
        XCTAssertEqual(palette.swatches.reduce(0) { $0 + $1.population }, 128 * 8)
        XCTAssertEqual(Set(palette.swatches.map(\.argb)).count, 16)

        let twentyFour = ArtworkSwatchPalette(pixels: pixels, maximumColorCount: 24, resizeArea: nil, filters: [])
        XCTAssertEqual(twentyFour.swatches.count, 24)
    }

    func testAveragedBoxesAreFilteredAgain() {
        // Yellow and cyan are each allowed, but they share a box whose mean is a
        // green the filter rejects — so that box is dropped after averaging.
        let pixels = makePixels(width: 3, height: 1) { x, _ in [argb(200, 200, 0), argb(0, 200, 200), argb(0, 0, 200)][x] }
        let noGreens = PaletteFilter { _, hsl in !(100...140).contains(hsl.hue) }
        let palette = ArtworkSwatchPalette(pixels: pixels, maximumColorCount: 2, filters: [noGreens])
        XCTAssertEqual(palette.swatches.map(\.argb), [argb(0, 0, 200)])
    }

    func testLargeImagesAreShrunkToTheResizeArea() {
        XCTAssertEqual(ArtworkSwatchPalette.scaledDown(solidPixels(width: 128, height: 128, 0), resizeArea: 112 * 112).width, 112)
        let wide = ArtworkSwatchPalette.scaledDown(solidPixels(width: 200, height: 100, 0), resizeArea: 112 * 112)
        XCTAssertEqual([wide.width, wide.height], [159, 80]) // ceil(200·0.7920), ceil(100·0.7920)
        XCTAssertEqual(ArtworkSwatchPalette.scaledDown(solidPixels(width: 100, height: 100, 0), resizeArea: 112 * 112).width, 100)
        XCTAssertEqual(ArtworkSwatchPalette.scaledDown(solidPixels(width: 500, height: 500, 0), resizeArea: nil).width, 500)

        // Populations are counted after the shrink.
        let palette = ArtworkSwatchPalette(pixels: solidPixels(width: 128, height: 128, argb(40, 120, 200)))
        XCTAssertEqual(palette.swatches.first?.population, 112 * 112)
    }

    func testNearestNeighbourPicksThePixelUnderEachCentre() {
        let pixels = makePixels(width: 4, height: 4) { x, y in argb(x * 10, y * 10, 0) }
        let half = pixels.scaledNearestNeighbor(width: 2, height: 2)
        XCTAssertEqual(half.argb, [argb(10, 10, 0), argb(30, 10, 0), argb(10, 30, 0), argb(30, 30, 0)])
    }

    func testJavaPriorityQueueKeepsTheJDKsArrayOrder() {
        var queue = JavaPriorityQueue<Int> { $0 - $1 }
        for value in [5, 3, 8, 1] {
            queue.offer(value)
        }
        XCTAssertEqual(queue.elementsInIterationOrder, [1, 3, 8, 5])
        XCTAssertEqual(queue.poll(), 1)
        XCTAssertEqual(queue.elementsInIterationOrder, [3, 5, 8])
        XCTAssertEqual(queue.poll(), 3)
        XCTAssertEqual(queue.poll(), 5)
        XCTAssertEqual(queue.poll(), 8)
        XCTAssertNil(queue.poll())
    }
}

/// Palette's target swatches (vibrant, muted and their light and dark variants).
final class SwatchTargetTests: XCTestCase {
    /// Four quadrants: a vivid red, a dark saturated blue, a light pastel pink and
    /// a greyish green.
    private func quadrants() -> ArtworkPixels {
        makePixels(width: 20, height: 20) { x, y in
            switch (x < 10, y < 10) {
            case (true, true): argb(230, 30, 30)
            case (false, true): argb(20, 30, 120)
            case (true, false): argb(240, 200, 210)
            case (false, false): argb(110, 130, 110)
            }
        }
    }

    func testEachFamilyLandsInItsTarget() {
        let palette = ArtworkSwatchPalette(pixels: quadrants())
        XCTAssertEqual(palette.swatches.count, 4)
        XCTAssertEqual(palette.vibrantSwatch?.argb, argb(224, 24, 24))
        XCTAssertEqual(palette.darkVibrantSwatch?.argb, argb(16, 24, 120))
        XCTAssertEqual(palette.lightVibrantSwatch?.argb, argb(240, 200, 208))
        XCTAssertEqual(palette.mutedSwatch?.argb, argb(104, 128, 104))
        // Nothing is light-and-grey or dark-and-grey.
        XCTAssertNil(palette.lightMutedSwatch)
        XCTAssertNil(palette.darkMutedSwatch)
    }

    func testExclusiveTargetsDoNotShareASwatch() {
        // One colour that fits both the light-vibrant and vibrant windows.
        let pixels = solidPixels(width: 8, height: 8, argb(230, 110, 110))
        let palette = ArtworkSwatchPalette(pixels: pixels)
        XCTAssertEqual(palette.lightVibrantSwatch?.argb, argb(224, 104, 104))
        XCTAssertNil(palette.vibrantSwatch, "light vibrant took it first")

        var shared = PaletteTarget.vibrant
        shared.isExclusive = false
        var sharedLight = PaletteTarget.lightVibrant
        sharedLight.isExclusive = false
        let open = ArtworkSwatchPalette(pixels: pixels, targets: [sharedLight, shared])
        XCTAssertEqual(open.swatch(for: sharedLight)?.argb, argb(224, 104, 104))
        XCTAssertEqual(open.swatch(for: shared)?.argb, argb(224, 104, 104))
    }

    func testPopulationBreaksCloseScores() {
        // Two vibrant reds of nearly equal saturation and lightness; the much more
        // populous one wins the vibrant target.
        let pixels = makePixels(width: 10, height: 10) { x, _ in x < 9 ? argb(200, 40, 40) : argb(208, 40, 48) }
        let palette = ArtworkSwatchPalette(pixels: pixels)
        XCTAssertEqual(palette.vibrantSwatch?.argb, argb(200, 40, 40))
    }

    func testTargetWindowsMatchAndroid() {
        XCTAssertEqual(PaletteTarget.lightVibrant.minimumLightness, 0.55)
        XCTAssertEqual(PaletteTarget.lightVibrant.targetLightness, 0.74)
        XCTAssertEqual(PaletteTarget.lightVibrant.minimumSaturation, 0.35)
        XCTAssertEqual(PaletteTarget.vibrant.minimumLightness, 0.3)
        XCTAssertEqual(PaletteTarget.vibrant.maximumLightness, 0.7)
        XCTAssertEqual(PaletteTarget.vibrant.targetSaturation, 1)
        XCTAssertEqual(PaletteTarget.darkVibrant.targetLightness, 0.26)
        XCTAssertEqual(PaletteTarget.darkVibrant.maximumLightness, 0.45)
        XCTAssertEqual(PaletteTarget.muted.targetSaturation, 0.3)
        XCTAssertEqual(PaletteTarget.muted.maximumSaturation, 0.4)
        XCTAssertEqual(PaletteTarget.defaults, [.lightVibrant, .vibrant, .darkVibrant, .lightMuted, .muted, .darkMuted])
        let weights = PaletteTarget.vibrant.normalizedWeights()
        XCTAssertEqual(weights.saturation + weights.lightness + weights.population, 1, accuracy: 1e-6)
    }

    func testSwatchBuilderHasNoTargetsByDefault() {
        let palette = ArtworkSwatchPalette(swatches: [PaletteSwatch(argb: argb(224, 24, 24), population: 5)])
        XCTAssertNil(palette.vibrantSwatch)
        XCTAssertEqual(palette.dominantSwatch?.population, 5)
        let targeted = ArtworkSwatchPalette(swatches: palette.swatches, targets: PaletteTarget.defaults)
        XCTAssertEqual(targeted.vibrantSwatch?.argb, argb(224, 24, 24))
    }

    func testTextColoursClearTheirContrast() {
        let dark = PaletteSwatch(argb: argb(16, 24, 120), population: 1)
        XCTAssertEqual(dark.bodyTextColor.argb & 0x00FF_FFFF, 0xFF_FFFF, "white on a dark swatch")
        XCTAssertGreaterThanOrEqual(dark.bodyTextColor.contrastRatio(over: dark.color), 4.5)
        XCTAssertGreaterThanOrEqual(dark.titleTextColor.contrastRatio(over: dark.color), 3.0)
        // Titles need less contrast, so they can be more transparent.
        XCTAssertLessThanOrEqual(dark.titleTextColor.alpha, dark.bodyTextColor.alpha)

        let light = PaletteSwatch(argb: argb(240, 200, 208), population: 1)
        XCTAssertEqual(light.bodyTextColor.argb & 0x00FF_FFFF, 0, "black on a light swatch")
        XCTAssertGreaterThanOrEqual(light.bodyTextColor.contrastRatio(over: light.color), 4.5)
    }
}
