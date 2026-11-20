import CoreGraphics
import Foundation

/// Four colours drawn from a sleeve for the blob mesh (`MeshGradientBackground`
/// on Android): the legacy player backdrop (Settings › "legacy mesh gradient"),
/// Replay's page, story and card backdrops, the Library's Replay banner, and the
/// Home screen's service cards (which pass fixed colours).
///
/// This is the *quantiser's* view of a sleeve — what it is about, not where
/// anything is or how much of it there is. See ``ArtworkMesh`` for the default
/// player backdrop, which answers the other question.
public struct MeshPalette: Hashable, Sendable {
    public var colors: [ThemeColor]

    public init(colors: [ThemeColor]) {
        self.colors = colors
    }

    /// The stock purple-pink-blue-peach, used until a sleeve has been read and
    /// for a sleeve with no colour in it at all.
    public static let fallbackColors: [ThemeColor] = [
        ThemeColor(argb: 0xFF3A_1C71),
        ThemeColor(argb: 0xFFD7_6D77),
        ThemeColor(argb: 0xFF2B_5876),
        ThemeColor(argb: 0xFFFF_AF7B),
    ]

    public static let fallback = MeshPalette(colors: fallbackColors)

    /// The size the sleeve is decoded at before quantising — palette quality is
    /// fine at thumbnail size, and it's fast.
    public static let decodePixels = 128
    static let swatchCount = 24

    /// Four mesh colours from a decoded sleeve (`paletteOf`).
    ///
    /// The named swatches — vibrant, muted and friends — are a convenience over
    /// the full set, and on dark or desaturated sleeves every vibrant slot comes
    /// back empty: Karan Aujla's marble interior fills two of the five. Topping the
    /// rest up from the stock colours is what left those covers sitting under the
    /// stock purple. So the whole swatch list is read instead (most populous
    /// first), and any shortfall is derived from the art's own colours.
    public init(pixels: ArtworkPixels) {
        func swatches(filters: [PaletteFilter]) -> [ThemeColor] {
            ArtworkSwatchPalette(pixels: pixels, maximumColorCount: Self.swatchCount, filters: filters)
                .swatches
                .stableSorted { $0.population > $1.population }
                .map(\.color)
        }
        var found = swatches(filters: [.default])
        if found.isEmpty {
            // The default filter discards near-black and near-white, which on a
            // monochrome sleeve can be everything there is.
            found = swatches(filters: [])
        }
        let distinct = Self.distinctEnough(found)
        if distinct.isEmpty {
            colors = Self.fallbackColors
        } else if distinct.count >= 4 {
            colors = Array(distinct.prefix(4))
        } else {
            colors = Self.expandedToFour(distinct)
        }
    }

    /// Decodes `image` at ``decodePixels`` and reads the four colours from it.
    public init?(image: CGImage) {
        guard let pixels = ArtworkPixels(image: image, fittingLongestSide: Self.decodePixels) else { return nil }
        self.init(pixels: pixels)
    }

    /// Every colour turned `degrees` around the wheel, tone untouched — how
    /// Replay's story makes each card's backdrop visibly its own.
    public func rotated(degrees: Float) -> MeshPalette {
        if degrees == 0 { return self }
        return MeshPalette(colors: colors.map { color in
            var hsl = color.hsl
            hsl.hue = (hsl.hue + degrees).truncatingRemainder(dividingBy: 360)
            return ThemeColor(hsl: hsl)
        })
    }

    /// Drops near-duplicates, so the four blobs don't collapse into one wash.
    static func distinctEnough(_ colors: [ThemeColor]) -> [ThemeColor] {
        var kept = [ThemeColor]()
        for color in colors where !kept.contains(where: { isClose($0, color) }) {
            kept.append(color)
        }
        return kept
    }

    static func isClose(_ a: ThemeColor, _ b: ThemeColor) -> Bool {
        let first = a.hsl
        let second = b.hsl
        let gap = abs(first.hue - second.hue)
        let hueGap = min(gap, 360 - gap)
        return hueGap < 15 && abs(first.lightness - second.lightness) < 0.12
    }

    /// Fills the empty slots off the art itself, fanning hue and lightness out.
    static func expandedToFour(_ colors: [ThemeColor]) -> [ThemeColor] {
        var out = colors
        var step: Float = 1
        while out.count < 4 {
            let source = colors[(out.count - colors.count) % colors.count]
            out.append(shifted(source, hue: 24 * step, lightness: 0.12 * step))
            step += 1
        }
        return out
    }

    static func shifted(_ color: ThemeColor, hue: Float, lightness: Float) -> ThemeColor {
        var hsl = color.hsl
        hsl.hue = (hsl.hue + hue).truncatingRemainder(dividingBy: 360)
        hsl.lightness = constrain(hsl.lightness + lightness, 0.2, 0.7)
        return ThemeColor(hsl: hsl)
    }
}

/// What the blob mesh actually paints for a palette: four blob colours and the
/// floor under them.
///
/// Any artwork has to yield a rich, non-muddy mesh, so each colour's saturation
/// is boosted by 35% and its lightness clamped to 0.28–0.58; the floor is the
/// first colour taken down to 0.12 lightness. Short palettes are padded from
/// the stock colours, an empty one is the stock colours.
public struct MeshGradientColors: Hashable, Sendable {
    public var blobs: [ThemeColor]
    public var base: ThemeColor

    public init(blobs: [ThemeColor], base: ThemeColor) {
        self.blobs = blobs
        self.base = base
    }

    public init(palette: MeshPalette) {
        let source = (palette.colors.isEmpty ? MeshPalette.fallbackColors : palette.colors) + MeshPalette.fallbackColors
        let tuned = source.prefix(4).map(Self.tuned)
        self.init(blobs: tuned, base: Self.dimmed(tuned[0]))
    }

    static func tuned(_ color: ThemeColor) -> ThemeColor {
        color.withHSL(saturation: { min($0 * 1.35, 1) }, lightness: { constrain($0, 0.28, 0.58) })
    }

    static func dimmed(_ color: ThemeColor) -> ThemeColor {
        color.withHSL(lightness: { _ in 0.12 })
    }
}

extension MeshGradientColors: ThemingInterpolatable {
    /// Each slot, and the floor, crossfade independently through Oklab — five
    /// `animateColorAsState`s on Android.
    public static func interpolate(from: MeshGradientColors, to: MeshGradientColors, fraction: Double) -> MeshGradientColors {
        let count = min(from.blobs.count, to.blobs.count)
        var blobs = (0..<count).map { ThemeColor.interpolateOklab(from: from.blobs[$0], to: to.blobs[$0], fraction: fraction) }
        if to.blobs.count > count {
            blobs += to.blobs[count...]
        }
        return MeshGradientColors(
            blobs: blobs,
            base: ThemeColor.interpolateOklab(from: from.base, to: to.base, fraction: fraction)
        )
    }
}

/// One soft blob of the mesh: a radial gradient from ``color`` at its centre
/// (at ``MeshGradientLayout/blobCenterAlpha``) to fully transparent at ``radius``.
public struct MeshBlob: Hashable, Sendable {
    public var center: CGPoint
    public var radius: CGFloat
    /// Already carries the centre opacity.
    public var color: ThemeColor
}

/// Where the blob mesh's colours sit and how they move — everything
/// `MeshGradientBackground` decides before it draws.
///
/// The view: fill with ``MeshGradientColors/base``, draw ``blobs(colors:phase:in:)``
/// as radial gradients, blur the layer by the blur radius, scale it by
/// ``overscale`` and clip it, then lay ``scrimStops`` over the top.
///
/// The blobs drift when there is a reason to — the player opening, or the track
/// changing — and then come to rest. They used to orbit forever, which meant
/// re-blurring a full-screen layer at display refresh rate for as long as the
/// player was up: the most expensive thing in the app, for motion that reads as
/// ambient at best and is invisible while the phone is in a pocket.
public enum MeshGradientLayout {
    /// Resting positions, as fractions of the surface.
    public static let anchors: [CGPoint] = [
        CGPoint(x: 0.20, y: 0.25),
        CGPoint(x: 0.80, y: 0.20),
        CGPoint(x: 0.75, y: 0.80),
        CGPoint(x: 0.25, y: 0.75),
    ]
    /// Per-blob angular speed multipliers. Irrational-ish ratios, so a
    /// continuous orbit never repeats.
    public static let speeds: [Double] = [1, -0.7, 0.85, -1.15]
    /// How far a blob strays from its anchor, as a fraction of the surface.
    public static let driftAmplitude = 0.16
    /// Blob radius as a fraction of the surface's larger side.
    public static let radiusFraction = 0.62
    public static let blobCenterAlpha = 0.85
    /// Scaled up slightly so the blur's clamped edges never show — and clipped
    /// *outside* the scale, or the overhang (a third of the width) is painted
    /// over whatever sits beside the backdrop.
    public static let overscale: CGFloat = 1.3
    /// Sized for a full screen; a small surface needs proportionally less
    /// (Replay card 34, Library banner 28, Home service cards 24), or the four
    /// colours blend into one wash before they reach its edges.
    public static let defaultBlurRadius: CGFloat = 64
    /// Gentle scrim so white text stays legible over bright art.
    public static let scrimStops: [ThemeGradientStop] = [
        ThemeGradientStop(location: 0, color: ThemeColor.black.withAlpha(0.10)),
        ThemeGradientStop(location: 1, color: ThemeColor.black.withAlpha(0.38)),
    ]

    /// The blobs at drift `phase` (radians) on a surface of `size` (before the overscale).
    public static func blobs(colors: MeshGradientColors, phase: Double, in size: CGSize) -> [MeshBlob] {
        let radius = max(size.width, size.height) * radiusFraction
        return colors.blobs.prefix(anchors.count).enumerated().map { index, color in
            let anchor = anchors[index]
            let i = Double(index)
            let x = (anchor.x + driftAmplitude * cos(phase * speeds[index] + i * 1.7)) * size.width
            let y = (anchor.y + driftAmplitude * sin(phase * speeds[index] * 0.9 + i * 2.3)) * size.height
            return MeshBlob(center: CGPoint(x: x, y: y), radius: radius, color: color.withAlpha(blobCenterAlpha))
        }
    }
}

/// How the blob mesh's colours and drift respond to a new palette or track.
public enum MeshGradientMotion {
    /// Colour changes on a track skip crossfade over this instead of snapping.
    public static let colorFadeDuration: TimeInterval = 1.4
    /// How long one settle takes.
    public static let defaultDriftDuration: TimeInterval = 8
    /// How far the blobs travel in one settle. A shade under half a turn: enough
    /// that the backdrop visibly reacts to a track change, short of a full orbit
    /// that would land the blobs back where they started.
    public static let driftRadians = Double(Float(Double.pi * 0.45))

    /// nil = snap. "Reduce animation", or a surface that should read as a still
    /// image (`animated: false` — Replay's page and cards), snap straight to the
    /// new colours.
    public static func colorFade(animated: Bool, reduceAnimation: Bool) -> TimeInterval? {
        reduceAnimation || !animated ? nil : colorFadeDuration
    }

    /// What the drift phase does when the player opens or the track key changes.
    public enum PhaseChange: Hashable, Sendable {
        /// Jump to this phase and stay.
        case snap(to: Double)
        /// Ease forward by `radians` over `duration` on ``ThemingMotion/fastOutSlowIn(_:)``, then rest.
        case settle(by: Double, duration: TimeInterval)
        /// Advance by a full turn over `duration` linearly, and repeat for as long
        /// as the surface is up. Restarted each lap rather than looped: the
        /// blobs' speeds keep the pattern from ever repeating.
        case orbit(by: Double, duration: TimeInterval)
    }

    /// - Parameters:
    ///   - continuous: keep orbiting instead of settling. Off everywhere the mesh
    ///     fills a screen; on for small cards the user is looking straight at,
    ///     where the motion is what makes the card feel like an object.
    ///   - animated: off for a surface that should read as a still image — the
    ///     blobs never drift on a track change, only ever sit at phase 0.
    public static func phaseChange(
        animated: Bool,
        reduceAnimation: Bool,
        continuous: Bool,
        driftDuration: TimeInterval = defaultDriftDuration
    ) -> PhaseChange {
        if !animated || reduceAnimation { return .snap(to: 0) }
        if continuous { return .orbit(by: 2 * Double.pi, duration: driftDuration * 4) }
        return .settle(by: driftRadians, duration: driftDuration)
    }
}

extension Array {
    /// Kotlin's `sortedBy…` is stable; this keeps equal elements in their original order.
    func stableSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        enumerated()
            .sorted { lhs, rhs in
                if areInIncreasingOrder(lhs.element, rhs.element) { return true }
                if areInIncreasingOrder(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
