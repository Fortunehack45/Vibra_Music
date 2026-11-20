import VibraMusicCore
import Foundation
import os

/// Colours already read, keyed by artwork URL, and the reads in progress.
///
/// Reading a sleeve again costs a download, a decode and a quantise for an answer
/// that cannot have changed — the artwork at a URL is the artwork at that URL. So
/// every derived value is cached per URL (the *unsized* URL, so a page and a row
/// showing the same cover at different sizes share one entry), and a read that
/// is already running is joined rather than started twice.
///
/// The `cached…` lookups are synchronous and cheap, for a view's first frame:
/// artwork that has been read once is tinted immediately, with nothing to wait
/// for and nothing to fade. The `async` reads fetch through ``ArtworkImageLoading``
/// and do their pixel work off the main thread.
///
/// | Read | Android | Decoded at | Entries |
/// |---|---|---|---|
/// | ``seed(for:artPixels:)`` | `rememberArtworkPalette` | 128 | 128 |
/// | ``mesh(for:artPixels:)`` | `rememberArtworkMesh` (retried) | 120 | 64 |
/// | ``meshPalette(for:artPixels:)`` | `rememberArtworkColors` | 128 | 64 |
/// | ``blurredArtwork(for:artPixels:)`` | `rememberFullArtworkBlurImage` | 128 | 8 |
///
/// Canvas clip frames never go through here: the next frame for the same URL is
/// a different picture, and there would be a new entry every few seconds.
public final class ArtworkPaletteCache: @unchecked Sendable {
    public typealias Sizing = @Sendable (_ url: URL, _ pixels: Int) -> URL

    /// The artwork size read when a caller doesn't say — a shelf card's
    /// (Core's `CARD_ART_PX`). Callers should pass whatever size the surface
    /// already has on screen so the read hits the image cache.
    public static let defaultArtPixels = 480

    private let loader: any ArtworkImageLoading
    private let sizing: Sizing
    private let retryDelay: TimeInterval
    private let logger = Logger(subsystem: "com.fortune.vibramusic.ios", category: "Theming")

    private let seeds = ArtworkResultStore<ArtworkSeed>(capacity: 128)
    private let meshes = ArtworkResultStore<ArtworkMesh>(capacity: ArtworkMeshBackdropStyle.cacheEntries)
    private let meshPalettes = ArtworkResultStore<MeshPalette>(capacity: 64)
    private let blurs = ArtworkResultStore<ArtworkPixels>(capacity: ArtworkBlur.cacheEntries)

    /// - Parameters:
    ///   - session: what reads fetch through: the app's ``VibraMusicHTTP`` stack unless a test
    ///     stubs it. The app's own cache doesn't fetch at all: it reads its artwork cache.
    ///   - sizing: turns an artwork URL and a pixel size into the URL to fetch.
    ///     Defaults to rewriting YouTube Music's `w…-h…` hint; the app can pass
    ///     Core's `artworkAt` instead.
    public convenience init(session: URLSession = VibraMusicHTTP.session, sizing: @escaping Sizing = ArtworkSizing.youTubeMusic) {
        self.init(loader: URLSessionArtworkLoader(session: session), sizing: sizing)
    }

    /// - Parameter retryDelay: the wait between a mesh read's attempts
    ///   (``ArtworkMeshBackdropStyle/retryDelay``); injectable for tests.
    public init(
        loader: any ArtworkImageLoading,
        sizing: @escaping Sizing = ArtworkSizing.youTubeMusic,
        retryDelay: TimeInterval = ArtworkMeshBackdropStyle.retryDelay
    ) {
        self.loader = loader
        self.sizing = sizing
        self.retryDelay = retryDelay
    }

    // MARK: Page tint

    public func cachedSeed(for url: URL) -> ArtworkSeed? {
        seeds.cached(url)
    }

    /// The page-tint seed for the artwork at `url`, read at `artPixels`. Nil
    /// when it can't be fetched or has no colour at all. Not retried: a page
    /// without a tint still reads fine.
    public func seed(for url: URL, artPixels: Int = defaultArtPixels) async -> ArtworkSeed? {
        await seeds.value(for: url, variant: artPixels) { [loader, sizing, logger] in
            do {
                let pixels = try await loader.loadArtwork(from: sizing(url, artPixels), fittingLongestSide: ArtworkSeed.decodePixels)
                return ArtworkSeed(pixels: pixels)
            } catch {
                logger.debug("Artwork tint read failed for \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }

    // MARK: Player mesh backdrop

    public func cachedMesh(for url: URL) -> ArtworkMesh? {
        meshes.cached(url)
    }

    /// The mesh backdrop for the artwork at `url`, read at `artPixels`.
    ///
    /// Tried ``ArtworkMeshBackdropStyle/loadAttempts`` times, ``retryDelay``
    /// apart, because nothing else re-triggers it: one dropped connection used to
    /// leave the player with no colour behind it at all until the track changed.
    /// A cover that decoded but had no mesh in it is an answer, not a failure, and
    /// isn't asked again.
    public func mesh(for url: URL, artPixels: Int = defaultArtPixels) async -> ArtworkMesh? {
        let attempts = ArtworkMeshBackdropStyle.loadAttempts
        let delay = retryDelay
        return await meshes.value(for: url, variant: artPixels) { [loader, sizing, logger] in
            let source = sizing(url, artPixels)
            for attempt in 0..<attempts {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
                }
                do {
                    let pixels = try await loader.loadArtwork(from: source, fittingLongestSide: ArtworkMesh.decodePixels)
                    return ArtworkMesh(pixels: pixels, seed: ArtworkMesh.seed(forArtworkURL: url.absoluteString))
                } catch {
                    logger.debug("Artwork mesh read \(attempt + 1)/\(attempts) failed for \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            return nil
        }
    }

    // MARK: Blob mesh colours

    public func cachedMeshPalette(for url: URL) -> MeshPalette? {
        meshPalettes.cached(url)
    }

    /// The four blob-mesh colours for the artwork at `url`. With `artPixels`, read at the size
    /// the surface already draws the cover, so the read comes out of the image cache instead of
    /// being a second download of a possibly full-size cover; without, fetched as given, which
    /// is what Android does. Nil when it can't be fetched, in which case the surface keeps
    /// ``MeshPalette/fallback``.
    public func meshPalette(for url: URL, artPixels: Int? = nil) async -> MeshPalette? {
        await meshPalettes.value(for: url, variant: artPixels ?? 0) { [loader, sizing, logger] in
            do {
                let source = artPixels.map { sizing(url, $0) } ?? url
                let pixels = try await loader.loadArtwork(from: source, fittingLongestSide: MeshPalette.decodePixels)
                return MeshPalette(pixels: pixels)
            } catch {
                logger.debug("Mesh palette read failed for \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }

    // MARK: Full-cover blur

    public func cachedBlurredArtwork(for url: URL) -> ArtworkPixels? {
        blurs.cached(url)
    }

    /// The pre-blurred full-cover backdrop (lyrics, queue, landscape and tablet
    /// players): a 128px copy box-blurred once, off the main thread. Draw it with
    /// ``ArtworkPixels/makeCGImage()`` scaled to fill, under ``ArtworkBlur/scrimStops``.
    public func blurredArtwork(for url: URL, artPixels: Int = defaultArtPixels) async -> ArtworkPixels? {
        await blurs.value(for: url, variant: artPixels) { [loader, sizing, logger] in
            do {
                let pixels = try await loader.loadArtwork(from: sizing(url, artPixels), fittingLongestSide: ArtworkBlur.sourcePixels)
                return pixels.boxBlurred(passes: ArtworkBlur.passes)
            } catch {
                logger.debug("Artwork blur read failed for \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }

    /// Forgets everything read so far (in-flight reads still finish).
    public func removeAll() {
        seeds.removeAll()
        meshes.removeAll()
        meshPalettes.removeAll()
        blurs.removeAll()
    }
}

/// One kind of cached artwork result: an access-ordered LRU (Android's
/// `LinkedHashMap(accessOrder = true)` with `removeEldestEntry`) plus the reads
/// in flight, both behind a lock.
final class ArtworkResultStore<Value: Sendable>: @unchecked Sendable {
    private struct Entry {
        var value: Value
        var stamp: UInt64
    }

    private struct FlightKey: Hashable {
        var url: URL
        var variant: Int
    }

    private enum Lookup {
        case hit(Value)
        case wait(Task<Value?, Never>)
    }

    let capacity: Int
    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]
    private var clock: UInt64 = 0
    private var inFlight: [FlightKey: Task<Value?, Never>] = [:]

    init(capacity: Int) {
        self.capacity = capacity
    }

    var count: Int {
        lock.withLock { entries.count }
    }

    /// A hit counts as a use, keeping it from being evicted.
    func cached(_ url: URL) -> Value? {
        lock.withLock { touch(url) }
    }

    func insert(_ value: Value, for url: URL) {
        lock.withLock { store(value, for: url) }
    }

    func removeAll() {
        lock.withLock { entries.removeAll() }
    }

    /// The cached value, or the result of `read` — shared with any caller already
    /// waiting on the same URL and variant. Non-nil results are cached.
    func value(for url: URL, variant: Int, read: @escaping @Sendable () async -> Value?) async -> Value? {
        let key = FlightKey(url: url, variant: variant)
        let lookup: Lookup = lock.withLock {
            if let hit = touch(url) {
                return .hit(hit)
            }
            if let running = inFlight[key] {
                return .wait(running)
            }
            // Detached: the pixel work must not inherit a caller's main actor.
            // Registered under the lock, so the read can't finish (and try to
            // deregister) before it is registered.
            let running = Task.detached(priority: .userInitiated) { [weak self] () -> Value? in
                let result = await read()
                self?.finish(key: key, result: result)
                return result
            }
            inFlight[key] = running
            return .wait(running)
        }
        switch lookup {
        case .hit(let value):
            return value
        case .wait(let task):
            return await task.value
        }
    }

    private func finish(key: FlightKey, result: Value?) {
        lock.withLock {
            inFlight[key] = nil
            if let result {
                store(result, for: key.url)
            }
        }
    }

    // Callers hold the lock.
    private func touch(_ url: URL) -> Value? {
        guard var entry = entries[url] else { return nil }
        clock &+= 1
        entry.stamp = clock
        entries[url] = entry
        return entry.value
    }

    private func store(_ value: Value, for url: URL) {
        clock &+= 1
        entries[url] = Entry(value: value, stamp: clock)
        while entries.count > capacity, let eldest = entries.min(by: { $0.value.stamp < $1.value.stamp })?.key {
            entries[eldest] = nil
        }
    }
}
