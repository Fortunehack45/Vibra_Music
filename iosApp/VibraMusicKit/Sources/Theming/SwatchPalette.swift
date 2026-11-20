import CoreGraphics
import Foundation

/// One colour the quantiser found, and how many (downscaled) pixels it stands
/// for — AndroidX Palette's `Palette.Swatch`.
public struct PaletteSwatch: Hashable, Sendable, CustomStringConvertible {
    /// Opaque `0xFFRRGGBB`.
    public let argb: UInt32
    public let population: Int

    public init(argb: UInt32, population: Int) {
        self.argb = argb | 0xFF00_0000
        self.population = population
    }

    public var color: ThemeColor { ThemeColor(argb: argb) }

    /// `Swatch.getHsl()`.
    public var hsl: ThemeHSL { ColorUtilsPort.rgbToHSL(argb: argb) }

    /// White or black at the lowest opacity that clears 3:1 on this swatch
    /// (`getTitleTextColor`). Where neither colour can reach it with the same
    /// lightness as the body text, the two are allowed to differ, as on Android.
    public var titleTextColor: ThemeColor { ThemeColor(argb: textColors.title) }

    /// White or black at the lowest opacity that clears 4.5:1 (`getBodyTextColor`).
    public var bodyTextColor: ThemeColor { ThemeColor(argb: textColors.body) }

    private static let minContrastTitleText: Float = 3.0
    private static let minContrastBodyText: Float = 4.5

    private var textColors: (title: UInt32, body: UInt32) {
        let white: UInt32 = 0xFFFF_FFFF
        let black: UInt32 = 0xFF00_0000
        // White first, as most swatches are dark.
        let lightBody = ColorUtilsPort.calculateMinimumAlpha(foreground: white, background: argb, minContrastRatio: Self.minContrastBodyText)
        let lightTitle = ColorUtilsPort.calculateMinimumAlpha(foreground: white, background: argb, minContrastRatio: Self.minContrastTitleText)
        if let lightBody, let lightTitle {
            return (ColorUtilsPort.setAlpha(white, lightTitle), ColorUtilsPort.setAlpha(white, lightBody))
        }
        let darkBody = ColorUtilsPort.calculateMinimumAlpha(foreground: black, background: argb, minContrastRatio: Self.minContrastBodyText)
        let darkTitle = ColorUtilsPort.calculateMinimumAlpha(foreground: black, background: argb, minContrastRatio: Self.minContrastTitleText)
        if let darkBody, let darkTitle {
            return (ColorUtilsPort.setAlpha(black, darkTitle), ColorUtilsPort.setAlpha(black, darkBody))
        }
        // Mismatched: whichever of white or black works for each on its own.
        let body = lightBody.map { ColorUtilsPort.setAlpha(white, $0) } ?? ColorUtilsPort.setAlpha(black, darkBody ?? 255)
        let title = lightTitle.map { ColorUtilsPort.setAlpha(white, $0) } ?? ColorUtilsPort.setAlpha(black, darkTitle ?? 255)
        return (title, body)
    }

    public var description: String {
        let hsl = self.hsl
        return String(format: "Swatch #%06X pop=%d hsl=(%.1f, %.3f, %.3f)", argb & 0xFF_FFFF, population, hsl.hue, hsl.saturation, hsl.lightness)
    }
}

/// A swatch the palette looks for — AndroidX Palette's `Target`: saturation and
/// lightness windows with a preferred value in each, and how much saturation,
/// lightness and population each count towards a swatch's score.
public struct PaletteTarget: Hashable, Sendable {
    public var minimumSaturation: Float = 0
    public var targetSaturation: Float = 0.5
    public var maximumSaturation: Float = 1
    public var minimumLightness: Float = 0
    public var targetLightness: Float = 0.5
    public var maximumLightness: Float = 1
    public var saturationWeight: Float = 0.24
    public var lightnessWeight: Float = 0.52
    public var populationWeight: Float = 0.24
    /// An exclusive target's pick can't be picked again by a later target.
    public var isExclusive = true

    public init() {}

    private static let targetDarkLuma: Float = 0.26
    private static let maxDarkLuma: Float = 0.45
    private static let minLightLuma: Float = 0.55
    private static let targetLightLuma: Float = 0.74
    private static let minNormalLuma: Float = 0.3
    private static let targetNormalLuma: Float = 0.5
    private static let maxNormalLuma: Float = 0.7
    private static let targetMutedSaturation: Float = 0.3
    private static let maxMutedSaturation: Float = 0.4
    private static let targetVibrantSaturation: Float = 1
    private static let minVibrantSaturation: Float = 0.35

    private func light() -> PaletteTarget {
        var t = self
        t.minimumLightness = Self.minLightLuma
        t.targetLightness = Self.targetLightLuma
        return t
    }

    private func normal() -> PaletteTarget {
        var t = self
        t.minimumLightness = Self.minNormalLuma
        t.targetLightness = Self.targetNormalLuma
        t.maximumLightness = Self.maxNormalLuma
        return t
    }

    private func dark() -> PaletteTarget {
        var t = self
        t.targetLightness = Self.targetDarkLuma
        t.maximumLightness = Self.maxDarkLuma
        return t
    }

    private func vibrant() -> PaletteTarget {
        var t = self
        t.minimumSaturation = Self.minVibrantSaturation
        t.targetSaturation = Self.targetVibrantSaturation
        return t
    }

    private func muted() -> PaletteTarget {
        var t = self
        t.targetSaturation = Self.targetMutedSaturation
        t.maximumSaturation = Self.maxMutedSaturation
        return t
    }

    public static let lightVibrant = PaletteTarget().light().vibrant()
    public static let vibrant = PaletteTarget().normal().vibrant()
    public static let darkVibrant = PaletteTarget().dark().vibrant()
    public static let lightMuted = PaletteTarget().light().muted()
    public static let muted = PaletteTarget().normal().muted()
    public static let darkMuted = PaletteTarget().dark().muted()

    /// The six a bitmap palette looks for by default, in the order they're scored —
    /// which matters, since exclusive targets take their pick before later ones look.
    public static let defaults: [PaletteTarget] = [lightVibrant, vibrant, darkVibrant, lightMuted, muted, darkMuted]

    /// `Target.normalizeWeights`: positive weights scaled to sum to 1, in single precision.
    func normalizedWeights() -> (saturation: Float, lightness: Float, population: Float) {
        var weights = [saturationWeight, lightnessWeight, populationWeight]
        var sum: Float = 0
        for weight in weights where weight > 0 {
            sum += weight
        }
        if sum != 0 {
            for i in weights.indices where weights[i] > 0 {
                weights[i] /= sum
            }
        }
        return (weights[0], weights[1], weights[2])
    }
}

/// Decides whether a colour may become a swatch — AndroidX Palette's `Palette.Filter`.
public struct PaletteFilter: Sendable {
    public let isAllowed: @Sendable (_ argb: UInt32, _ hsl: ThemeHSL) -> Bool

    public init(isAllowed: @escaping @Sendable (_ argb: UInt32, _ hsl: ThemeHSL) -> Bool) {
        self.isAllowed = isAllowed
    }

    /// Palette's `DEFAULT_FILTER`: no near-black (lightness ≤ 0.05), no
    /// near-white (≥ 0.95), and nothing close to the red side of the I line
    /// (hue 10–37° at saturation ≤ 0.82 — skin tones).
    public static let `default` = PaletteFilter { _, hsl in
        let isBlack = hsl.lightness <= 0.05
        let isWhite = hsl.lightness >= 0.95
        let isNearRedILine = hsl.hue >= 10 && hsl.hue <= 37 && hsl.saturation <= 0.82
        return !isWhite && !isBlack && !isNearRedILine
    }
}

/// AndroidX Palette, generated: every swatch the quantiser found, the dominant
/// one, and the best match for each target.
///
/// Built from ``ArtworkPixels`` the way `Palette.from(bitmap)…generate()` builds
/// one from a bitmap: downscaled (nearest-neighbour) to at most `resizeArea`
/// pixels, quantised to at most `maximumColorCount` swatches through the given
/// filters, then scored against each target in turn.
public struct ArtworkSwatchPalette: Hashable, Sendable {
    public static let defaultMaximumColorCount = 16
    public static let defaultResizeArea = 112 * 112

    /// In the quantiser's output order (which the Android callers' "first
    /// highest" picks depend on).
    public let swatches: [PaletteSwatch]
    /// The most populous swatch — the first of them on a tie.
    public let dominantSwatch: PaletteSwatch?
    public let targets: [PaletteTarget]
    private let selected: [PaletteSwatch?]

    /// - Parameters:
    ///   - maximumColorCount: `Builder.maximumColorCount` (Android default 16).
    ///   - resizeArea: `Builder.resizeBitmapArea`; the image is shrunk to about
    ///     this many pixels first. Nil or ≤ 0 disables the shrink.
    ///   - filters: `[.default]` like a fresh builder; `[]` is `clearFilters()`.
    ///   - targets: `PaletteTarget.defaults` like a bitmap builder.
    public init(
        pixels: ArtworkPixels,
        maximumColorCount: Int = defaultMaximumColorCount,
        resizeArea: Int? = defaultResizeArea,
        filters: [PaletteFilter] = [.default],
        targets: [PaletteTarget] = PaletteTarget.defaults
    ) {
        let scaled = Self.scaledDown(pixels, resizeArea: resizeArea)
        let swatches = ColorCutQuantizer.quantize(pixels: scaled.argb, maxColors: maximumColorCount, filters: filters)
        self.init(swatches: swatches, targets: targets)
    }

    /// `Palette.from(swatches)` — scoring only. Android's swatch builder starts
    /// with no targets, hence the default here.
    public init(swatches: [PaletteSwatch], targets: [PaletteTarget] = []) {
        self.swatches = swatches
        self.targets = targets

        var dominant: PaletteSwatch?
        var maxPopulation = Int.min
        for swatch in swatches where swatch.population > maxPopulation {
            dominant = swatch
            maxPopulation = swatch.population
        }
        dominantSwatch = dominant

        var used = Set<UInt32>()
        var picks = [PaletteSwatch?]()
        for target in targets {
            let pick = Self.maxScoredSwatch(swatches: swatches, target: target, dominant: dominant, used: used)
            if let pick, target.isExclusive {
                used.insert(pick.argb)
            }
            picks.append(pick)
        }
        selected = picks
    }

    public func swatch(for target: PaletteTarget) -> PaletteSwatch? {
        guard let index = targets.firstIndex(of: target) else { return nil }
        return selected[index]
    }

    public var lightVibrantSwatch: PaletteSwatch? { swatch(for: .lightVibrant) }
    public var vibrantSwatch: PaletteSwatch? { swatch(for: .vibrant) }
    public var darkVibrantSwatch: PaletteSwatch? { swatch(for: .darkVibrant) }
    public var lightMutedSwatch: PaletteSwatch? { swatch(for: .lightMuted) }
    public var mutedSwatch: PaletteSwatch? { swatch(for: .muted) }
    public var darkMutedSwatch: PaletteSwatch? { swatch(for: .darkMuted) }

    private static func maxScoredSwatch(
        swatches: [PaletteSwatch],
        target: PaletteTarget,
        dominant: PaletteSwatch?,
        used: Set<UInt32>
    ) -> PaletteSwatch? {
        let weights = target.normalizedWeights()
        let maxPopulation = Float(dominant?.population ?? 1)
        var maxScore: Float = 0
        var best: PaletteSwatch?
        for swatch in swatches {
            let hsl = swatch.hsl
            guard hsl.saturation >= target.minimumSaturation, hsl.saturation <= target.maximumSaturation,
                  hsl.lightness >= target.minimumLightness, hsl.lightness <= target.maximumLightness,
                  !used.contains(swatch.argb)
            else { continue }

            var saturationScore: Float = 0
            var lightnessScore: Float = 0
            var populationScore: Float = 0
            if weights.saturation > 0 {
                saturationScore = weights.saturation * (1 - abs(hsl.saturation - target.targetSaturation))
            }
            if weights.lightness > 0 {
                lightnessScore = weights.lightness * (1 - abs(hsl.lightness - target.targetLightness))
            }
            if weights.population > 0 {
                populationScore = weights.population * (Float(swatch.population) / maxPopulation)
            }
            let score = saturationScore + lightnessScore + populationScore
            if best == nil || score > maxScore {
                best = swatch
                maxScore = score
            }
        }
        return best
    }

    /// `Builder.scaleBitmapDown`: shrink to about `resizeArea` pixels, rounding
    /// each side up, with no filtering.
    static func scaledDown(_ pixels: ArtworkPixels, resizeArea: Int?) -> ArtworkPixels {
        guard let resizeArea, resizeArea > 0 else { return pixels }
        let area = pixels.width * pixels.height
        guard area > resizeArea else { return pixels }
        let ratio = (Double(resizeArea) / Double(area)).squareRoot()
        return pixels.scaledNearestNeighbor(
            width: Int((Double(pixels.width) * ratio).rounded(.up)),
            height: Int((Double(pixels.height) * ratio).rounded(.up))
        )
    }
}
