import CoreGraphics
import XCTest
@testable import Theming

/// The per-URL colour cache: sizing, sharing, retries, eviction.
final class ArtworkPaletteCacheTests: XCTestCase {
    private let art = URL(string: "https://yt3.googleusercontent.com/cover=w544-h544-l90-rj")!
    private let sized = URL(string: "https://yt3.googleusercontent.com/cover=w480-h480-l90-rj")!

    func testSeedIsReadAtTheRequestedSizeAndCachedUnderTheUnsizedURL() async throws {
        let loader = StubArtworkLoader()
        loader.serve(solidPixels(width: 480, height: 480, argb(40, 90, 200)), at: sized)
        let cache = ArtworkPaletteCache(loader: loader)

        XCTAssertNil(cache.cachedSeed(for: art))
        let seed = await cache.seed(for: art, artPixels: 480)
        XCTAssertEqual(loader.requests, [.init(url: sized, side: 128)])
        assertColor(try XCTUnwrap(seed).dominant, argb(40, 88, 200))
        XCTAssertEqual(cache.cachedSeed(for: art), seed)

        // A second read is the cached answer, not another fetch.
        _ = await cache.seed(for: art, artPixels: 480)
        XCTAssertEqual(loader.requests.count, 1)
    }

    func testConcurrentReadsOfOneCoverShareOneFetch() async {
        let loader = StubArtworkLoader()
        loader.delay = 0.05
        loader.serve(solidPixels(width: 64, height: 64, argb(200, 60, 60)), at: sized)
        let cache = ArtworkPaletteCache(loader: loader)
        let url = art
        let seeds = await withTaskGroup(of: ArtworkSeed?.self) { group in
            for _ in 0..<8 {
                group.addTask { await cache.seed(for: url, artPixels: 480) }
            }
            return await group.reduce(into: [ArtworkSeed?]()) { $0.append($1) }
        }
        XCTAssertEqual(seeds.count, 8)
        XCTAssertEqual(Set(seeds.compactMap { $0 }).count, 1)
        XCTAssertEqual(loader.requests.count, 1)
    }

    func testFailedTintReadIsNotCachedAndNotRetried() async {
        let loader = StubArtworkLoader()
        loader.serve(solidPixels(argb(1, 2, 3)), at: sized, failingFirst: 1)
        let cache = ArtworkPaletteCache(loader: loader)
        let first = await cache.seed(for: art, artPixels: 480)
        XCTAssertNil(first)
        XCTAssertEqual(loader.requests.count, 1)
        XCTAssertNil(cache.cachedSeed(for: art))
        // Asking again later does try again.
        let second = await cache.seed(for: art, artPixels: 480)
        XCTAssertNotNil(second)
    }

    func testMeshReadIsRetriedThroughDroppedConnections() async throws {
        let loader = StubArtworkLoader()
        loader.serve(solidPixels(width: 240, height: 240, argb(30, 30, 200)), at: sized, failingFirst: 3)
        let cache = ArtworkPaletteCache(loader: loader, retryDelay: 0.01)
        let mesh = await cache.mesh(for: art, artPixels: 480)
        XCTAssertEqual(loader.requests.count, 4, "four attempts")
        XCTAssertTrue(loader.requests.allSatisfy { $0.side == 120 })
        XCTAssertEqual(try XCTUnwrap(mesh).controlPoints.first, ArtworkMesh.lifted(argb(30, 30, 200)))
        XCTAssertEqual(cache.cachedMesh(for: art), mesh)
        // Seeded by the artwork URL's Java hash, as on Android.
        let expected = ArtworkMesh(pixels: try XCTUnwrap(loader.lastServed(url: sized, side: 120)), seed: ArtworkMesh.seed(forArtworkURL: art.absoluteString))
        XCTAssertEqual(mesh, expected)
    }

    func testMeshReadGivesUpAfterFourAttempts() async {
        let loader = StubArtworkLoader()
        let cache = ArtworkPaletteCache(loader: loader, retryDelay: 0.01)
        let mesh = await cache.mesh(for: art)
        XCTAssertNil(mesh)
        XCTAssertEqual(loader.requests.count, ArtworkMeshBackdropStyle.loadAttempts)
        XCTAssertNil(cache.cachedMesh(for: art))
    }

    func testMeshPaletteIsReadWithoutASizeHint() async {
        let loader = StubArtworkLoader()
        loader.serve(solidPixels(argb(40, 60, 200)), at: art)
        let cache = ArtworkPaletteCache(loader: loader)
        let palette = await cache.meshPalette(for: art)
        XCTAssertEqual(loader.requests, [.init(url: art, side: 128)])
        XCTAssertEqual(palette?.colors.count, 4)
        XCTAssertEqual(cache.cachedMeshPalette(for: art), palette)
    }

    /// A surface that draws the cover at a size (Replay's) gets its colours from that size, the
    /// copy its image is already fetching, not from the cover as it came.
    func testMeshPaletteIsReadAtTheSizeASurfaceDraws() async {
        let loader = StubArtworkLoader()
        let drawn = URL(string: "https://yt3.googleusercontent.com/cover=w160-h160-l90-rj")!
        loader.serve(solidPixels(argb(40, 60, 200)), at: drawn)
        let cache = ArtworkPaletteCache(loader: loader)
        let palette = await cache.meshPalette(for: art, artPixels: 160)
        XCTAssertEqual(loader.requests, [.init(url: drawn, side: 128)])
        XCTAssertEqual(palette?.colors.count, 4)
        XCTAssertEqual(cache.cachedMeshPalette(for: art), palette)
    }

    func testBlurredArtworkIsPreparedOnce() async throws {
        let loader = StubArtworkLoader()
        let source = makePixels(width: 256, height: 256) { x, _ in x < 128 ? argb(0, 0, 0) : argb(240, 240, 240) }
        loader.serve(source, at: sized)
        let cache = ArtworkPaletteCache(loader: loader)
        let blurredResult = await cache.blurredArtwork(for: art, artPixels: 480)
        let blurred = try XCTUnwrap(blurredResult)
        XCTAssertEqual([blurred.width, blurred.height], [128, 128])
        XCTAssertEqual(loader.requests, [.init(url: sized, side: 128)])
        XCTAssertGreaterThan(Set(blurred.argb).count, 10, "the step has been softened")
        XCTAssertEqual(cache.cachedBlurredArtwork(for: art), blurred)
        cache.removeAll()
        XCTAssertNil(cache.cachedBlurredArtwork(for: art))
    }

    func testLeastRecentlyUsedEntryIsEvicted() {
        let store = ArtworkResultStore<Int>(capacity: 3)
        let urls = (0..<4).map { URL(string: "https://example.com/\($0)")! }
        store.insert(0, for: urls[0])
        store.insert(1, for: urls[1])
        store.insert(2, for: urls[2])
        // Reading 0 makes 1 the eldest.
        XCTAssertEqual(store.cached(urls[0]), 0)
        store.insert(3, for: urls[3])
        XCTAssertEqual(store.count, 3)
        XCTAssertNil(store.cached(urls[1]))
        XCTAssertEqual(store.cached(urls[0]), 0)
        XCTAssertEqual(store.cached(urls[3]), 3)
    }

    func testYouTubeMusicSizing() {
        XCTAssertEqual(ArtworkSizing.youTubeMusic(art, 120).absoluteString, "https://yt3.googleusercontent.com/cover=w120-h120-l90-rj")
        let thumbnail = URL(string: "https://i.ytimg.com/vi/abc/hqdefault.jpg")!
        XCTAssertEqual(ArtworkSizing.youTubeMusic(thumbnail, 120), thumbnail)
        let file = URL(fileURLWithPath: "/tmp/cover.jpg")
        XCTAssertEqual(ArtworkSizing.youTubeMusic(file, 120), file)
        XCTAssertEqual(ArtworkSizing.unchanged(art, 120), art)
    }
}

/// The real `URLSession` loader, against stubbed responses.
final class URLSessionArtworkLoaderTests: XCTestCase {
    private func cover() -> Data {
        pngData(makeCGImage(width: 200, height: 200) { context in
            context.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        })
    }

    func testDecodesAThumbnailOffTheWire() async throws {
        let body = cover()
        StubURLProtocol.register(host: "art.ok.test") { _ in (200, body) }
        let loader = URLSessionArtworkLoader(session: StubURLProtocol.session())
        let pixels = try await loader.loadArtwork(from: URL(string: "https://art.ok.test/cover.png")!, fittingLongestSide: 64)
        XCTAssertEqual([pixels.width, pixels.height], [64, 64])
        assertColor(ThemeColor(argb: pixels.argb[0]), argb(204, 51, 51), tolerance: 1)
    }

    func testHTTPErrorsAndGarbageAreErrors() async {
        StubURLProtocol.register(host: "art.missing.test") { _ in (404, Data()) }
        StubURLProtocol.register(host: "art.garbage.test") { _ in (200, Data("<html>".utf8)) }
        let loader = URLSessionArtworkLoader(session: StubURLProtocol.session())
        do {
            _ = try await loader.loadArtwork(from: URL(string: "https://art.missing.test/x")!, fittingLongestSide: 64)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ArtworkLoadingError, .badStatus(404))
        }
        do {
            _ = try await loader.loadArtwork(from: URL(string: "https://art.garbage.test/x")!, fittingLongestSide: 64)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ArtworkLoadingError, .undecodable)
        }
    }

    func testCacheOverURLSessionFetchesSizedURLOnce() async throws {
        let body = cover()
        StubURLProtocol.register(host: "yt3.cache.test") { request in
            request.url?.absoluteString.contains("=w160-h160") == true ? (200, body) : (404, Data())
        }
        let cache = ArtworkPaletteCache(session: StubURLProtocol.session())
        let url = URL(string: "https://yt3.cache.test/abc=w544-h544-l90-rj")!
        let seed = await cache.seed(for: url, artPixels: 160)
        XCTAssertNotNil(seed)
        _ = await cache.seed(for: url, artPixels: 160)
        XCTAssertEqual(StubURLProtocol.hitCount(host: "yt3.cache.test"), 1)
    }
}

extension StubArtworkLoader {
    /// What the stub hands back for `url` at `side`, for comparing results.
    func lastServed(url: URL, side: Int) -> ArtworkPixels? {
        guard let served = image(for: url), let cgImage = served.makeCGImage() else { return nil }
        return ArtworkPixels(image: cgImage, fittingLongestSide: side)
    }
}
