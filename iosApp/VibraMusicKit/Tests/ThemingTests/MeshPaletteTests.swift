import CoreGraphics
import XCTest
@testable import Theming

/// The blob mesh's four colours (`paletteOf` in MeshGradient.kt).
final class MeshPaletteTests: XCTestCase {
    func testFourDistinctColoursAreTakenMostPopulousFirst() {
        // Five well-separated hues with different areas.
        let colors = [argb(200, 40, 40), argb(40, 160, 60), argb(40, 60, 200), argb(220, 200, 40), argb(160, 40, 200)]
        let widths = [30, 25, 20, 15, 10] // columns out of 100
        let pixels = makePixels(width: 100, height: 10) { x, _ in
            var edge = 0
            for (index, width) in widths.enumerated() {
                edge += width
                if x < edge { return colors[index] }
            }
            return colors[4]
        }
        let palette = MeshPalette(pixels: pixels)
        XCTAssertEqual(palette.colors.map(\.argb), [argb(200, 40, 40), argb(40, 160, 56), argb(40, 56, 200), argb(216, 200, 40)])
    }

    func testNearDuplicatesCollapseSoBlobsDoNotMergeIntoOneWash() {
        let close = [ThemeColor(argb: argb(200, 40, 40)), ThemeColor(argb: argb(208, 48, 40)), ThemeColor(argb: argb(40, 60, 200))]
        let kept = MeshPalette.distinctEnough(close)
        XCTAssertEqual(kept.map(\.argb), [argb(200, 40, 40), argb(40, 60, 200)])
        // Same hue but far apart in lightness is distinct.
        XCTAssertFalse(MeshPalette.isClose(ThemeColor(argb: argb(80, 10, 10)), ThemeColor(argb: argb(250, 150, 150))))
        // Hue distance wraps around 360°.
        XCTAssertTrue(MeshPalette.isClose(ThemeColor(argb: argb(200, 40, 48)), ThemeColor(argb: argb(200, 48, 40))))
    }

    func testShortfallIsDerivedFromTheArtNotTheStockColours() {
        let palette = MeshPalette(pixels: solidPixels(width: 32, height: 32, argb(40, 60, 200)))
        XCTAssertEqual(palette.colors.count, 4)
        let base = ThemeColor(argb: argb(40, 56, 200)).hsl
        XCTAssertEqual(palette.colors[0].argb, argb(40, 56, 200))
        for (index, step) in [(1, 1), (2, 2), (3, 3)] {
            let hsl = palette.colors[index].hsl
            XCTAssertEqual(hsl.hue, (base.hue + 24 * Float(step)).truncatingRemainder(dividingBy: 360), accuracy: 1.5)
            XCTAssertEqual(hsl.lightness, min(max(base.lightness + 0.12 * Float(step), 0.2), 0.7), accuracy: 0.005)
        }
        XCTAssertFalse(palette.colors.contains { MeshPalette.fallbackColors.contains($0) })
    }

    func testMonochromeSleeveUsesUnfilteredSwatches() {
        // Everything is near-black, which the default filter drops; the cleared
        // pass still finds it rather than falling back to stock purple.
        let palette = MeshPalette(pixels: solidPixels(width: 16, height: 16, argb(6, 6, 6)))
        XCTAssertEqual(palette.colors.first?.argb, argb(0, 0, 0))
        XCTAssertEqual(palette.colors.count, 4)
        XCTAssertNotEqual(palette, .fallback)
    }

    func testNothingToReadIsTheStockPalette() {
        XCTAssertEqual(MeshPalette(pixels: ArtworkPixels(width: 0, height: 0, argb: [])), .fallback)
        XCTAssertEqual(MeshPalette.fallback.colors.map(\.argb), [0xFF3A_1C71, 0xFFD7_6D77, 0xFF2B_5876, 0xFFFF_AF7B])
    }

    func testRotationTurnsHueAndKeepsTone() {
        let palette = MeshPalette(colors: [ThemeColor(argb: 0xFFFF_0000), ThemeColor(argb: 0xFF3A_1C71)])
        XCTAssertEqual(palette.rotated(degrees: 0), palette)
        let turned = palette.rotated(degrees: 120)
        XCTAssertEqual(turned.colors[0].argb, 0xFF00_FF00)
        XCTAssertEqual(turned.colors[1].hsl.lightness, palette.colors[1].hsl.lightness, accuracy: 0.005)
        XCTAssertEqual(turned.colors[1].hsl.hue, (palette.colors[1].hsl.hue + 120).truncatingRemainder(dividingBy: 360), accuracy: 1)
    }

    func testFromCGImage() throws {
        let image = makeCGImage(width: 256, height: 256) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 256))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 128, y: 0, width: 128, height: 256))
        }
        let palette = try XCTUnwrap(MeshPalette(image: image))
        XCTAssertEqual(palette.colors.count, 4)
        XCTAssertEqual(Set(palette.colors.prefix(2).map(\.argb)), [argb(248, 0, 0), argb(0, 0, 248)])
    }
}

/// What the blob mesh draws for a palette, and where.
final class MeshGradientPlanTests: XCTestCase {
    func testColoursAreTunedRichAndTheFloorIsDimmed() {
        let colors = MeshGradientColors(palette: MeshPalette(colors: [
            ThemeColor(argb: argb(250, 250, 250)), // too light: clamped to 0.58
            ThemeColor(argb: argb(10, 10, 40)), // too dark: raised to 0.28
            ThemeColor(argb: argb(120, 90, 80)),
            ThemeColor(argb: argb(40, 160, 60)),
        ]))
        XCTAssertEqual(colors.blobs.count, 4)
        XCTAssertEqual(colors.blobs[0].hsl.lightness, 0.58, accuracy: 0.005)
        XCTAssertEqual(colors.blobs[1].hsl.lightness, 0.28, accuracy: 0.005)
        let source = ThemeColor(argb: argb(120, 90, 80)).hsl
        XCTAssertEqual(colors.blobs[2].hsl.saturation, min(source.saturation * 1.35, 1), accuracy: 0.02)
        XCTAssertEqual(colors.base.hsl.lightness, 0.12, accuracy: 0.005)
        XCTAssertEqual(colors.base.hsl.hue, colors.blobs[0].hsl.hue, accuracy: 1)
    }

    func testShortPalettesArePaddedFromTheStockColours() {
        let two = MeshGradientColors(palette: MeshPalette(colors: [ThemeColor(argb: 0xFFFF_0000), ThemeColor(argb: 0xFF00_00FF)]))
        XCTAssertEqual(two.blobs[2], MeshGradientColors.tuned(MeshPalette.fallbackColors[0]))
        XCTAssertEqual(two.blobs[3], MeshGradientColors.tuned(MeshPalette.fallbackColors[1]))
        let none = MeshGradientColors(palette: MeshPalette(colors: []))
        XCTAssertEqual(none, MeshGradientColors(palette: .fallback))
    }

    func testBlobsSitAtTheirAnchorsOffsetByDrift() {
        let colors = MeshGradientColors(palette: .fallback)
        let size = CGSize(width: 400, height: 800)
        let blobs = MeshGradientLayout.blobs(colors: colors, phase: 0, in: size)
        XCTAssertEqual(blobs.count, 4)
        XCTAssertEqual(blobs[0].center.x, (0.20 + 0.16) * 400, accuracy: 1e-6)
        XCTAssertEqual(blobs[0].center.y, 0.25 * 800, accuracy: 1e-6)
        XCTAssertEqual(blobs[1].center.x, (0.80 + 0.16 * cos(1.7)) * 400, accuracy: 1e-6)
        XCTAssertEqual(blobs[1].center.y, (0.20 + 0.16 * sin(2.3)) * 800, accuracy: 1e-6)
        XCTAssertEqual(blobs[0].radius, 0.62 * 800, accuracy: 1e-6)
        XCTAssertEqual(blobs[0].color.alpha, 0.85, accuracy: 1e-9)

        // Drift moves each blob at its own speed.
        let later = MeshGradientLayout.blobs(colors: colors, phase: 1, in: size)
        XCTAssertEqual(later[2].center.x, (0.75 + 0.16 * cos(0.85 + 2 * 1.7)) * 400, accuracy: 1e-6)
        XCTAssertEqual(later[3].center.y, (0.75 + 0.16 * sin(-1.15 * 0.9 + 3 * 2.3)) * 800, accuracy: 1e-6)
    }

    func testMotionFollowsSettings() {
        XCTAssertEqual(MeshGradientMotion.phaseChange(animated: true, reduceAnimation: false, continuous: false),
                       .settle(by: Double(Float(Double.pi * 0.45)), duration: 8))
        XCTAssertEqual(MeshGradientMotion.phaseChange(animated: true, reduceAnimation: false, continuous: true, driftDuration: 8),
                       .orbit(by: 2 * .pi, duration: 32))
        XCTAssertEqual(MeshGradientMotion.phaseChange(animated: true, reduceAnimation: true, continuous: true), .snap(to: 0))
        XCTAssertEqual(MeshGradientMotion.phaseChange(animated: false, reduceAnimation: false, continuous: false), .snap(to: 0))
        XCTAssertEqual(MeshGradientMotion.colorFade(animated: true, reduceAnimation: false), 1.4)
        XCTAssertNil(MeshGradientMotion.colorFade(animated: false, reduceAnimation: false))
        XCTAssertNil(MeshGradientMotion.colorFade(animated: true, reduceAnimation: true))
    }

    func testCrossfadeInterpolatesEachSlotThroughOklab() {
        let from = MeshGradientColors(palette: .fallback)
        let to = MeshGradientColors(palette: MeshPalette(colors: [ThemeColor(argb: 0xFF10_A040)]))
        XCTAssertEqual(MeshGradientColors.interpolate(from: from, to: to, fraction: 0), from)
        XCTAssertEqual(MeshGradientColors.interpolate(from: from, to: to, fraction: 1), to)
        let middle = MeshGradientColors.interpolate(from: from, to: to, fraction: 0.5)
        for index in 0..<4 {
            XCTAssertEqual(middle.blobs[index], ThemeColor.interpolateOklab(from: from.blobs[index], to: to.blobs[index], fraction: 0.5))
        }
        XCTAssertEqual(middle.base, ThemeColor.interpolateOklab(from: from.base, to: to.base, fraction: 0.5))
    }
}
