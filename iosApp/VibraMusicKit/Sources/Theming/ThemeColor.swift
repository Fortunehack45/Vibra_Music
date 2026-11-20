import CoreGraphics
import Foundation
import SwiftUI

/// A colour as the Android app holds one: gamma-encoded sRGB components and a
/// straight (not premultiplied) alpha, each in `0...1`.
///
/// Platform-neutral on purpose — the colour logic in this module runs off the
/// main thread and in tests on the Mac host, where neither `UIColor` nor a
/// resolved SwiftUI `Color` is a convenient value to compute with. Convert at
/// the edge with ``color`` or ``cgColor``.
///
/// Compose stores sRGB colours as 8 bits per channel, and every HSL step the
/// Android code takes goes through `androidx.core.graphics.ColorUtils` on packed
/// ARGB ints. ``argb`` and ``init(argb:)`` are the bridge to that representation,
/// with Compose's own rounding, so the ported maths lands on the same integers.
public struct ThemeColor: Hashable, Sendable, CustomStringConvertible {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// From a packed `0xAARRGGBB` value — Android's `@ColorInt`, and Compose's `Color(0xFF3A1C71)`.
    public init(argb: UInt32) {
        self.init(
            red: Double((argb >> 16) & 0xFF) / 255,
            green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255,
            alpha: Double(argb >> 24) / 255
        )
    }

    /// From 8-bit channels, as Compose's `Color(red: Int, green: Int, blue: Int)`.
    public init(red8: Int, green8: Int, blue8: Int, alpha8: Int = 255) {
        self.init(argb: packARGB(alpha: alpha8, red: red8, green: green8, blue: blue8))
    }

    /// Packed `0xAARRGGBB`, rounded the way Compose's `Color.toArgb()` rounds
    /// (`(component * 255 + 0.5).toInt()`, after clamping).
    public var argb: UInt32 {
        packARGB(
            alpha: Self.channel8(alpha),
            red: Self.channel8(red),
            green: Self.channel8(green),
            blue: Self.channel8(blue)
        )
    }

    /// The same colour at a different opacity — Compose's `copy(alpha = …)`.
    public func withAlpha(_ alpha: Double) -> ThemeColor {
        ThemeColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public static let black = ThemeColor(argb: 0xFF00_0000)
    public static let white = ThemeColor(argb: 0xFFFF_FFFF)
    public static let clear = ThemeColor(argb: 0x0000_0000)

    /// A SwiftUI colour in the sRGB colour space.
    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    /// A Core Graphics colour in the sRGB colour space.
    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// Hue, saturation and lightness exactly as `ColorUtils.colorToHSL` computes
    /// them (single precision, from the 8-bit channels).
    public var hsl: ThemeHSL {
        ColorUtilsPort.rgbToHSL(argb: argb)
    }

    /// An opaque colour from HSL, exactly as `ColorUtils.HSLToColor` builds it.
    public init(hsl: ThemeHSL) {
        self.init(argb: ColorUtilsPort.hslToARGB(hsl))
    }

    /// Relative luminance per `ColorUtils.calculateLuminance` (WCAG, 0 for black, 1 for white).
    /// Alpha is ignored, as it is there.
    public var luminance: Double {
        ColorUtilsPort.calculateLuminance(argb: argb)
    }

    /// WCAG contrast ratio of `self` drawn over an opaque `background`
    /// (`ColorUtils.calculateContrast`); a translucent foreground is composited first.
    public func contrastRatio(over background: ThemeColor) -> Double {
        ColorUtilsPort.calculateContrast(foreground: argb, background: background.withAlpha(1).argb)
    }

    /// Straight linear interpolation of the gamma-encoded channels.
    ///
    /// This is what drawing `other` over `self` at opacity `fraction` produces
    /// for opaque colours, so it is the right blend for layer crossfades (see
    /// ``ArtworkMeshCrossfade``). Animated colour *values* use ``interpolateOklab(from:to:fraction:)``.
    public func mixed(with other: ThemeColor, fraction: Double) -> ThemeColor {
        let t = min(max(fraction, 0), 1)
        return ThemeColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t,
            alpha: alpha + (other.alpha - alpha) * t
        )
    }

    public var description: String {
        String(format: "#%08X", argb)
    }

    static func channel8(_ component: Double) -> Int {
        Int(min(max(component, 0), 1) * 255 + 0.5)
    }
}

/// HSL in `ColorUtils`' convention: hue in degrees `0...360`, saturation and
/// lightness in `0...1`, single precision like the `FloatArray(3)` it replaces.
public struct ThemeHSL: Hashable, Sendable {
    public var hue: Float
    public var saturation: Float
    public var lightness: Float

    public init(hue: Float, saturation: Float, lightness: Float) {
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
    }
}

/// One stop of a vertical scrim or wash: a colour at a fraction of the height
/// (0 = top). The views build a SwiftUI `LinearGradient` from these.
public struct ThemeGradientStop: Hashable, Sendable {
    public var location: Double
    public var color: ThemeColor

    public init(location: Double, color: ThemeColor) {
        self.location = location
        self.color = color
    }

    public var gradientStop: Gradient.Stop {
        Gradient.Stop(color: color.color, location: location)
    }
}

// MARK: - Oklab

extension ThemeColor {
    /// Interpolates the way Compose's `animateColorAsState` does: through Oklab,
    /// with alpha interpolated separately and not premultiplied.
    ///
    /// A straight sRGB lerp between two saturated colours dips through a muddy
    /// grey halfway; the Android crossfades never showed that, so neither should
    /// these. L is clamped to `0...1` and a/b to `-0.5...0.5` on the way back, as
    /// `Color.VectorConverter` clamps them.
    public static func interpolateOklab(from: ThemeColor, to: ThemeColor, fraction: Double) -> ThemeColor {
        if fraction <= 0 { return from }
        if fraction >= 1 { return to }
        let a = Oklab(from)
        let b = Oklab(to)
        let t = fraction
        let mixed = Oklab(
            l: min(max(a.l + (b.l - a.l) * t, 0), 1),
            a: min(max(a.a + (b.a - a.a) * t, -0.5), 0.5),
            b: min(max(a.b + (b.b - a.b) * t, -0.5), 0.5)
        )
        let alpha = min(max(from.alpha + (to.alpha - from.alpha) * t, 0), 1)
        return mixed.color(alpha: alpha)
    }
}

/// Björn Ottosson's Oklab, from linear sRGB.
struct Oklab: Equatable {
    var l: Double
    var a: Double
    var b: Double

    init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }

    init(_ color: ThemeColor) {
        let r = srgbToLinear(color.red)
        let g = srgbToLinear(color.green)
        let bl = srgbToLinear(color.blue)
        let lms0 = cbrt(0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * bl)
        let lms1 = cbrt(0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * bl)
        let lms2 = cbrt(0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * bl)
        l = 0.210_454_255_3 * lms0 + 0.793_617_785_0 * lms1 - 0.004_072_046_8 * lms2
        a = 1.977_998_495_1 * lms0 - 2.428_592_205_0 * lms1 + 0.450_593_709_9 * lms2
        b = 0.025_904_037_1 * lms0 + 0.782_771_766_2 * lms1 - 0.808_675_766_0 * lms2
    }

    func color(alpha: Double) -> ThemeColor {
        let lms0 = l + 0.396_337_777_4 * a + 0.215_803_757_3 * b
        let lms1 = l - 0.105_561_345_8 * a - 0.063_854_172_8 * b
        let lms2 = l - 0.089_484_177_5 * a - 1.291_485_548_0 * b
        let l3 = lms0 * lms0 * lms0
        let m3 = lms1 * lms1 * lms1
        let s3 = lms2 * lms2 * lms2
        let r = 4.076_741_662_1 * l3 - 3.307_711_591_3 * m3 + 0.230_969_929_2 * s3
        let g = -1.268_438_004_6 * l3 + 2.609_757_401_1 * m3 - 0.341_319_396_5 * s3
        let b = -0.004_196_086_3 * l3 - 0.703_418_614_7 * m3 + 1.707_614_701_0 * s3
        return ThemeColor(
            red: linearToSRGB(min(max(r, 0), 1)),
            green: linearToSRGB(min(max(g, 0), 1)),
            blue: linearToSRGB(min(max(b, 0), 1)),
            alpha: alpha
        )
    }
}

func srgbToLinear(_ value: Double) -> Double {
    value <= 0.040_45 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
}

func linearToSRGB(_ value: Double) -> Double {
    value <= 0.003_130_8 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
}

// MARK: - Packed ARGB helpers

@inline(__always)
func packARGB(alpha: Int, red: Int, green: Int, blue: Int) -> UInt32 {
    (UInt32(alpha & 0xFF) << 24) | (UInt32(red & 0xFF) << 16) | (UInt32(green & 0xFF) << 8) | UInt32(blue & 0xFF)
}

/// `android.graphics.Color.rgb` — opaque.
@inline(__always)
func opaqueARGB(red: Int, green: Int, blue: Int) -> UInt32 {
    packARGB(alpha: 0xFF, red: red, green: green, blue: blue)
}

@inline(__always) func alphaOf(_ argb: UInt32) -> Int { Int(argb >> 24) }
@inline(__always) func redOf(_ argb: UInt32) -> Int { Int((argb >> 16) & 0xFF) }
@inline(__always) func greenOf(_ argb: UInt32) -> Int { Int((argb >> 8) & 0xFF) }
@inline(__always) func blueOf(_ argb: UInt32) -> Int { Int(argb & 0xFF) }
