import CoreGraphics
import Foundation
import Observation

/// The page tint for whichever artwork a page is showing — `rememberArtworkPalette`.
///
/// ```swift
/// @State private var tint = ArtworkTintModel(cache: palettes)
/// …
/// let target = tint.palette(for: artworkURL, scheme: scheme)   // first frame included
/// content
///     .background(target.background.color)
///     .animation(tint.fade(for: artworkURL, reduceAnimation: reduce).map(ThemingMotion.fastOutSlowInAnimation), value: target)
///     .task(id: artworkURL) { await tint.load(artworkURL, artPixels: 480) }
/// ```
///
/// Artwork already read once is tinted on the very first frame, off the cache —
/// a sheet opened from a page it shares a cover with, or a page opened twice, has
/// nothing to wait for and nothing to fade. Only a sleeve genuinely being seen for
/// the first time starts from the theme's own colours and warms into its own.
@MainActor
@Observable
public final class ArtworkTintModel {
    @ObservationIgnored private let cache: ArtworkPaletteCache

    /// The artwork the loaded state belongs to.
    public private(set) var artworkURL: URL?
    public private(set) var seed: ArtworkSeed?
    /// Whether the colours were there from the first frame — then there is
    /// nothing to crossfade *from*.
    public private(set) var knownUpFront = false

    public init(cache: ArtworkPaletteCache) {
        self.cache = cache
    }

    /// The seed for `url` right now, without waiting: the loaded one if it's for
    /// this URL, else whatever the cache already holds.
    public func currentSeed(for url: URL?) -> ArtworkSeed? {
        guard let url else { return nil }
        if url == artworkURL, let seed { return seed }
        return cache.cachedSeed(for: url)
    }

    /// The colours to paint for `url` now: its tint once known, the scheme's own
    /// colours until then. Dark or light follows the scheme.
    public func palette(for url: URL?, scheme: ThemeColorScheme) -> ArtworkPalette {
        currentSeed(for: url)?.palette(dark: scheme.isDark) ?? .untinted(scheme)
    }

    /// How to move to `url`'s tint — see ``ArtworkPalette/tintFade(reduceAnimation:knownUpFront:)``.
    /// For a URL not loaded yet, "known up front" is whether the cache has it now.
    public func fade(for url: URL?, reduceAnimation: Bool) -> TimeInterval? {
        let known = url == artworkURL ? knownUpFront : url.flatMap(cache.cachedSeed(for:)) != nil
        return ArtworkPalette.tintFade(reduceAnimation: reduceAnimation, knownUpFront: known)
    }

    /// Top-band luminance of the current artwork, for the status-bar scrim.
    public func topBandLuminance(for url: URL?) -> Double? {
        currentSeed(for: url)?.topBandLuminance
    }

    /// Switches to `url` and reads its colours if they aren't known yet. Call
    /// from `.task(id: url)`.
    public func load(_ url: URL?, artPixels: Int = ArtworkPaletteCache.defaultArtPixels) async {
        if url != artworkURL {
            artworkURL = url
            seed = url.flatMap(cache.cachedSeed(for:))
            knownUpFront = seed != nil
        }
        guard let url, seed == nil else { return }
        let found = await cache.seed(for: url, artPixels: artPixels)
        guard url == artworkURL, let found else { return }
        seed = found
    }
}

/// The mesh the player's backdrop should show — `rememberArtworkMesh`.
///
/// Feed ``mesh`` into an ``ArtworkMeshCrossfade``. A cover the cache has never
/// seen is read *over* the last mesh rather than blanking the backdrop for the
/// beat the read takes — which is the flicker a version switch showed every time
/// its cut arrived carrying its own thumbnail. Wrong colour for one read is the
/// trade; absent colour was the flicker. A new track (Android keys this state on
/// the video id) drops the carried mesh; the crossfade keeps the old one drawn
/// until the new one arrives anyway.
@MainActor
@Observable
public final class ArtworkMeshModel {
    @ObservationIgnored private let cache: ArtworkPaletteCache
    @ObservationIgnored private var trackID: String?
    @ObservationIgnored private var artworkURL: URL?
    /// What the mesh on screen was actually read from: nil while it is a
    /// carry-over from the previous cover, so the carried mesh isn't mistaken for
    /// this cover's own answer.
    @ObservationIgnored private var meshURL: URL?

    public private(set) var mesh: ArtworkMesh?

    public init(cache: ArtworkPaletteCache) {
        self.cache = cache
    }

    /// The mesh to draw for `url` right now: the cached one if there is one
    /// (a cover seen before is on colour in its first frame), else the carried one.
    public func currentMesh(for url: URL?) -> ArtworkMesh? {
        if let url, url != artworkURL, let cached = cache.cachedMesh(for: url) {
            return cached
        }
        return mesh
    }

    /// Switches to `url` (and `trackID`) and reads its mesh if needed. Call from
    /// `.task(id: …)` keyed on both.
    public func load(_ url: URL?, trackID: String? = nil, artPixels: Int = ArtworkPaletteCache.defaultArtPixels) async {
        if trackID != self.trackID {
            self.trackID = trackID
            mesh = nil
            artworkURL = nil
            meshURL = nil
        }
        if url != artworkURL {
            artworkURL = url
            if let url, let cached = cache.cachedMesh(for: url) {
                mesh = cached
                meshURL = url
            } else {
                meshURL = nil
            }
        }
        guard let url, meshURL != url else { return }
        let found = await cache.mesh(for: url, artPixels: artPixels)
        guard url == artworkURL, meshURL != url else { return }
        if let found {
            mesh = found
        }
        meshURL = url
    }

    /// A frame grabbed off a playing Canvas clip takes over: a clip is often
    /// graded nothing like the still sleeve it replaces. Near-black frames (the
    /// first read after the video surface is recreated) are ignored and the last
    /// mesh kept. Not cached — the next frame is a different picture.
    public func receiveCanvasFrame(_ frame: ArtworkPixels) async {
        if frame.isLikelyBlackFrame { return }
        let seed = ArtworkMesh.seed(forArtworkURL: artworkURL?.absoluteString)
        let url = artworkURL
        let computed = await Task.detached(priority: .userInitiated) {
            ArtworkMesh(pixels: frame, seed: seed)
        }.value
        guard url == artworkURL else { return }
        if let computed {
            mesh = computed
        }
        meshURL = url
    }
}

/// The blob mesh's four colours for a sleeve — `rememberArtworkColors`.
///
/// Starts from the stock colours for an artwork not read before, and swaps in
/// the sleeve's own once read; drive a ``ThemingTransition`` of
/// ``MeshGradientColors`` off ``palette`` for the 1.4 s crossfade.
@MainActor
@Observable
public final class MeshPaletteModel {
    @ObservationIgnored private let cache: ArtworkPaletteCache
    @ObservationIgnored private var artworkURL: URL?
    @ObservationIgnored private var loaded = false

    public private(set) var palette: MeshPalette = .fallback

    public init(cache: ArtworkPaletteCache) {
        self.cache = cache
    }

    /// The palette for `url` right now — cached if known, else the current one.
    public func currentPalette(for url: URL?) -> MeshPalette {
        if url != artworkURL {
            return url.flatMap(cache.cachedMeshPalette(for:)) ?? .fallback
        }
        return palette
    }

    /// Switches to `url` and reads it, at `artPixels` when the surface draws the cover at a size
    /// (see ``ArtworkPaletteCache/meshPalette(for:artPixels:)``). Call from `.task(id: url)`.
    public func load(_ url: URL?, artPixels: Int? = nil) async {
        if url != artworkURL {
            artworkURL = url
            let cached = url.flatMap(cache.cachedMeshPalette(for:))
            palette = cached ?? .fallback
            loaded = cached != nil
        }
        guard let url, !loaded else { return }
        let found = await cache.meshPalette(for: url, artPixels: artPixels)
        // `loaded` also means a canvas frame got here first and keeps its colours.
        guard url == artworkURL, !loaded, let found else { return }
        palette = found
        loaded = true
    }

    /// A Canvas frame is quantised the same way and takes over, crossfading in
    /// exactly like a track skip. Near-black frames are ignored.
    public func receiveCanvasFrame(_ frame: ArtworkPixels) async {
        if frame.isLikelyBlackFrame { return }
        let url = artworkURL
        let colors = await Task.detached(priority: .userInitiated) {
            MeshPalette(pixels: frame)
        }.value
        guard url == artworkURL else { return }
        palette = colors
        // The still sleeve must not replace the clip's colours when its read lands later, as
        // ``ArtworkMeshModel`` guards with `meshURL`.
        loaded = url != nil
    }
}
