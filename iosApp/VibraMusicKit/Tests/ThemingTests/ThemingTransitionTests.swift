import SwiftUI
import XCTest
@testable import Theming

/// Colour interpolation (Oklab, as Compose animates colours) and the easing and
/// retargeting behaviour of `animate*AsState`.
final class ThemingTransitionTests: XCTestCase {
    func testOklabRoundTripsSRGB() {
        for value in [0xFF00_0000, 0xFFFF_FFFF, 0xFFFA_2D48, 0xFF3A_1C71, 0xFF12_1212, 0xFF00_FF00] as [UInt32] {
            let color = ThemeColor(argb: value)
            assertColor(Oklab(color).color(alpha: 1), value)
        }
    }

    func testBlackToWhiteMidpointIsPerceptualGrey() {
        let middle = ThemeColor.interpolateOklab(from: .black, to: .white, fraction: 0.5)
        // Oklab L 0.5 is linear 0.125, sRGB ≈ 0.3885 — not the sRGB midpoint 0.5.
        XCTAssertEqual(middle.red, 0.3885, accuracy: 0.002)
        XCTAssertEqual(middle.red, middle.green, accuracy: 1e-6)
        XCTAssertEqual(middle.green, middle.blue, accuracy: 1e-6)
    }

    func testSaturatedCrossfadeDoesNotGoMuddy() {
        let red = ThemeColor(argb: 0xFFFF_0000)
        let blue = ThemeColor(argb: 0xFF00_00FF)
        let oklab = ThemeColor.interpolateOklab(from: red, to: blue, fraction: 0.5)
        let straight = red.mixed(with: blue, fraction: 0.5)
        // The Oklab midpoint is lighter than the dull sRGB-lerp purple.
        XCTAssertGreaterThan(oklab.luminance, straight.luminance)
        XCTAssertEqual(ThemeColor.interpolateOklab(from: red, to: blue, fraction: 0), red)
        XCTAssertEqual(ThemeColor.interpolateOklab(from: red, to: blue, fraction: 1), blue)
        // Alpha is interpolated on its own.
        let fading = ThemeColor.interpolateOklab(from: red, to: red.withAlpha(0), fraction: 0.25)
        XCTAssertEqual(fading.alpha, 0.75, accuracy: 1e-9)
        assertColor(fading.withAlpha(1), 0xFFFF_0000)
    }

    func testStraightMixIsLayerCompositing() {
        let mixed = ThemeColor(argb: argb(0, 0, 0)).mixed(with: ThemeColor(argb: argb(200, 100, 50)), fraction: 0.25)
        assertColor(mixed, argb(50, 25, 13))
        XCTAssertEqual(ThemeColor.black.mixed(with: .white, fraction: 3), .white)
    }

    func testFastOutSlowInMatchesTheCurve() {
        XCTAssertEqual(ThemingMotion.fastOutSlowIn(0), 0)
        XCTAssertEqual(ThemingMotion.fastOutSlowIn(1), 1)
        // The Bézier's own midpoint: x(½) = 0.35, y(½) = 0.5.
        XCTAssertEqual(ThemingMotion.fastOutSlowIn(0.35), 0.5, accuracy: 1e-6)
        var previous = 0.0
        for step in 1...100 {
            let value = ThemingMotion.fastOutSlowIn(Double(step) / 100)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
        // Outside 0…1 the fraction passes through, as Compose's does.
        XCTAssertEqual(ThemingMotion.fastOutSlowIn(1.5), 1.5)
        XCTAssertEqual(ThemingMotion.cubicBezier(x1: 0, y1: 0, x2: 1, y2: 1, at: 0.3), 0.3, accuracy: 1e-6)
    }

    func testTransitionEasesAndRetargetsFromWhereItIs() {
        var transition = ThemingTransition(value: ThemeColor.black)
        XCTAssertEqual(transition.value(at: 0), .black)

        transition.retarget(to: .white, at: 10, duration: 1)
        XCTAssertEqual(transition.value(at: 10), .black)
        XCTAssertEqual(transition.value(at: 10.35).argb, ThemeColor.interpolateOklab(from: .black, to: .white, fraction: 0.5).argb)
        XCTAssertFalse(transition.isSettled(at: 10.5))

        // A new target mid-flight starts from the current value, for a full duration.
        let midway = transition.value(at: 10.5)
        let red = ThemeColor(argb: 0xFFFF_0000)
        transition.retarget(to: red, at: 10.5, duration: 1)
        XCTAssertEqual(transition.from, midway)
        XCTAssertEqual(transition.value(at: 10.5), midway)
        XCTAssertEqual(transition.value(at: 11.5), red)
        XCTAssertTrue(transition.isSettled(at: 11.5))

        // The same target again doesn't restart it.
        transition.retarget(to: .white, at: 20, duration: 1)
        transition.retarget(to: .white, at: 20.5, duration: 1)
        XCTAssertEqual(transition.startTime, 20)

        // Nil duration is a snap.
        transition.retarget(to: .black, at: 20.6, duration: nil)
        XCTAssertEqual(transition.value(at: 20.6), .black)
        XCTAssertTrue(transition.isSettled(at: 20.6))
    }

    func testTransitionWorksForWholePalettes() {
        let from = MeshGradientColors(palette: .fallback)
        let to = MeshGradientColors(palette: MeshPalette(colors: [ThemeColor(argb: 0xFF10_A040)]))
        var transition = ThemingTransition(value: from)
        transition.retarget(to: to, at: 0, duration: MeshGradientMotion.colorFadeDuration)
        XCTAssertEqual(transition.value(at: 0.7), MeshGradientColors.interpolate(from: from, to: to, fraction: ThemingMotion.fastOutSlowIn(0.5)))
        XCTAssertEqual(transition.value(at: 1.4), to)
    }
}

/// `Theme.kt`: the two schemes, the Theme setting, and the type scale.
final class ThemeColorSchemeTests: XCTestCase {
    func testSchemesMatchAndroid() {
        XCTAssertEqual(ThemeColorScheme.dark.background, .black)
        XCTAssertEqual(ThemeColorScheme.dark.surface.argb, 0xFF0D_0D0F)
        XCTAssertEqual(ThemeColorScheme.dark.surfaceVariant.argb, 0xFF1C_1C1E)
        XCTAssertEqual(ThemeColorScheme.dark.onSurfaceVariant.argb, 0xFF8E_8E93)
        XCTAssertEqual(ThemeColorScheme.dark.outline.argb, 0xFF2C_2C2E)
        XCTAssertEqual(ThemeColorScheme.light.background, .white)
        XCTAssertEqual(ThemeColorScheme.light.surface.argb, 0xFFF7_F7F9)
        XCTAssertEqual(ThemeColorScheme.light.surfaceVariant.argb, 0xFFF2_F2F7)
        XCTAssertEqual(ThemeColorScheme.light.onSurfaceVariant.argb, 0xFF6E_6E73)
        XCTAssertEqual(ThemeColorScheme.light.outline.argb, 0xFFE5_E5EA)
        XCTAssertEqual(ThemeColorScheme.accentRed.argb, 0xFFFA_2D48)
    }

    func testDarknessIsReadOffTheBackground() {
        XCTAssertTrue(ThemeColorScheme.dark.isDark)
        XCTAssertFalse(ThemeColorScheme.light.isDark)
        XCTAssertEqual(ThemeColorScheme.forDarkTheme(true), .dark)
        XCTAssertEqual(ThemeColorScheme.dark.colorScheme, .dark)
        var custom = ThemeColorScheme.light
        custom.background = ThemeColor(argb: 0xFF33_3333)
        XCTAssertTrue(custom.isDark)
    }

    func testThemeSetting() {
        XCTAssertEqual(ThemeAppearance.defaultValue, .dark)
        XCTAssertEqual(ThemeAppearance(rawValue: "SYSTEM"), .system)
        XCTAssertTrue(ThemeAppearance.system.isDark(systemIsDark: true))
        XCTAssertFalse(ThemeAppearance.system.isDark(systemIsDark: false))
        XCTAssertFalse(ThemeAppearance.light.isDark(systemIsDark: true))
        XCTAssertTrue(ThemeAppearance.dark.isDark(systemIsDark: false))
        XCTAssertNil(ThemeAppearance.system.preferredColorScheme)
        XCTAssertEqual(ThemeAppearance.light.preferredColorScheme, .light)
    }

    func testTypeScaleIsHeavyAndTight() {
        XCTAssertEqual(ThemeTextStyle.displayLarge.size, 34)
        XCTAssertEqual(ThemeTextStyle.displayLarge.weight, .heavy)
        XCTAssertEqual(ThemeTextStyle.displayLarge.tracking, -0.8)
        XCTAssertEqual(ThemeTextStyle.headlineMedium.weight, .bold)
        XCTAssertEqual(ThemeTextStyle.labelSmall.size, 11)
        XCTAssertEqual(ThemeTextStyle.bodyMedium.tracking, 0)
    }
}
