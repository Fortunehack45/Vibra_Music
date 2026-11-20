import Foundation

/// The parts of `androidx.core.graphics.ColorUtils` the Android colour code leans
/// on, ported line for line.
///
/// Kept bit-faithful rather than "equivalent": HSL is computed in single
/// precision from 8-bit channels and rounded back with Java's `Math.round`, so a
/// swatch that lands on a given integer colour on Android lands on the same one
/// here. The palette maths downstream (saturation floors, lightness bands, the
/// quantiser's filters) all sits on these values.
enum ColorUtilsPort {
    // MARK: HSL

    /// `ColorUtils.RGBToHSL`.
    static func rgbToHSL(red r: Int, green g: Int, blue b: Int) -> ThemeHSL {
        let rf = Float(r) / 255
        let gf = Float(g) / 255
        let bf = Float(b) / 255

        let maxC = max(rf, max(gf, bf))
        let minC = min(rf, min(gf, bf))
        let deltaMaxMin = maxC - minC

        var h: Float
        let s: Float
        let l = (maxC + minC) / 2

        if maxC == minC {
            // Monochromatic
            h = 0
            s = 0
        } else {
            if maxC == rf {
                h = ((gf - bf) / deltaMaxMin).truncatingRemainder(dividingBy: 6)
            } else if maxC == gf {
                h = ((bf - rf) / deltaMaxMin) + 2
            } else {
                h = ((rf - gf) / deltaMaxMin) + 4
            }
            s = deltaMaxMin / (1 - abs(2 * l - 1))
        }

        h = (h * 60).truncatingRemainder(dividingBy: 360)
        if h < 0 {
            h += 360
        }
        return ThemeHSL(
            hue: constrain(h, 0, 360),
            saturation: constrain(s, 0, 1),
            lightness: constrain(l, 0, 1)
        )
    }

    /// `ColorUtils.colorToHSL` (alpha ignored).
    static func rgbToHSL(argb: UInt32) -> ThemeHSL {
        rgbToHSL(red: redOf(argb), green: greenOf(argb), blue: blueOf(argb))
    }

    /// `ColorUtils.HSLToColor` — always opaque. A hue whose segment isn't 0…6
    /// falls through every case of the Java switch and comes out black, as it
    /// does there.
    static func hslToARGB(_ hsl: ThemeHSL) -> UInt32 {
        let h = hsl.hue
        let s = hsl.saturation
        let l = hsl.lightness

        let c = (1 - abs(2 * l - 1)) * s
        let m = l - 0.5 * c
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))

        // Java: `(int) h / 60` — the cast binds first, then integer division.
        // Java's float-to-int cast saturates and maps NaN to 0; Swift's traps.
        let hueSegment = h.isNaN ? 0 : Int(constrain(h, -1e9, 1e9)) / 60

        var r = 0
        var g = 0
        var b = 0
        switch hueSegment {
        case 0:
            r = javaRound(255 * (c + m)); g = javaRound(255 * (x + m)); b = javaRound(255 * m)
        case 1:
            r = javaRound(255 * (x + m)); g = javaRound(255 * (c + m)); b = javaRound(255 * m)
        case 2:
            r = javaRound(255 * m); g = javaRound(255 * (c + m)); b = javaRound(255 * (x + m))
        case 3:
            r = javaRound(255 * m); g = javaRound(255 * (x + m)); b = javaRound(255 * (c + m))
        case 4:
            r = javaRound(255 * (x + m)); g = javaRound(255 * m); b = javaRound(255 * (c + m))
        case 5, 6:
            r = javaRound(255 * (c + m)); g = javaRound(255 * m); b = javaRound(255 * (x + m))
        default:
            break
        }
        return opaqueARGB(red: constrain(r, 0, 255), green: constrain(g, 0, 255), blue: constrain(b, 0, 255))
    }

    // MARK: Luminance and contrast

    /// `ColorUtils.calculateLuminance`: the Y of `RGBToXYZ`, over 100.
    static func calculateLuminance(argb: UInt32) -> Double {
        func linear(_ channel: Int) -> Double {
            let s = Double(channel) / 255.0
            return s < 0.040_45 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let y = 100 * (linear(redOf(argb)) * 0.2126 + linear(greenOf(argb)) * 0.7152 + linear(blueOf(argb)) * 0.0722)
        return y / 100
    }

    /// `ColorUtils.compositeColors`.
    static func compositeColors(foreground: UInt32, background: UInt32) -> UInt32 {
        let bgAlpha = alphaOf(background)
        let fgAlpha = alphaOf(foreground)
        let a = 0xFF - (((0xFF - bgAlpha) * (0xFF - fgAlpha)) / 0xFF)
        func component(_ fgC: Int, _ bgC: Int) -> Int {
            if a == 0 { return 0 }
            return ((0xFF * fgC * fgAlpha) + (bgC * bgAlpha * (0xFF - fgAlpha))) / (a * 0xFF)
        }
        return packARGB(
            alpha: a,
            red: component(redOf(foreground), redOf(background)),
            green: component(greenOf(foreground), greenOf(background)),
            blue: component(blueOf(foreground), blueOf(background))
        )
    }

    /// `ColorUtils.calculateContrast`. The background must be opaque (Android throws otherwise).
    static func calculateContrast(foreground: UInt32, background: UInt32) -> Double {
        precondition(alphaOf(background) == 255, "background can not be translucent")
        var fg = foreground
        if alphaOf(fg) < 255 {
            fg = compositeColors(foreground: fg, background: background)
        }
        let luminance1 = calculateLuminance(argb: fg) + 0.05
        let luminance2 = calculateLuminance(argb: background) + 0.05
        return max(luminance1, luminance2) / min(luminance1, luminance2)
    }

    /// `ColorUtils.calculateMinimumAlpha`: the lowest alpha at which `foreground`
    /// over `background` reaches `minContrastRatio`, or nil (Android's -1) when
    /// even an opaque foreground doesn't.
    static func calculateMinimumAlpha(foreground: UInt32, background: UInt32, minContrastRatio: Float) -> Int? {
        precondition(alphaOf(background) == 255, "background can not be translucent")
        let minRatio = Double(minContrastRatio)
        if calculateContrast(foreground: setAlpha(foreground, 255), background: background) < minRatio {
            return nil
        }
        var numIterations = 0
        var minAlpha = 0
        var maxAlpha = 255
        while numIterations <= 10 && (maxAlpha - minAlpha) > 1 {
            let testAlpha = (minAlpha + maxAlpha) / 2
            if calculateContrast(foreground: setAlpha(foreground, testAlpha), background: background) < minRatio {
                minAlpha = testAlpha
            } else {
                maxAlpha = testAlpha
            }
            numIterations += 1
        }
        // Conservatively the top of the range, which is known to pass.
        return maxAlpha
    }

    /// `ColorUtils.setAlphaComponent`.
    static func setAlpha(_ argb: UInt32, _ alpha: Int) -> UInt32 {
        (argb & 0x00FF_FFFF) | (UInt32(alpha & 0xFF) << 24)
    }
}

// MARK: - Java arithmetic

/// Java's `Math.round(float)`: round half up (towards positive infinity),
/// exactly; NaN is 0 and out-of-range values saturate, where Swift would trap.
@inline(__always)
func javaRound(_ value: Float) -> Int {
    if value.isNaN { return 0 }
    let floorValue = value.rounded(.down)
    let rounded = value - floorValue >= 0.5 ? floorValue + 1 : floorValue
    return Int(constrain(rounded, Float(Int32.min), Float(Int32.max)))
}

@inline(__always)
func constrain<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T {
    value < low ? low : (value > high ? high : value)
}

extension ThemeColor {
    /// The Kotlin `Color.withHsl` helper the artwork palette and mesh share:
    /// read HSL off the 8-bit colour, adjust, rebuild through `HSLToColor`.
    func withHSL(
        saturation: (Float) -> Float = { $0 },
        lightness: (Float) -> Float = { $0 }
    ) -> ThemeColor {
        var hsl = self.hsl
        hsl.saturation = constrain(saturation(hsl.saturation), 0, 1)
        hsl.lightness = constrain(lightness(hsl.lightness), 0, 1)
        return ThemeColor(hsl: hsl)
    }
}
