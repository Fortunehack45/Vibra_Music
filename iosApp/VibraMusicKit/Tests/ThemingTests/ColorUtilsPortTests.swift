import XCTest
@testable import Theming

/// `ColorUtils` and `ThemeColor` behave like the Android originals.
final class ColorUtilsPortTests: XCTestCase {
    func testRGBToHSLMatchesTheFormula() {
        // #3A1C71, the first stock mesh colour: blue is the max channel.
        let hsl = ColorUtilsPort.rgbToHSL(red: 58, green: 28, blue: 113)
        XCTAssertEqual(hsl.hue, 261.18, accuracy: 0.01)
        XCTAssertEqual(hsl.saturation, 0.6028, accuracy: 0.0005)
        XCTAssertEqual(hsl.lightness, 0.2765, accuracy: 0.0005)

        // Red max with green < blue: the `% 6` goes negative and wraps to 345°.
        XCTAssertEqual(ColorUtilsPort.rgbToHSL(red: 240, green: 200, blue: 210).hue, 345, accuracy: 0.01)
        // Greys are hue 0, saturation 0.
        let grey = ColorUtilsPort.rgbToHSL(red: 128, green: 128, blue: 128)
        XCTAssertEqual(grey.hue, 0)
        XCTAssertEqual(grey.saturation, 0)
        XCTAssertEqual(grey.lightness, 128.0 / 255.0, accuracy: 1e-6)
    }

    func testHSLToColorCoversEverySegment() {
        XCTAssertEqual(ColorUtilsPort.hslToARGB(ThemeHSL(hue: 0, saturation: 1, lightness: 0.5)), 0xFFFF_0000)
        XCTAssertEqual(ColorUtilsPort.hslToARGB(ThemeHSL(hue: 60, saturation: 1, lightness: 0.5)), 0xFFFF_FF00)
        XCTAssertEqual(ColorUtilsPort.hslToARGB(ThemeHSL(hue: 120, saturation: 1, lightness: 0.5)), 0xFF00_FF00)
        XCTAssertEqual(ColorUtilsPort.hslToARGB(ThemeHSL(hue: 180, saturation: 1, lightness: 0.5)), 0xFF00_FFFF)
        XCTAssertEqual(ColorUtilsPort.hslToARGB(ThemeHSL(hue: 240, saturation: 1, lightness: 0.5)), 0xFF00_00FF)
        XCTAssertEqual(ColorUtilsPort.hslToARGB(ThemeHSL(hue: 300, saturation: 1, lightness: 0.5)), 0xFFFF_00FF)
        XCTAssertEqual(ColorUtilsPort.hslToARGB(ThemeHSL(hue: 360, saturation: 1, lightness: 0.5)), 0xFFFF_0000)
        // Lightness alone, rounded half up: 0.045 * 255 = 11.475 → 11; 0.5 * 255 = 127.5 → 128.
        XCTAssertEqual(ColorUtilsPort.hslToARGB(ThemeHSL(hue: 0, saturation: 0, lightness: 0.045)), 0xFF0B_0B0B)
        XCTAssertEqual(ColorUtilsPort.hslToARGB(ThemeHSL(hue: 0, saturation: 0, lightness: 0.5)), 0xFF80_8080)
        // A hue whose segment is past 6 falls through the Java switch: black.
        XCTAssertEqual(ColorUtilsPort.hslToARGB(ThemeHSL(hue: 450, saturation: 1, lightness: 0.5)), 0xFF00_0000)
        // NaN hue: segment 0, and Java rounds the NaN channel to 0 rather than trapping.
        XCTAssertEqual(ColorUtilsPort.hslToARGB(ThemeHSL(hue: .nan, saturation: 0, lightness: 0.5)), 0xFF80_0080)
    }

    func testHSLRoundTripsQuantisedColours() {
        // Palette swatches are always multiples of 8; they survive a round trip.
        for r in stride(from: 0, through: 248, by: 24) {
            for g in stride(from: 0, through: 248, by: 40) {
                for b in stride(from: 0, through: 248, by: 56) {
                    let color = argb(r, g, b)
                    let back = ColorUtilsPort.hslToARGB(ColorUtilsPort.rgbToHSL(argb: color))
                    assertColor(ThemeColor(argb: back), color, tolerance: 1)
                }
            }
        }
    }

    func testJavaRoundIsHalfUp() {
        XCTAssertEqual(javaRound(0.5), 1)
        XCTAssertEqual(javaRound(1.5), 2)
        XCTAssertEqual(javaRound(2.4999), 2)
        XCTAssertEqual(javaRound(-0.5), 0)
        XCTAssertEqual(javaRound(-1.5), -1)
        XCTAssertEqual(javaRound(23.5), 24)
    }

    func testLuminanceAndContrast() {
        XCTAssertEqual(ThemeColor.white.luminance, 1, accuracy: 1e-9)
        XCTAssertEqual(ThemeColor.black.luminance, 0, accuracy: 1e-9)
        XCTAssertEqual(ThemeColor.white.contrastRatio(over: .black), 21, accuracy: 1e-9)
        XCTAssertEqual(ThemeColor.black.contrastRatio(over: .white), 21, accuracy: 1e-9)
        // A translucent foreground is composited first: 50% white on black is ~#808080.
        let half = ThemeColor.white.withAlpha(0.5)
        let composited = ColorUtilsPort.compositeColors(foreground: half.argb, background: 0xFF00_0000)
        XCTAssertEqual(composited, 0xFF80_8080)
    }

    func testMinimumAlphaIsTheLowestPassingValue() {
        for background in [argb(20, 20, 20), argb(60, 90, 160), argb(100, 100, 100)] {
            let alpha = try? XCTUnwrap(ColorUtilsPort.calculateMinimumAlpha(foreground: 0xFFFF_FFFF, background: background, minContrastRatio: 4.5))
            guard let alpha else { return XCTFail("white should reach 4.5:1 on \(String(format: "%08X", background))") }
            let passing = ColorUtilsPort.calculateContrast(foreground: ColorUtilsPort.setAlpha(0xFFFF_FFFF, alpha), background: background)
            XCTAssertGreaterThanOrEqual(passing, 4.5)
            let below = ColorUtilsPort.calculateContrast(foreground: ColorUtilsPort.setAlpha(0xFFFF_FFFF, alpha - 1), background: background)
            XCTAssertLessThan(below, 4.5, "search should stop within one step")
        }
        // White can't reach 4.5:1 on mid grey, or on white, at all.
        XCTAssertNil(ColorUtilsPort.calculateMinimumAlpha(foreground: 0xFFFF_FFFF, background: argb(128, 128, 128), minContrastRatio: 4.5))
        XCTAssertNil(ColorUtilsPort.calculateMinimumAlpha(foreground: 0xFFFF_FFFF, background: 0xFFFF_FFFF, minContrastRatio: 4.5))
    }

    func testThemeColorArgbBridge() {
        let color = ThemeColor(argb: 0x80FA_2D48)
        XCTAssertEqual(color.red, 250.0 / 255.0, accuracy: 1e-12)
        XCTAssertEqual(color.alpha, 128.0 / 255.0, accuracy: 1e-12)
        XCTAssertEqual(color.argb, 0x80FA_2D48)
        // Compose's rounding: 0.7 * 255 + 0.5 = 179.0 → 179; 0.12 → 31.
        XCTAssertEqual(ThemeColor.black.withAlpha(0.70).argb >> 24, 179)
        XCTAssertEqual(ThemeColor.white.withAlpha(0.12).argb >> 24, 31)
        // Out-of-range components clamp.
        XCTAssertEqual(ThemeColor(red: 2, green: -1, blue: 0.5).argb, 0xFFFF_0080)
        XCTAssertEqual(ThemeColor(red8: 1, green8: 2, blue8: 3).argb, 0xFF01_0203)
        XCTAssertEqual(String(describing: ThemeColor(argb: 0xFF12_1212)), "#FF121212")
    }

    func testWithHSLAdjustsThroughColorUtils() {
        let color = ThemeColor(argb: 0xFFE0_4020)
        let deep = color.withHSL(lightness: { _ in 0.13 })
        XCTAssertEqual(deep.hsl.lightness, 0.13, accuracy: 0.003)
        XCTAssertEqual(deep.hsl.hue, color.hsl.hue, accuracy: 2)
        let greyed = color.withHSL(saturation: { _ in 0 })
        XCTAssertTrue(greyed.isNeutral)
    }
}
