import XCTest
@testable import Theming

/// Port of `ArtworkPaletteTest.kt` (`adaptedArtworkSaturation`), plus the page
/// palette that is built on it.
final class ArtworkSaturationTests: XCTestCase {
    func testGrayscaleDoesNotAcquireTheDefaultRedHue() {
        XCTAssertEqual(adaptedArtworkSaturation(0, minimum: 0.20, maximum: 0.62), 0)
        XCTAssertEqual(adaptedArtworkSaturation(0, minimum: 0.55, maximum: 1), 0)
    }

    func testNearlyNeutralArtworkKeepsItsSubtleSaturation() {
        XCTAssertEqual(adaptedArtworkSaturation(0.08, minimum: 0.20, maximum: 0.62), 0.08)
    }

    func testGenuinelyChromaticArtworkIsStillStrengthenedAndCapped() {
        XCTAssertEqual(adaptedArtworkSaturation(0.25, minimum: 0.55, maximum: 1), 0.55)
        XCTAssertEqual(adaptedArtworkSaturation(0.90, minimum: 0.20, maximum: 0.62), 0.62)
    }

    func testThresholdIsInclusiveOfChromatic() {
        // 0.12 is the first saturation that counts as a real colour.
        XCTAssertEqual(adaptedArtworkSaturation(0.12, minimum: 0.20, maximum: 0.62), 0.20)
        XCTAssertEqual(adaptedArtworkSaturation(0.1199, minimum: 0.20, maximum: 0.62), 0.1199)
        // Out-of-range input is clamped first.
        XCTAssertEqual(adaptedArtworkSaturation(-1, minimum: 0.20, maximum: 0.62), 0)
        XCTAssertEqual(adaptedArtworkSaturation(3, minimum: 0.20, maximum: 0.62), 0.62)
    }
}

/// The page tint (`Seed.toPalette`) for dark and light themes.
final class ArtworkPageTintTests: XCTestCase {
    private let chromatic = ArtworkSeed(
        dominant: ThemeColor(argb: 0xFF1E_3C72), // deep blue
        vibrant: ThemeColor(argb: 0xFFE0_4020), // orange-red
        edge: ThemeColor(argb: 0xFF50_3020),
        topBandLuminance: 0.1
    )

    func testDarkTintKeepsTheHueAtFixedDepth() {
        let palette = chromatic.palette(dark: true)
        let dominantHue = chromatic.dominant.hsl.hue

        let background = palette.background.hsl
        XCTAssertEqual(background.lightness, 0.13, accuracy: 0.005)
        XCTAssertEqual(background.hue, dominantHue, accuracy: 3)
        XCTAssertTrue((0.195...0.625).contains(background.saturation), "\(background.saturation)")

        XCTAssertEqual(palette.elevated.hsl.lightness, 0.22, accuracy: 0.005)
        XCTAssertGreaterThan(palette.elevated.luminance, palette.background.luminance)

        let accent = palette.accent.hsl
        XCTAssertTrue((0.615...0.785).contains(accent.lightness), "\(accent.lightness)")
        XCTAssertGreaterThanOrEqual(accent.saturation, 0.545)

        let wash = palette.wash.hsl
        XCTAssertTrue((0.135...0.245).contains(wash.lightness), "\(wash.lightness)")

        XCTAssertEqual(palette.onBackground, .white)
        XCTAssertEqual(palette.onBackgroundVariant, ThemeColor.white.withAlpha(0.80))
        XCTAssertEqual(palette.divider, ThemeColor.white.withAlpha(0.12))
        // White body text clears WCAG AA on the tint.
        XCTAssertGreaterThan(ThemeColor.white.contrastRatio(over: palette.background), 4.5)
    }

    func testLightTintIsAPaleWashOfTheSameHue() {
        let palette = chromatic.palette(dark: false)
        XCTAssertEqual(palette.background.hsl.lightness, 0.91, accuracy: 0.005)
        XCTAssertEqual(palette.background.hsl.hue, chromatic.dominant.hsl.hue, accuracy: 3)
        XCTAssertEqual(palette.elevated.hsl.lightness, 0.83, accuracy: 0.005)
        XCTAssertTrue((0.295...0.445).contains(palette.accent.hsl.lightness))
        XCTAssertTrue((0.775...0.905).contains(palette.wash.hsl.lightness))
        XCTAssertEqual(palette.onBackground, .black)
        XCTAssertEqual(palette.onBackgroundVariant, ThemeColor.black.withAlpha(0.70))
        XCTAssertEqual(palette.divider, ThemeColor.black.withAlpha(0.10))
        XCTAssertGreaterThan(ThemeColor.black.contrastRatio(over: palette.background), 4.5)
    }

    func testMonochromeSleeveStaysNeutralNotMaroon() {
        // The bug the saturation guard exists for: grey has hue 0, so raising its
        // saturation to a floor manufactured red, and a dark page turned maroon.
        let grey = ArtworkSeed(
            dominant: ThemeColor(argb: 0xFF80_8080),
            vibrant: ThemeColor(argb: 0xFFA0_A0A0),
            edge: ThemeColor(argb: 0xFF40_4040),
            topBandLuminance: 0.2
        )
        for dark in [true, false] {
            let palette = grey.palette(dark: dark)
            for color in [palette.background, palette.wash, palette.elevated, palette.accent] {
                XCTAssertTrue(color.isNeutral, "\(color) should be grey (dark: \(dark))")
            }
        }
        assertColor(grey.palette(dark: true).background, 0xFF21_2121) // 0.13 * 255 = 33.15
    }

    func testWashFollowsTheEdgeWithinItsBand() {
        func seed(edge: UInt32) -> ArtworkSeed {
            ArtworkSeed(dominant: chromatic.dominant, vibrant: chromatic.vibrant, edge: ThemeColor(argb: edge), topBandLuminance: 0)
        }
        // A sleeve that ends near-black hands over at the band's floor…
        XCTAssertEqual(seed(edge: 0xFF08_0808).palette(dark: true).wash.hsl.lightness, 0.14, accuracy: 0.005)
        // …one that ends bright is capped at its ceiling.
        XCTAssertEqual(seed(edge: 0xFFF0_E0D0).palette(dark: true).wash.hsl.lightness, 0.24, accuracy: 0.005)
        // In between it keeps its own brightness.
        XCTAssertEqual(seed(edge: 0xFF33_2E29).palette(dark: true).wash.hsl.lightness, seed(edge: 0xFF33_2E29).edge.hsl.lightness, accuracy: 0.005)
    }

    func testUntintedIsTheSchemesOwnColours() {
        let dark = ArtworkPalette.untinted(.dark)
        XCTAssertEqual(dark.background, ThemeColorScheme.dark.background)
        XCTAssertEqual(dark.wash, ThemeColorScheme.dark.background)
        XCTAssertEqual(dark.elevated, ThemeColorScheme.dark.surfaceVariant)
        XCTAssertEqual(dark.accent, ThemeColorScheme.dark.primary)
        XCTAssertEqual(dark.onBackground, ThemeColorScheme.dark.onBackground)
        XCTAssertEqual(dark.onBackgroundVariant, ThemeColorScheme.dark.onSurfaceVariant)
        XCTAssertEqual(dark.divider, ThemeColorScheme.dark.outline)
        XCTAssertEqual(ArtworkPalette.untinted(.light).background, .white)
    }

    func testTintFadesOnlyWhenColoursArriveLate() {
        XCTAssertEqual(ArtworkPalette.tintFade(reduceAnimation: false, knownUpFront: false), 0.26)
        XCTAssertNil(ArtworkPalette.tintFade(reduceAnimation: false, knownUpFront: true))
        XCTAssertNil(ArtworkPalette.tintFade(reduceAnimation: true, knownUpFront: false))
    }

    func testPaletteCrossfadeInterpolatesEveryRole() {
        let from = ArtworkPalette.untinted(.dark)
        let to = chromatic.palette(dark: true)
        XCTAssertEqual(ArtworkPalette.interpolate(from: from, to: to, fraction: 0), from)
        XCTAssertEqual(ArtworkPalette.interpolate(from: from, to: to, fraction: 1), to)
        let middle = ArtworkPalette.interpolate(from: from, to: to, fraction: 0.5)
        XCTAssertNotEqual(middle.background, from.background)
        XCTAssertNotEqual(middle.background, to.background)
        XCTAssertNotEqual(middle.accent, from.accent)
        // Alpha interpolates straight: 0.8 white towards opaque grey.
        XCTAssertEqual(middle.onBackgroundVariant.alpha, (from.onBackgroundVariant.alpha + 0.8) / 2, accuracy: 1e-9)
    }
}
