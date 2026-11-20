import SwiftUI
import XCTest
@testable import Theming

/// Port of `StatusBarContrastTest.kt`, plus the player's scrim gradient and the
/// app-wide glyph policy.
final class StatusBarContrastTests: XCTestCase {
    // MARK: Ported

    func testDarkTopBandUsesSubtleBaseScrim() {
        XCTAssertEqual(StatusBarContrast.topBandScrimAlpha(artworkLuminance: 0), 0.16, accuracy: 0.0001)
        XCTAssertEqual(StatusBarContrast.topBandScrimAlpha(artworkLuminance: nil), 0.16, accuracy: 0.0001)
    }

    func testLightTopBandUsesMaximumScrim() {
        XCTAssertEqual(StatusBarContrast.topBandScrimAlpha(artworkLuminance: 1), 0.65, accuracy: 0.0001)
        // Out of range is clamped, not extrapolated: a luminance above 1 is a
        // rounding artefact, not a reason to darken past the ceiling.
        XCTAssertEqual(StatusBarContrast.topBandScrimAlpha(artworkLuminance: 2), 0.65, accuracy: 0.0001)
    }

    func testMixedTopBandInterpolatesScrimInLinearLuminance() {
        let mixed = StatusBarContrast.averageRelativeLuminance([0xFF00_0000, 0xFFFF_FFFF, 0xFF00_0000, 0xFFFF_FFFF] as [UInt32])

        XCTAssertEqual(mixed, 0.5, accuracy: 0.0001)
        // The midpoint of the 0.16…0.65 band, read off the linear luminance
        // rather than off the sRGB values — half black and half white averages
        // to a mid grey here, not to the much darker sRGB midpoint.
        XCTAssertEqual(StatusBarContrast.topBandScrimAlpha(artworkLuminance: mixed), 0.405, accuracy: 0.0001)
    }

    // MARK: Luminance

    func testRelativeLuminanceMatchesWCAG() {
        XCTAssertEqual(StatusBarContrast.relativeLuminance(argb: argb(0, 0, 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(StatusBarContrast.relativeLuminance(argb: argb(255, 255, 255)), 1, accuracy: 1e-6)
        // Pure primaries are their coefficients.
        XCTAssertEqual(StatusBarContrast.relativeLuminance(argb: argb(255, 0, 0)), 0.2126, accuracy: 1e-6)
        XCTAssertEqual(StatusBarContrast.relativeLuminance(argb: argb(0, 255, 0)), 0.7152, accuracy: 1e-6)
        XCTAssertEqual(StatusBarContrast.relativeLuminance(argb: argb(0, 0, 255)), 0.0722, accuracy: 1e-6)
        // sRGB mid grey is about a fifth as bright in linear light.
        XCTAssertEqual(StatusBarContrast.relativeLuminance(argb: argb(128, 128, 128)), 0.2158, accuracy: 0.0005)
    }

    func testAverageOfNothingIsDark() {
        XCTAssertEqual(StatusBarContrast.averageRelativeLuminance([UInt32]()), 0)
    }

    func testSubviewKeepsAModestFloor() {
        // A dark cover's scrim is raised to the floor while lyrics or queue are open…
        XCTAssertEqual(StatusBarContrast.playerTopScrimAlpha(artworkLuminance: 0, subviewOpen: true), 0.40, accuracy: 1e-9)
        XCTAssertEqual(StatusBarContrast.playerTopScrimAlpha(artworkLuminance: 0, subviewOpen: false), 0.16, accuracy: 1e-9)
        // …and a bright one's stronger scrim is kept.
        XCTAssertEqual(StatusBarContrast.playerTopScrimAlpha(artworkLuminance: 1, subviewOpen: true), 0.65, accuracy: 1e-9)
    }

    func testTopScrimFadesOutWithPowerFalloff() {
        let stops = StatusBarContrast.playerTopScrimStops(alpha: 0.5)
        XCTAssertEqual(stops.count, 8)
        XCTAssertEqual(stops.first?.location, 0)
        XCTAssertEqual(stops.last?.location, 1)
        XCTAssertEqual(stops[0].color.alpha, 0.5, accuracy: 1e-6)
        XCTAssertEqual(stops[7].color.alpha, 0, accuracy: 1e-6)
        // (1 - 1/7)^1.5 of the top opacity at the second stop.
        XCTAssertEqual(stops[1].color.alpha, 0.5 * pow(6.0 / 7.0, 1.5), accuracy: 1e-6)
        for (upper, lower) in zip(stops, stops.dropFirst()) {
            XCTAssertGreaterThan(upper.color.alpha, lower.color.alpha)
            XCTAssertEqual(lower.color.red, 0)
        }
    }

    func testSeedCarriesItsScrim() {
        let whiteTop = makePixels(width: 20, height: 20) { _, y in y < 10 ? argb(255, 255, 255) : argb(0, 0, 0) }
        let seed = try? XCTUnwrap(ArtworkSeed(pixels: whiteTop))
        XCTAssertEqual(seed?.statusBarScrimAlpha ?? 0, 0.65, accuracy: 1e-6)
    }

    // MARK: Glyph policy

    func testGlyphsFollowTheAppNotTheSystem() {
        // Light theme: dark glyphs on every ordinary page…
        XCTAssertEqual(StatusBarContrast.glyphs(darkTheme: false, nowPlayingShown: false, replayShown: false, replayStoryShown: false), .dark)
        // …but the player and Replay are dark artwork either way.
        XCTAssertEqual(StatusBarContrast.glyphs(darkTheme: false, nowPlayingShown: true, replayShown: false, replayStoryShown: false), .light)
        XCTAssertEqual(StatusBarContrast.glyphs(darkTheme: false, nowPlayingShown: false, replayShown: true, replayStoryShown: false), .light)
        XCTAssertEqual(StatusBarContrast.glyphs(darkTheme: false, nowPlayingShown: false, replayShown: false, replayStoryShown: true), .light)
        // Dark theme: always light glyphs.
        XCTAssertEqual(StatusBarContrast.glyphs(darkTheme: true, nowPlayingShown: false, replayShown: false, replayStoryShown: false), .light)
        XCTAssertEqual(StatusBarContrast.playerGlyphs, .light)
    }

    func testGlyphsMapToTheInverseColorScheme() {
        XCTAssertEqual(StatusBarGlyphs.dark.colorScheme, .light)
        XCTAssertEqual(StatusBarGlyphs.light.colorScheme, .dark)
    }
}
