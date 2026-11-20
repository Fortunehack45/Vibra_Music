import CoreGraphics
import Foundation

/// The colours an album, playlist or artist page paints itself in.
///
/// Apple Music's release pages are not one design tinted five ways — the whole
/// page is derived from the sleeve, down to which grey the metadata line is. So
/// rather than hand callers a raw swatch and let each of them guess, this is the
/// finished set: a page tint, an accent that is legible *on that tint*, and the
/// two text colours and hairline that go with them.
///
/// Every value is theme-aware. The same sleeve yields a near-black tint in dark
/// mode and a pale wash of the same hue in light mode, which is the only way the
/// pages stay readable when the app's theme disagrees with the artwork's.
///
/// Get one from ``ArtworkSeed/palette(dark:)``, or ``untinted(_:)`` while the
/// artwork hasn't been read.
public struct ArtworkPalette: Hashable, Sendable {
    /// The page's background wash.
    public var background: ThemeColor
    /// The colour the artwork's own bottom edge blurs down to.
    ///
    /// A blur wide enough to lose the picture leaves the mean of what it
    /// sampled, so a page that starts from this colour where the artwork stops
    /// reads as that blur carrying on rather than as a second surface beginning.
    /// Lighter than ``background``, which the page still settles into further
    /// down — the artwork's colour is strongest right under the artwork.
    public var wash: ThemeColor
    /// Fill for the glass buttons and chips that sit on ``background``.
    public var elevated: ThemeColor
    /// The artwork's own colour, contrast-corrected — titles, icons, Play.
    public var accent: ThemeColor
    public var onBackground: ThemeColor
    public var onBackgroundVariant: ThemeColor
    public var divider: ThemeColor

    public init(
        background: ThemeColor,
        wash: ThemeColor,
        elevated: ThemeColor,
        accent: ThemeColor,
        onBackground: ThemeColor,
        onBackgroundVariant: ThemeColor,
        divider: ThemeColor
    ) {
        self.background = background
        self.wash = wash
        self.elevated = elevated
        self.accent = accent
        self.onBackground = onBackground
        self.onBackgroundVariant = onBackgroundVariant
        self.divider = divider
    }

    /// The theme's own colours, for a page whose artwork hasn't been read (or
    /// has none). A sleeve seen for the first time starts here and warms into
    /// its tint, so it never flashes a placeholder colour.
    public static func untinted(_ scheme: ThemeColorScheme) -> ArtworkPalette {
        ArtworkPalette(
            background: scheme.background,
            wash: scheme.background,
            elevated: scheme.surfaceVariant,
            accent: scheme.primary,
            onBackground: scheme.onBackground,
            onBackgroundVariant: scheme.onSurfaceVariant,
            divider: scheme.outline
        )
    }

    /// Short: this is a surface settling into its colour, not an effect in itself.
    public static let tintFadeDuration: TimeInterval = 0.26

    /// How a page moves to a new tint: nil for a cut, else a fade of this length
    /// on ``ThemingMotion/fastOutSlowIn``.
    ///
    /// Colours that were there from the first frame (`knownUpFront` — the seed
    /// was already cached when the page asked) have nothing to crossfade *from*;
    /// animating would only put a delay in front of a surface that could already
    /// be right. "Reduce animation" turns every fade into a cut.
    public static func tintFade(reduceAnimation: Bool, knownUpFront: Bool) -> TimeInterval? {
        reduceAnimation || knownUpFront ? nil : tintFadeDuration
    }
}

extension ArtworkPalette: ThemingInterpolatable {
    /// Every colour crossfades on its own through Oklab, as seven
    /// `animateColorAsState`s do on Android.
    public static func interpolate(from: ArtworkPalette, to: ArtworkPalette, fraction: Double) -> ArtworkPalette {
        func mix(_ keyPath: KeyPath<ArtworkPalette, ThemeColor>) -> ThemeColor {
            ThemeColor.interpolateOklab(from: from[keyPath: keyPath], to: to[keyPath: keyPath], fraction: fraction)
        }
        return ArtworkPalette(
            background: mix(\.background),
            wash: mix(\.wash),
            elevated: mix(\.elevated),
            accent: mix(\.accent),
            onBackground: mix(\.onBackground),
            onBackgroundVariant: mix(\.onBackgroundVariant),
            divider: mix(\.divider)
        )
    }
}

/// The raw artwork colours a page tint is derived from: what the sleeve is
/// mostly made of, its brightest note, and what its bottom edge averages out to
/// — plus how bright the band under the status bar is.
///
/// This is what gets cached per artwork URL (``ArtworkPaletteCache``): the
/// finished ``ArtworkPalette`` depends on the theme, the seed doesn't.
public struct ArtworkSeed: Hashable, Sendable {
    public var dominant: ThemeColor
    public var vibrant: ThemeColor
    public var edge: ThemeColor
    /// Mean WCAG relative luminance of the top ``topBand`` of the sleeve, in linear light.
    public var topBandLuminance: Double

    public init(dominant: ThemeColor, vibrant: ThemeColor, edge: ThemeColor, topBandLuminance: Double) {
        self.dominant = dominant
        self.vibrant = vibrant
        self.edge = edge
        self.topBandLuminance = topBandLuminance
    }

    /// The size the sleeve is decoded at before it's read (`PALETTE_PX`). A
    /// quantiser cares about resolution no more than a blur does.
    public static let decodePixels = 128
    /// Swatches asked of the quantiser (`SWATCH_COUNT`).
    static let swatchCount = 24
    /// How much of the artwork's height the edge colour is read from.
    static let edgeBand: Float = 0.18
    /// The status inset occupies only the upper sliver of the full-bleed hero on
    /// a phone. Kept tight so titles or faces lower in the cover don't decide the
    /// icon treatment for pixels that are never behind the status bar.
    static let topBand: Float = 0.10

    /// Reads a seed out of a decoded sleeve (`seedOf`). Nil only when the
    /// quantiser finds nothing at all — an empty image.
    public init?(pixels: ArtworkPixels) {
        guard pixels.width > 0, pixels.height > 0 else { return nil }

        // The default filter deliberately throws away near-black and near-white.
        // That is useful while looking for an accent, but it is the wrong answer
        // to "what colour is this page mostly made of?" A dark photograph would
        // otherwise be reduced to whatever warm face or tiny coloured detail
        // survived the filter, and a monochrome sleeve to an anti-aliased fringe.
        // Both cases used to turn into the same maroon page.
        let all = ArtworkSwatchPalette(pixels: pixels, maximumColorCount: Self.swatchCount, filters: []).swatches
        guard !all.isEmpty else { return nil }
        let filtered = ArtworkSwatchPalette(pixels: pixels, maximumColorCount: Self.swatchCount).swatches
        let accentCandidates = filtered.isEmpty ? all : filtered

        // First of the most populous, as Kotlin's `maxBy` picks.
        let dominant = all.firstMax(by: { Float($0.population) })!
        // The accent has to earn its place twice over: a colour nobody sees enough
        // of reads as arbitrary, and a grey one isn't an accent at all. Scoring on
        // saturation against the *square root* of population is what stops a sleeve
        // that is four-fifths black sky from accenting in black.
        let vibrant = accentCandidates.firstMax(by: { $0.hsl.saturation * Float($0.population).squareRoot() })!

        self.init(
            dominant: dominant.color,
            vibrant: vibrant.color,
            edge: Self.bottomEdgeColor(pixels),
            topBandLuminance: Self.topBandRelativeLuminance(pixels)
        )
    }

    /// Decodes `image` at ``decodePixels`` and reads a seed from it.
    public init?(image: CGImage) {
        guard let pixels = ArtworkPixels(image: image, fittingLongestSide: Self.decodePixels) else { return nil }
        self.init(pixels: pixels)
    }

    /// The mean of the artwork's bottom band — what a blur wide enough to lose
    /// the picture leaves behind at that edge.
    ///
    /// A flat mean rather than a quantised swatch on purpose: a blur has no notion
    /// of which colour is *important*, and the page under the artwork has to match
    /// what the blur actually produced, not what the picture is about.
    static func bottomEdgeColor(_ pixels: ArtworkPixels) -> ThemeColor {
        let band = constrain(Int(Float(pixels.height) * edgeBand), 1, pixels.height)
        let start = (pixels.height - band) * pixels.width
        var red = 0, green = 0, blue = 0
        for pixel in pixels.argb[start...] {
            red += redOf(pixel)
            green += greenOf(pixel)
            blue += blueOf(pixel)
        }
        let count = max(band * pixels.width, 1)
        return ThemeColor(red8: red / count, green8: green / count, blue8: blue / count)
    }

    static func topBandRelativeLuminance(_ pixels: ArtworkPixels) -> Double {
        let band = constrain(Int(Float(pixels.height) * topBand), 1, pixels.height)
        return StatusBarContrast.averageRelativeLuminance(pixels.argb[0..<(band * pixels.width)])
    }

    /// The finished page colours for this sleeve in a dark or light theme.
    public func palette(dark: Bool) -> ArtworkPalette {
        if dark {
            return ArtworkPalette(
                // Deep enough that white body text clears contrast on any sleeve, but
                // not so deep the hue is gone — the whole point is that the page is
                // recognisably *this* record's colour.
                background: dominant.withHSL(
                    saturation: { adaptedArtworkSaturation($0, minimum: 0.20, maximum: 0.62) },
                    lightness: { _ in 0.13 }
                ),
                // Follows the edge's own brightness within a band that stays clear of
                // white body text at the top and of `background` at the bottom: a
                // sleeve that ends dark hands over almost invisibly, one that ends
                // bright leaves a page that is visibly lit from under the artwork.
                wash: edge.withHSL(
                    saturation: { adaptedArtworkSaturation($0, minimum: 0.18, maximum: 0.58) },
                    lightness: { constrain($0, 0.14, 0.24) }
                ),
                elevated: dominant.withHSL(
                    saturation: { adaptedArtworkSaturation($0, minimum: 0.20, maximum: 0.62) },
                    lightness: { _ in 0.22 }
                ),
                accent: vibrant.withHSL(
                    saturation: { adaptedArtworkSaturation($0, minimum: 0.55, maximum: 1) },
                    lightness: { constrain($0, 0.62, 0.78) }
                ),
                onBackground: .white,
                // Well above the grey the untinted screens use for secondary text. A
                // tint is a *coloured* background, not a black one, so the contrast a
                // dim grey has against black is not the contrast it has here — artist
                // names were sinking into the wash on mid-toned sleeves.
                onBackgroundVariant: ThemeColor.white.withAlpha(0.80),
                divider: ThemeColor.white.withAlpha(0.12)
            )
        } else {
            return ArtworkPalette(
                background: dominant.withHSL(
                    saturation: { adaptedArtworkSaturation($0, minimum: 0.14, maximum: 0.50) },
                    lightness: { _ in 0.91 }
                ),
                wash: edge.withHSL(
                    saturation: { adaptedArtworkSaturation($0, minimum: 0.12, maximum: 0.46) },
                    lightness: { constrain($0, 0.78, 0.90) }
                ),
                elevated: dominant.withHSL(
                    saturation: { adaptedArtworkSaturation($0, minimum: 0.14, maximum: 0.50) },
                    lightness: { _ in 0.83 }
                ),
                accent: vibrant.withHSL(
                    saturation: { adaptedArtworkSaturation($0, minimum: 0.55, maximum: 1) },
                    lightness: { constrain($0, 0.30, 0.44) }
                ),
                onBackground: .black,
                onBackgroundVariant: ThemeColor.black.withAlpha(0.70),
                divider: ThemeColor.black.withAlpha(0.10)
            )
        }
    }

    /// Scrim opacity for the status bar over this sleeve — see ``StatusBarContrast/topBandScrimAlpha(artworkLuminance:)``.
    public var statusBarScrimAlpha: Double {
        StatusBarContrast.topBandScrimAlpha(artworkLuminance: topBandLuminance)
    }
}

/// Keeps neutral artwork neutral instead of inventing a hue for it.
///
/// HSL represents grey with hue zero. Raising that grey to a saturation floor
/// therefore does not make it "more colourful"; it manufactures red, which
/// becomes brown/maroon once the page lightness is lowered. A small real amount
/// of colour is kept as-is, while an unmistakably chromatic swatch can still be
/// strengthened enough to make controls legible and the page recognisable.
func adaptedArtworkSaturation(_ source: Float, minimum: Float, maximum: Float) -> Float {
    let saturation = constrain(source, 0, 1)
    return saturation < chromaticSaturationThreshold ? saturation : constrain(saturation, minimum, maximum)
}

/// Below this, boosting saturation makes quantisation noise visible as a tint.
let chromaticSaturationThreshold: Float = 0.12

extension Sequence {
    /// Kotlin's `maxBy`: the *first* element with the largest key.
    func firstMax(by key: (Element) -> Float) -> Element? {
        var best: Element?
        var bestKey = -Float.infinity
        for element in self {
            let k = key(element)
            if best == nil || bestKey < k {
                best = element
                bestKey = k
            }
        }
        return best
    }
}
