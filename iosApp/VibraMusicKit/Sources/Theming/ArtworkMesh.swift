import CoreGraphics
import Foundation
import SwiftUI

/// The artwork's own colours, upside down and reduced to a mesh, for the player
/// to stand on (`ArtworkMesh` / `ArtworkMeshBackdrop` on Android — the default
/// player backdrop).
///
/// The blob mesh (``MeshPalette``) answers a different question: it asks the
/// quantiser what colours a sleeve is *about* and paints four blobs of them.
/// That is why a cover that is nine-tenths black with a red stripe came out as a
/// red screen — the quantiser reports red because red is the interesting answer,
/// and nothing downstream knows how little of the picture it was. It also has no
/// idea *where* in the frame that red was.
///
/// This is the other approach: no quantiser at all. The sleeve is averaged into a
/// ``gridSize``-square grid of means; the row against the seam is kept in place,
/// and everything below it is flipped and then rotated sideways (see
/// `rotatedBelowSeam`). What the backdrop holds is the cover's own colours,
/// roughly in the cover's own proportions (nine-tenths black stays nine-tenths
/// black) and with each cell's neighbours exactly what they were in the source,
/// but not lined up in the cover's own *position*: a flip on its own reads as a
/// reflection on any cover with real structure to it — a face, a horizon, a
/// logo — because the layout still lines up column for column with what's on
/// screen above it. The rotation is what breaks that; the coarseness keeps any
/// one cell from being recognisable on its own.
///
/// Two outputs, for the two ways the view can draw it:
/// - ``texture``: the grid smoothly resampled to ``textureSize``², exactly the
///   texture Android uploads. Draw it stretched with linear filtering
///   (``textureImage()``), iOS 17 and up.
/// - ``gridLayout(seamFraction:)``: the control points laid out for SwiftUI's
///   `MeshGradient` (iOS 18).
public struct ArtworkMesh: Hashable, Sendable {
    /// How many cells across the mesh is. Coarse deliberately: enough that a
    /// cover's layout survives (where the bright part was, how much of the frame
    /// it took), few enough that nothing recognisable does.
    public static let gridSize = 6
    /// How far the grid is interpolated on the CPU before the GPU stretches it.
    ///
    /// Bilinear filtering straight off a 6×6 texture is smooth but not *soft*: it
    /// is piecewise-linear, and the eye finds the crease at every cell boundary
    /// when they are a hundred and eighty pixels apart. Resampling to this first,
    /// with a curve that flattens at each control point, leaves creases too small
    /// to see before they are magnified — which is what lets the blur on top be
    /// narrow, and what makes following a playing clip affordable.
    public static let textureSize = 32
    /// What a still sleeve is decoded at before it is averaged down. A whole
    /// multiple of ``gridSize``, so every cell is an equal number of source pixels.
    public static let decodePixels = 120
    /// The most rows and columns of a source that are actually looked at. A clip
    /// frame is whatever size it was grabbed at; sampling on a stride bounds the
    /// work at a fixed cost per frame, which is what makes it safe several times
    /// a second.
    static let sampleLimit = 128
    static let vibrance: Float = 1.12
    static let lightnessFloor: Float = 0.045

    public let columns: Int
    public let rows: Int
    /// `rows × columns` means, row-major. Row 0 is the sleeve's own bottom edge
    /// — the row that sits against the seam — and later rows run back up into
    /// the cover, which is the order the backdrop draws them down the screen.
    public let controlPoints: [UInt32]
    /// ``textureSize``² texels, the smoothly resampled grid.
    public let texture: ArtworkPixels

    /// Averages `pixels` into a mesh (`meshOf`). Nil only for an empty image.
    ///
    /// - Parameter seed: decides the sideways rotation. The same artwork must
    ///   land in the same arrangement each time it is read, or a playing clip
    ///   re-read every few seconds would show its layout visibly turning under its
    ///   own colours. Use ``seed(forArtworkURL:)``.
    public init?(pixels: ArtworkPixels, seed: Int32) {
        let width = pixels.width
        let height = pixels.height
        guard width >= 1, height >= 1 else { return nil }

        // A cell nothing lands in would come out black, so the grid never asks
        // for more cells than the artwork has pixels.
        let cols = min(Self.gridSize, width)
        let rows = min(Self.gridSize, height)
        let rowStep = max(height / Self.sampleLimit, 1)
        let colStep = max(width / Self.sampleLimit, 1)

        let cells = rows * cols
        var red = [Int](repeating: 0, count: cells)
        var green = [Int](repeating: 0, count: cells)
        var blue = [Int](repeating: 0, count: cells)
        var count = [Int](repeating: 0, count: cells)

        var y = 0
        while y < height {
            // Flipped as it is read: the bottom of the sleeve becomes row 0.
            let rowBase = ((height - 1 - y) * rows / height) * cols
            var x = 0
            while x < width {
                let cell = rowBase + x * cols / width
                let pixel = pixels.pixel(x: x, y: y)
                red[cell] += redOf(pixel)
                green[cell] += greenOf(pixel)
                blue[cell] += blueOf(pixel)
                count[cell] += 1
                x += colStep
            }
            y += rowStep
        }

        let grid = (0..<cells).map { cell -> UInt32 in
            let n = max(count[cell], 1)
            return Self.lifted(opaqueARGB(red: red[cell] / n, green: green[cell] / n, blue: blue[cell] / n))
        }
        let arranged = Self.rotatedBelowSeam(grid, cols: cols, rows: rows, seed: seed)
        self.columns = cols
        self.rows = rows
        self.controlPoints = arranged
        self.texture = ArtworkPixels(
            width: Self.textureSize,
            height: Self.textureSize,
            argb: Self.resampled(arranged, cols: cols, rows: rows, size: Self.textureSize)
        )
    }

    /// Decodes `image` at ``decodePixels`` (a still sleeve) and meshes it.
    public init?(image: CGImage, seed: Int32) {
        guard let pixels = ArtworkPixels(image: image, fittingLongestSide: Self.decodePixels) else { return nil }
        self.init(pixels: pixels, seed: seed)
    }

    /// The arrangement seed for an artwork: Java's `String.hashCode()` of its
    /// URL, as Android seeds it, so a cover lands in the same arrangement on
    /// both platforms. Zero when there is no URL (a clip with no still sleeve).
    public static func seed(forArtworkURL url: String?) -> Int32 {
        guard let url else { return 0 }
        return javaStringHashCode(url)
    }

    public var controlColors: [ThemeColor] { controlPoints.map(ThemeColor.init(argb:)) }

    /// The texture as a `CGImage` — draw it stretched over the surface below the
    /// seam, with linear (`.low`/`.medium`) interpolation.
    public func textureImage() -> CGImage? { texture.makeCGImage() }

    /// The texture's first row as a 32×1 image — draw it stretched over the
    /// band *above* the seam (behind the artwork), so the backdrop is continuous
    /// everywhere rather than only below the sleeve.
    public func seamRowImage() -> CGImage? {
        ArtworkPixels(width: Self.textureSize, height: 1, argb: Array(texture.argb[0..<Self.textureSize])).makeCGImage()
    }

    /// The one liberty taken with the artwork's colours.
    ///
    /// Saturation is nudged because averaging a block of pixels greys it — the
    /// mean of a red stripe and the black around it is a dull maroon, and this
    /// puts back roughly what the averaging took, not more. Lightness is only
    /// floored, off pure black, which is not so much a colour choice as somewhere
    /// for the blur to find an edge. Neither touches the *proportions*: a sleeve
    /// that is mostly black stays mostly black.
    static func lifted(_ argb: UInt32) -> UInt32 {
        var hsl = ColorUtilsPort.rgbToHSL(argb: argb)
        hsl.saturation = min(hsl.saturation * vibrance, 1)
        hsl.lightness = max(hsl.lightness, lightnessFloor)
        return ColorUtilsPort.hslToARGB(hsl)
    }

    /// Every row but row 0 — the seam row, kept literal so there is no visible
    /// join under the artwork — rotated sideways by the same random amount, and
    /// mirrored left-to-right half the time.
    ///
    /// An earlier version shuffled every cell below the seam independently, which
    /// broke the *mesh*: a photo's neighbouring regions are usually close in
    /// colour, and a random per-cell permutation puts wildly different cells next
    /// to each other far more often than the photo ever did, so the smooth blend
    /// between them read as a mosaic rather than the two or three broad blobs a
    /// real mesh gradient has. A cyclic shift keeps every cell's neighbours, just
    /// carried around the row, so whatever gradient existed between them survives.
    static func rotatedBelowSeam(_ grid: [UInt32], cols: Int, rows: Int, seed: Int32) -> [UInt32] {
        if rows <= 1 { return grid }
        var random = KotlinXorWowRandom(seed: seed)
        let mirror = random.nextBoolean()
        let shift = Int(random.nextInt(until: Int32(cols)))
        var out = grid
        for row in 1..<rows {
            let base = row * cols
            for x in 0..<cols {
                let src = mirror ? cols - 1 - x : x
                out[base + x] = grid[base + (src + shift) % cols]
            }
        }
        return out
    }

    /// Smoothly resamples a `cols × rows` grid of control points up to a
    /// `size × size` texture (smoothstep between cell centres, held flat past
    /// the outermost ones).
    static func resampled(_ grid: [UInt32], cols: Int, rows: Int, size: Int) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: size * size)
        for ty in 0..<size {
            let fy = (Float(ty) + 0.5) / Float(size) * Float(rows) - 0.5
            let y0 = constrain(Int(fy.rounded(.down)), 0, rows - 1)
            let y1 = min(y0 + 1, rows - 1)
            let wy = smoothstep(fy - Float(y0))
            for tx in 0..<size {
                let fx = (Float(tx) + 0.5) / Float(size) * Float(cols) - 0.5
                let x0 = constrain(Int(fx.rounded(.down)), 0, cols - 1)
                let x1 = min(x0 + 1, cols - 1)
                let wx = smoothstep(fx - Float(x0))
                let top = lerpARGB(grid[y0 * cols + x0], grid[y0 * cols + x1], wx)
                let bottom = lerpARGB(grid[y1 * cols + x0], grid[y1 * cols + x1], wx)
                out[ty * size + tx] = lerpARGB(top, bottom, wy)
            }
        }
        return out
    }

    /// Flat at both ends, so no cell boundary shows up as a crease once magnified.
    static func smoothstep(_ t: Float) -> Float {
        let x = constrain(t, 0, 1)
        return x * x * (3 - 2 * x)
    }

    static func lerpARGB(_ from: UInt32, _ to: UInt32, _ t: Float) -> UInt32 {
        if t <= 0 { return from }
        if t >= 1 { return to }
        func channel(_ a: Int, _ b: Int) -> Int {
            constrain(javaRound(Float(a) + Float(b - a) * t), 0, 255)
        }
        return opaqueARGB(
            red: channel(redOf(from), redOf(to)),
            green: channel(greenOf(from), greenOf(to)),
            blue: channel(blueOf(from), blueOf(to))
        )
    }
}

// MARK: - MeshGradient layout

/// A mesh's control points laid out over the whole backdrop, for SwiftUI's
/// `MeshGradient` (iOS 18): `width × height` points, row-major, in unit
/// coordinates with y pointing down.
///
/// It reproduces how Android lays the texture out:
/// - above the seam, the seam row is held flat (the band behind the artwork);
/// - below it, each control point sits at its cell's centre across the rest of
///   the surface, with the outermost values held flat out to the edges — which
///   is where the texture's clamped resample puts them.
///
/// `MeshGradient` blends the patches with smooth Bézier interpolation rather
/// than the texture's smoothstep-then-bilinear; with the blur on top the two are
/// indistinguishable, but they are not bit-identical.
public struct ArtworkMeshGrid: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let points: [SIMD2<Float>]
    public let colors: [ThemeColor]

    @available(iOS 18.0, macOS 15.0, *)
    public func meshGradient(smoothsColors: Bool = true) -> MeshGradient {
        MeshGradient(
            width: width,
            height: height,
            points: points,
            colors: colors.map(\.color),
            smoothsColors: smoothsColors
        )
    }
}

extension ArtworkMesh {
    /// - Parameter seamFraction: where the artwork's bottom edge sits, as a
    ///   fraction of the surface's height. Zero for a surface with no artwork over
    ///   it, which puts the whole mesh on screen.
    public func gridLayout(seamFraction: Double) -> ArtworkMeshGrid {
        let seam = Float(constrain(seamFraction.isFinite ? seamFraction : 0, 0, 1))

        var xs: [Float] = [0]
        var columnSources: [Int] = [0]
        for c in 0..<columns {
            xs.append((Float(c) + 0.5) / Float(columns))
            columnSources.append(c)
        }
        xs.append(1)
        columnSources.append(columns - 1)

        var ys: [Float] = [0]
        var rowSources: [Int] = [0]
        if seam >= 1 {
            ys.append(1)
            rowSources.append(0)
        } else {
            if seam > 0 {
                ys.append(seam)
                rowSources.append(0)
            }
            for r in 0..<rows {
                ys.append(seam + (Float(r) + 0.5) / Float(rows) * (1 - seam))
                rowSources.append(r)
            }
            ys.append(1)
            rowSources.append(rows - 1)
        }

        var points = [SIMD2<Float>]()
        var colors = [ThemeColor]()
        points.reserveCapacity(xs.count * ys.count)
        colors.reserveCapacity(xs.count * ys.count)
        for (y, sourceRow) in zip(ys, rowSources) {
            for (x, sourceColumn) in zip(xs, columnSources) {
                points.append(SIMD2(x, y))
                colors.append(ThemeColor(argb: controlPoints[sourceRow * columns + sourceColumn]))
            }
        }
        return ArtworkMeshGrid(width: xs.count, height: ys.count, points: points, colors: colors)
    }

    /// Where the two texture draws go on a surface of `size` with the seam at
    /// `seam` points down: the seam row stretched over `held` (empty when the
    /// seam is at the very top), the whole texture stretched over `body`.
    public static func textureRegions(in size: CGSize, seam: CGFloat) -> (held: CGRect, body: CGRect) {
        let seamY = constrain(seam, 0, size.height)
        let held = seamY > 0.5 ? CGRect(x: 0, y: 0, width: size.width, height: seamY.rounded()) : .zero
        let body = CGRect(x: 0, y: seamY.rounded(), width: size.width, height: (size.height - seamY).rounded())
        return (held, body)
    }
}

// MARK: - Crossfade

/// One layer of the mesh backdrop: a mesh at an opacity.
public struct ArtworkMeshLayer: Hashable, Sendable {
    public let mesh: ArtworkMesh
    public let opacity: Double
}

/// The mesh backdrop's crossfade between two covers — the state machine behind
/// `ArtworkMeshBackdrop`'s `LaunchedEffect(mesh)`.
///
/// What crossfades is a pair of *layers*, not a pair of colours: the outgoing
/// mesh stays drawn at full opacity until the incoming one, drawn over it, has
/// faded all the way in. (Drawing two opaque layers is equivalent to one mesh
/// whose colours are ``ThemeColor/mixed(with:fraction:)`` — straight sRGB —
/// which is what a view that merges them into one `MeshGradient` should use.)
///
/// - The first mesh has nothing to fade *from*: it's shown at once.
/// - "Reduce animation": every change is a cut.
/// - A change arriving mid-fade: whatever was fading in has been on screen for a
///   while and is what the new one fades *from* — it is promoted to ``shown``
///   first. Leaving it would restart the fade from the mesh before it, and a clip
///   sending frames faster than the fade runs would never settle at all.
/// - Nil (a track whose cover hasn't been read) changes nothing: the last mesh
///   stays on screen rather than blanking. On Android a nil mid-fade also freezes
///   the fade part-way (the coroutine is cancelled); here the fade just finishes.
public struct ArtworkMeshCrossfade: Hashable, Sendable {
    /// Long enough to read as the screen changing colour rather than cutting, and
    /// comfortably inside the interval a clip's frames arrive on
    /// (``ArtworkMeshBackdropStyle/canvasRefreshInterval``). It has to finish
    /// before the next one lands, or the backdrop never settles where a frame
    /// actually put it.
    public static let fadeDuration: TimeInterval = 0.9

    public private(set) var shown: ArtworkMesh?
    public private(set) var incoming: ArtworkMesh?
    public private(set) var fadeStart: TimeInterval = 0
    private var lastReceived: ArtworkMesh?

    public init(mesh: ArtworkMesh? = nil) {
        shown = mesh
        lastReceived = mesh
    }

    /// Feeds the backdrop the mesh that should now be on screen.
    public mutating func receive(_ mesh: ArtworkMesh?, at time: TimeInterval, reduceAnimation: Bool) {
        guard let next = mesh else {
            lastReceived = nil
            return
        }
        if next == lastReceived { return }
        lastReceived = next

        if let fadingIn = incoming {
            shown = fadingIn
        }
        incoming = nil
        if next == shown { return }
        if shown == nil || reduceAnimation {
            shown = next
            return
        }
        incoming = next
        fadeStart = time
    }

    /// The incoming mesh's opacity, eased.
    public func incomingOpacity(at time: TimeInterval) -> Double {
        guard incoming != nil else { return 0 }
        let linear = constrain((time - fadeStart) / Self.fadeDuration, 0, 1)
        return ThemingMotion.fastOutSlowIn(linear)
    }

    /// Whether nothing is fading — the view can stop redrawing every frame.
    public func isSettled(at time: TimeInterval) -> Bool {
        incoming == nil || time - fadeStart >= Self.fadeDuration
    }

    /// Completes a finished fade: the incoming mesh becomes the shown one.
    public mutating func settle(at time: TimeInterval) {
        if let fadingIn = incoming, time - fadeStart >= Self.fadeDuration {
            shown = fadingIn
            incoming = nil
        }
    }

    /// What to draw, bottom to top.
    public func layers(at time: TimeInterval) -> [ArtworkMeshLayer] {
        var layers = [ArtworkMeshLayer]()
        if let shown {
            layers.append(ArtworkMeshLayer(mesh: shown, opacity: 1))
        }
        if let incoming {
            let opacity = incomingOpacity(at: time)
            if opacity > 0.001 {
                layers.append(ArtworkMeshLayer(mesh: incoming, opacity: opacity))
            }
        }
        return layers
    }
}

/// The mesh backdrop's surface constants (`ArtworkMeshBackdrop`).
public enum ArtworkMeshBackdropStyle {
    /// Drawn only until an artwork has been read — never a colour anyone chose.
    /// Also the opaque floor under the mesh: the player is a sheet over the app's
    /// own pages and every pixel of it has to be opaque.
    public static let fallback = ThemeColor(argb: 0xFF12_1212)
    /// Narrow on purpose, and not what makes the backdrop smooth — the texture is
    /// already resampled. It takes the last of the edge off. Skipped when the
    /// user reduces blur.
    public static let blurRadius: CGFloat = 32
    /// Enough of a scrim to keep white text off a bright sleeve, and no more:
    /// these are the sleeve's own colours, and a sleeve that ends dark should
    /// leave a dark screen.
    public static let scrimStops: [ThemeGradientStop] = [
        ThemeGradientStop(location: 0, color: ThemeColor.black.withAlpha(0.06)),
        ThemeGradientStop(location: 1, color: ThemeColor.black.withAlpha(0.30)),
    ]
    /// How often the player re-reads a playing Canvas clip's colours. The read is
    /// the expensive half (a frame grab); the fade is over well inside the gap.
    public static let canvasRefreshInterval: TimeInterval = 3
    /// How many goes a cover's read gets, and the wait between them — matched to
    /// the cover image's own retry so the two never disagree about whether a
    /// track has a picture.
    public static let loadAttempts = 4
    public static let retryDelay: TimeInterval = 1.5
    /// A session's worth of covers, at four kilobytes of texture each.
    static let cacheEntries = 64

    public static func blurRadius(reduceDynamicBlur: Bool) -> CGFloat {
        reduceDynamicBlur ? 0 : blurRadius
    }
}

// MARK: - Kotlin / Java determinism

/// Java's `String.hashCode()`: `s[0]·31^(n-1) + … + s[n-1]` over UTF-16 code
/// units, wrapping at 32 bits.
func javaStringHashCode(_ string: String) -> Int32 {
    var hash: Int32 = 0
    for unit in string.utf16 {
        hash = hash &* 31 &+ Int32(unit)
    }
    return hash
}

/// `kotlin.random.Random(seed: Int)` — Marsaglia's xorwow as the Kotlin
/// standard library implements it (`XorWowRandom`), so a seed produces the same
/// sequence here as on Android.
struct KotlinXorWowRandom {
    private var x: Int32
    private var y: Int32
    private var z: Int32
    private var w: Int32
    private var v: Int32
    private var addend: Int32

    init(seed: Int32) {
        self.init(seed1: seed, seed2: seed >> 31)
    }

    init(seed1: Int32, seed2: Int32) {
        x = seed1
        y = seed2
        z = 0
        w = 0
        v = ~seed1
        addend = (seed1 << 10) ^ Int32(bitPattern: UInt32(bitPattern: seed2) >> 4)
        precondition((x | y | z | w | v) != 0, "Initial state must have at least one non-zero element.")
        // Some trivial seeds produce several values with zeroes in the upper bits, so the first 64 are discarded.
        for _ in 0..<64 {
            _ = nextInt()
        }
    }

    mutating func nextInt() -> Int32 {
        var t = x
        t = t ^ Int32(bitPattern: UInt32(bitPattern: t) >> 2)
        x = y
        y = z
        z = w
        let v0 = v
        w = v0
        t = (t ^ (t << 1)) ^ v0 ^ (v0 << 4)
        v = t
        addend = addend &+ 362_437
        return t &+ addend
    }

    mutating func nextBits(_ bitCount: Int) -> Int32 {
        Self.takeUpperBits(nextInt(), bitCount)
    }

    /// `Int.takeUpperBits`: `ushr(32 - bitCount) and (-bitCount).shr(31)`, with
    /// the JVM's five-bit shift-count masking.
    static func takeUpperBits(_ value: Int32, _ bitCount: Int) -> Int32 {
        let shifted = Int32(bitPattern: UInt32(bitPattern: value) >> UInt32((32 - bitCount) & 31))
        return shifted & (Int32(truncatingIfNeeded: -bitCount) >> 31)
    }

    mutating func nextBoolean() -> Bool {
        nextBits(1) != 0
    }

    /// `nextInt(until)` for a positive bound.
    mutating func nextInt(until n: Int32) -> Int32 {
        precondition(n > 0, "bound must be positive")
        if n & (0 &- n) == n {
            return nextBits(31 - n.leadingZeroBitCount)
        }
        var bits: Int32
        var value: Int32
        repeat {
            bits = Int32(bitPattern: UInt32(bitPattern: nextInt()) >> 1)
            value = bits % n
        } while bits &- value &+ (n - 1) < 0
        return value
    }
}
